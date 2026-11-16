#!/usr/bin/env bash
# Run the Zouch Jepsen scenarios sequentially and keep one log per suite.
set -u

cd "$(dirname "$0")"
PORT="${JEPSEN_PORT:-5985}"
TARGET_PORT="${JEPSEN_TARGET_PORT:-$((PORT + 6))}"
TIMEOUT="${JEPSEN_TIMEOUT:-180}"
SUITES="${SUITES:-smoke kill pause partition disk replication attachments pull continuous multipeer}"
TARGET2_PORT="${JEPSEN_TARGET2_PORT:-$((PORT + 7))}"

mkdir -p logs

cleanup() {
  # Only stop servers started by this harness (identified by pidfile); never
  # pkill by executable name because unrelated zouch instances may be running.
  for pf in /tmp/zouch-jepsen.pid \
            /tmp/zouch-jepsen-source.pid \
            /tmp/zouch-jepsen-target.pid \
            /tmp/zouch-jepsen-target2.pid; do
    if [ -f "$pf" ]; then
      pid="$(cat "$pf" 2>/dev/null || true)"
      if [ -n "$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$pf"
    fi
  done
  for _ in 1 2 3; do
    for p in "$PORT" "$TARGET_PORT" "$TARGET2_PORT"; do
      sudo -n iptables -D INPUT -p tcp --dport "$p" -j DROP 2>/dev/null || true
      sudo -n iptables -D OUTPUT -p tcp --dport "$p" -j DROP 2>/dev/null || true
    done
  done
  if mountpoint -q /mnt/zouch-jepsen; then
    sudo -n umount /mnt/zouch-jepsen 2>/dev/null || true
  fi
}
trap cleanup EXIT

failed=0
for suite in $SUITES; do
  cleanup
  log="logs/${suite}.log"
  echo "=== Jepsen suite: ${suite} ==="
  timeout "$TIMEOUT" lein run "$suite" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    echo "PASS ${suite}"
  else
    echo "FAIL ${suite} (exit ${rc})"
    failed=1
  fi
done

exit "$failed"
