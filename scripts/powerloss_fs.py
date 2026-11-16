#!/usr/bin/env python3
"""A FUSE passthrough that only persists writes on fsync.

This models a power-loss disk: bytes written by a process live in the overlay until the
process calls fsync.  Killing the daemon (without unmounting cleanly) discards those bytes;
the backing directory contains exactly what reached stable storage.  It is deliberately
slow and test-only.
"""
import errno
import os
import shutil
import stat
import sys
import time

import fuse

FUSE = fuse.FUSE


class Overlay(fuse.Operations):
    def __init__(self, backing):
        self.backing = os.path.abspath(backing)
        self.data = {}       # path -> bytearray (uncommitted or committed cache)
        self.created = set()
        self.dirs = set()
        self.modes = {}

    def _b(self, path):
        return os.path.join(self.backing, path.lstrip("/"))

    def _stat_dict(self, st):
        return {
            "st_mode": st.st_mode,
            "st_ino": st.st_ino,
            "st_dev": st.st_dev,
            "st_nlink": st.st_nlink,
            "st_uid": st.st_uid,
            "st_gid": st.st_gid,
            "st_size": st.st_size,
            "st_atime": st.st_atime,
            "st_mtime": st.st_mtime,
            "st_ctime": st.st_ctime,
        }

    def _load(self, path):
        if path not in self.data:
            try:
                with open(self._b(path), "rb") as f:
                    self.data[path] = bytearray(f.read())
            except FileNotFoundError:
                self.data[path] = bytearray()
        return self.data[path]

    def _commit(self, path):
        buf = self.data.get(path)
        if buf is None:
            return
        target = self._b(path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(buf)
            f.flush()
            os.fsync(f.fileno())
        if path in self.created:
            try:
                mode = self.modes.get(path, 0o644)
                os.chmod(target, mode)
            except OSError:
                pass
            self.created.discard(path)

    def getattr(self, path, fh=None):
        try:
            st = os.lstat(self._b(path))
            attrs = self._stat_dict(st)
            if not stat.S_ISDIR(st.st_mode) and path in self.data:
                attrs["st_size"] = len(self.data[path])
            return attrs
        except FileNotFoundError:
            if path in self.data:
                return {
                    "st_mode": self.modes.get(path, 0o644),
                    "st_size": len(self.data[path]),
                    "st_nlink": 1,
                    "st_uid": os.getuid(),
                    "st_gid": os.getgid(),
                    "st_atime": time.time(),
                    "st_mtime": time.time(),
                    "st_ctime": time.time(),
                }
            raise fuse.FuseOSError(errno.ENOENT)

    def _stat(self, d):
        return d  # fusepy accepts a dict/stat_result

    def _dir_stat(self, st):
        return dict(st)

    def readdir(self, path, fh):
        names = {".", ".."}
        try:
            names.update(os.listdir(self._b(path)))
        except FileNotFoundError:
            if path not in self.dirs:
                raise fuse.FuseOSError(errno.ENOENT)
        prefix = path.rstrip("/") + "/"
        for p in list(self.data) + list(self.dirs):
            if p.startswith(prefix):
                rest = p[len(prefix):]
                if rest and "/" not in rest:
                    names.add(rest)
        return list(names)

    def mkdir(self, path, mode):
        os.makedirs(self._b(path), mode=mode, exist_ok=True)
        self.dirs.add(path)
        return 0

    def rmdir(self, path):
        os.rmdir(self._b(path))
        self.dirs.discard(path)
        return 0

    def create(self, path, mode, fi=None):
        self.data[path] = bytearray()
        self.created.add(path)
        self.modes[path] = mode
        return 0

    def open(self, path, flags):
        if flags & os.O_TRUNC:
            self.data[path] = bytearray()
            self.created.add(path)
        return 0

    def read(self, path, size, offset, fh):
        if path in self.data:
            return bytes(self.data[path][offset:offset + size])
        try:
            with open(self._b(path), "rb") as f:
                f.seek(offset)
                return f.read(size)
        except FileNotFoundError:
            raise fuse.FuseOSError(errno.ENOENT)

    def write(self, path, data, offset, fh):
        buf = self._load(path)
        if offset > len(buf):
            buf.extend(b"\0" * (offset - len(buf)))
        buf[offset:offset + len(data)] = data
        self.created.add(path)
        return len(data)

    def truncate(self, path, length, fh=None):
        buf = self._load(path)
        if length < len(buf):
            del buf[length:]
        else:
            buf.extend(b"\0" * (length - len(buf)))
        self.created.add(path)
        return 0

    def fsync(self, path, datasync, fh):
        delay = float(os.environ.get("PL_SLOW_FSYNC", "0") or 0)
        if delay > 0:
            time.sleep(delay)
        self._commit(path)
        return 0

    def fsyncdir(self, path, datasync, fh):
        d = self._b(path)
        try:
            fd = os.open(d, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        except OSError:
            pass
        return 0

    def flush(self, path, fh):
        return 0

    def release(self, path, fh):
        return 0

    def unlink(self, path):
        self.data.pop(path, None)
        self.created.discard(path)
        try:
            os.unlink(self._b(path))
        except FileNotFoundError:
            pass
        return 0

    def rename(self, old, new):
        if old in self.data:
            self.data[new] = self.data.pop(old)
        if old in self.created:
            self.created.discard(old)
            self.created.add(new)
        if old in self.modes:
            self.modes[new] = self.modes.pop(old)
        os.makedirs(os.path.dirname(self._b(new)), exist_ok=True)
        try:
            os.rename(self._b(old), self._b(new))
        except FileNotFoundError:
            pass
        return 0

    def chmod(self, path, mode):
        self.modes[path] = mode
        try:
            os.chmod(self._b(path), mode)
        except FileNotFoundError:
            pass
        return 0

    def utimens(self, path, times=None):
        try:
            os.utime(self._b(path), times)
        except FileNotFoundError:
            pass
        return 0

    def access(self, path, mode):
        if path in self.data or path in self.dirs:
            return 0
        if os.access(self._b(path), mode):
            return 0
        raise fuse.FuseOSError(errno.EACCES)

    def statfs(self, path):
        s = shutil.disk_usage(self.backing)
        return {
            "f_bsize": 4096,
            "f_frsize": 4096,
            "f_blocks": s.total // 4096,
            "f_bfree": s.free // 4096,
            "f_bavail": s.free // 4096,
            "f_files": 1_000_000,
            "f_ffree": 1_000_000,
            "f_favail": 1_000_000,
            "f_fsid": 0,
            "f_flag": 0,
            "f_namemax": 255,
        }


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: powerloss_fs.py BACKING MOUNTPOINT", file=sys.stderr)
        sys.exit(2)
    backing, mount = sys.argv[1], sys.argv[2]
    os.makedirs(backing, exist_ok=True)
    os.makedirs(mount, exist_ok=True)
    FUSE(Overlay(backing), mount, foreground=True, nothreads=True, allow_other=False)
