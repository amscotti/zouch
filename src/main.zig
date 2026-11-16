const std = @import("std");
const srv = @import("http/server.zig");
const replicator = @import("replicator.zig");
const Db = @import("store/db.zig").Db;
const version = @import("version.zig");

const Source = struct { url: []u8, user: ?[]u8, password: ?[]u8 };

fn usage() void {
    std.debug.print(
        \\usage: zouch <command> [args]
        \\
        \\commands:
        \\  serve [data-dir] [port] [bind-address]    start the server (defaults: data 5985 127.0.0.1)
        \\  pull <source-url> <database> [data-dir]   copy a database from a CouchDB-compatible source
        \\  push <target-url> <database> [data-dir]   copy a local database to a CouchDB-compatible target
        \\  check [data-dir]                          verify manifests, segments and WAL; exit 1 on damage
        \\  --version                                 print the version and exit
        \\  --help                                    print this message and exit
        \\
        \\environment:
        \\  ZOUCH_AUTH=user:password                  global Basic auth for every request
        \\  ZOUCH_AUTH_FILE=/path/to/credentials      per-database credentials, lines of db:user:password
        \\  ZOUCH_ROLES="alice:dev,ops;bob:ops"       static roles used by _security
        \\  ZOUCH_MAX_FEEDS=256                       concurrent longpoll/continuous feeds (max 4096)
        \\  ZOUCH_AUTO_COMPACT_SECS=3600              background compaction interval; 0 disables
        \\  ZOUCH_WWW=/path/to/fauxton                serve a different Fauxton build at /_utils
        \\
        \\A data directory has one writer: stop the server before a CLI pull or push.
        \\
    , .{});
}

fn usageAndExit() noreturn {
    usage();
    std.process.exit(2);
}

/// Prints a single updating line while a pull runs. Only to a terminal: with
/// output redirected the final summary is enough, and a run of carriage
/// returns would leave one long line in the log.
const ProgressPrinter = struct {
    tty: bool,
    width: usize = 0,

    fn report(ctx: ?*anyopaque, p: replicator.Progress) void {
        const self: *ProgressPrinter = @ptrCast(@alignCast(ctx.?));
        if (!self.tty) return;
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  {d} documents, {d} changes fetched", .{ p.documents, p.changes }) catch return;
        // Pad with spaces so a shorter line cannot leave the tail of a longer
        // previous one behind the cursor.
        const pad = if (self.width > line.len) self.width - line.len else 0;
        std.debug.print("\r{s}", .{line});
        for (0..pad) |_| std.debug.print(" ", .{});
        self.width = line.len;
    }

    fn finish(self: *ProgressPrinter) void {
        if (!self.tty) return;
        std.debug.print("\r", .{});
        for (0..self.width) |_| std.debug.print(" ", .{});
        std.debug.print("\r", .{});
    }
};

/// Print a replication failure with whatever the replicator could learn about
/// it, plus a hint that matches the HTTP status. A bare `error.SourceHttpError`
/// made a wrong password, a missing database and a broken server look alike.
fn reportFailure(diag: *const replicator.Diag, what: []const u8, e: anyerror) void {
    if (diag.message) |message| {
        std.debug.print("{s}: {s}\n", .{ what, message });
    } else {
        std.debug.print("{s}: {s}\n", .{ what, @errorName(e) });
    }
    if (diag.status == 401 or diag.status == 403) {
        std.debug.print("{s}: the remote rejected the credentials; put user:password in the URL\n", .{what});
    } else if (diag.status == 404) {
        std.debug.print("{s}: the remote has no such database\n", .{what});
    } else if (e == error.DatabaseLocked) {
        std.debug.print("{s}: a running server holds this database; stop it and re-run\n", .{what});
    } else if (e == error.ConnectionRefused or e == error.ConnectionResetByPeer or e == error.NetworkUnreachable) {
        std.debug.print("{s}: cannot reach the remote host; check the URL and that it is listening\n", .{what});
    }
}

fn parseSource(alloc: std.mem.Allocator, raw: []const u8) !Source {
    const scheme = std.mem.indexOf(u8, raw, "://") orelse return .{ .url = try alloc.dupe(u8, raw), .user = null, .password = null };
    const rest = raw[scheme + 3 ..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return .{ .url = try alloc.dupe(u8, raw), .user = null, .password = null };
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (at >= slash) return .{ .url = try alloc.dupe(u8, raw), .user = null, .password = null };
    const userinfo = rest[0..at];
    const colon = std.mem.indexOfScalar(u8, userinfo, ':') orelse return error.InvalidSource;
    return .{
        .url = try std.fmt.allocPrint(alloc, "{s}://{s}", .{ raw[0..scheme], rest[at + 1 ..] }),
        .user = try alloc.dupe(u8, userinfo[0..colon]),
        .password = try alloc.dupe(u8, userinfo[colon + 1 ..]),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const cmd = args.next() orelse "serve";

    if (std.mem.eql(u8, cmd, "serve")) {
        const root = args.next() orelse "data";
        const port: u16 = if (args.next()) |p| std.fmt.parseInt(u16, p, 10) catch {
            // Silently serving on 5985 when the caller asked for 60000 hid a
            // typo and could leave a second, unnoticed listener running.
            std.debug.print("serve: invalid port '{s}' (expected a number from 1 to 65535)\n", .{p});
            std.process.exit(2);
        } else 5985;
        const bind = args.next() orelse "127.0.0.1";
        const bind_all = std.mem.eql(u8, bind, "0.0.0.0") or std.mem.eql(u8, bind, "::");
        const app = try srv.App.init(alloc, io, root);
        if (init.environ_map.get("ZOUCH_MAX_FEEDS")) |v| {
            app.setMaxFeeds(std.fmt.parseInt(u32, v, 10) catch 256);
        }
        if (init.environ_map.get("ZOUCH_WWW")) |dir| try app.setWww(dir);
        if (init.environ_map.get("ZOUCH_AUTO_COMPACT_SECS")) |v| {
            app.setAutoCompact(std.fmt.parseInt(u64, v, 10) catch 0);
        }
        if (init.environ_map.get("ZOUCH_ROLES")) |roles| try app.setRoles(roles);
        if (init.environ_map.get("ZOUCH_AUTH")) |credentials| try app.setAuth(credentials);
        if (init.environ_map.get("ZOUCH_AUTH_FILE")) |auth_file| try app.setAuthFile(auth_file);
        try srv.serve(app, port, bind_all);
    } else if (std.mem.eql(u8, cmd, "pull")) {
        const source_raw = args.next() orelse usageAndExit();
        const target = args.next() orelse usageAndExit();
        const root = args.next() orelse "data";
        const source = try parseSource(alloc, source_raw);
        defer alloc.free(source.url);
        defer if (source.user) |u| alloc.free(u);
        defer if (source.password) |p| alloc.free(p);
        const target_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, target });
        defer alloc.free(target_path);
        var diag: replicator.Diag = .{ .alloc = alloc };
        defer diag.deinit();
        var progress: ProgressPrinter = .{ .tty = std.Io.File.stderr().isTty(io) catch false };
        const result = replicator.pull(alloc, io, .{
            .source = source.url,
            .target_path = target_path,
            .username = source.user,
            .password = source.password,
            .diag = &diag,
            .on_progress = ProgressPrinter.report,
            .progress_ctx = &progress,
        }) catch |e| {
            progress.finish();
            reportFailure(&diag, "pull", e);
            std.process.exit(1);
        };
        progress.finish();
        // The sequences are allocated for the HTTP answer, which frees them;
        // this path must free them too or the leak check at exit complains.
        if (result.start_seq) |seq| alloc.free(seq);
        if (result.end_seq) |seq| alloc.free(seq);
        std.debug.print("replicated {d} documents ({d} changes seen)\n", .{ result.documents, result.changes_seen });
    } else if (std.mem.eql(u8, cmd, "push")) {
        const target_raw = args.next() orelse usageAndExit();
        const database = args.next() orelse usageAndExit();
        const root = args.next() orelse "data";
        const target = try parseSource(alloc, target_raw);
        defer alloc.free(target.url);
        defer if (target.user) |u| alloc.free(u);
        defer if (target.password) |p| alloc.free(p);
        const local_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, database });
        defer alloc.free(local_path);
        // Refuse to invent an empty database for a mistyped name. Db.open
        // creates the directory, so a typo used to push nothing, report
        // success, and leave a stray database behind.
        {
            var probe = std.Io.Dir.cwd().openDir(io, local_path, .{}) catch {
                std.debug.print("push: no local database '{s}' under {s}\n", .{ database, root });
                std.process.exit(1);
            };
            probe.close(io);
        }
        var diag: replicator.Diag = .{ .alloc = alloc };
        defer diag.deinit();
        const result = replicator.push(alloc, io, .{
            .target = target.url,
            .local_path = local_path,
            .username = target.user,
            .password = target.password,
            .diag = &diag,
        }) catch |e| {
            reportFailure(&diag, "push", e);
            std.process.exit(1);
        };
        if (result.end_seq) |seq| alloc.free(seq);
        std.debug.print("pushed {d} documents ({d} checked)\n", .{ result.pushed, result.checked });
    } else if (std.mem.eql(u8, cmd, "check")) {
        const root = args.next() orelse "data";
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| {
            std.debug.print("check: cannot open {s}: {s}\n", .{ root, @errorName(e) });
            std.debug.print("check: expected the data directory, which holds one directory per database\n", .{});
            std.process.exit(1);
        };
        defer dir.close(io);
        var failed = false;
        var locked: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, "blobs")) continue;
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, entry.name });
            defer alloc.free(path);
            const db = Db.open(alloc, io, path) catch |e| {
                // A database held by a running server is not damaged data.
                // Reporting it as corruption sent operators into the recovery
                // runbook for a lock they only had to release.
                if (e == error.DatabaseLocked) {
                    locked += 1;
                    std.debug.print("skipped: {s}: open in another process (stop the server and re-run)\n", .{entry.name});
                    continue;
                }
                std.debug.print("check: {s}: {s} ({s})\n", .{ entry.name, path, @errorName(e) });
                failed = true;
                continue;
            };
            db.closeReadOnly();
        }
        if (failed) {
            std.debug.print("check: FAILED: at least one database could not be recovered\n", .{});
            std.process.exit(1);
        }
        if (locked > 0) {
            std.debug.print("ok ({d} database{s} skipped: locked by a running server)\n", .{ locked, if (locked == 1) "" else "s" });
            return;
        }
        std.debug.print("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        usage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V") or std.mem.eql(u8, cmd, "version")) {
        std.debug.print("zouch {s}\n", .{version.string});
    } else {
        // A misspelled subcommand used to print usage and exit 0, so a CI
        // health step like `zouch chek ./data` passed without checking anything.
        std.debug.print("zouch: unknown command '{s}'\n\n", .{cmd});
        usageAndExit();
    }
}
