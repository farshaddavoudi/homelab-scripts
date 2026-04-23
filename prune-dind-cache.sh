#!/usr/bin/env bash
set -euo pipefail

systemctl stop gitlab-runner

SOCK=/var/run/dind-maint.sock
PID=/var/run/dind-maint.pid
LOG=/tmp/dind-maint.log
DATA_ROOT=/var/lib/gitlab-runner/docker-cache
EXEC_ROOT=/var/run/dind-maint-exec

rm -f "$SOCK" "$PID" "$LOG"

cleanup() {
  if [ -f "$PID" ]; then
    pkill -F "$PID" || true
  fi
  rm -f "$SOCK" "$PID"
  systemctl start gitlab-runner
}
trap cleanup EXIT

nohup dockerd \
  --data-root "$DATA_ROOT" \
  --exec-root "$EXEC_ROOT" \
  --pidfile "$PID" \
  -H unix://$SOCK \
  --iptables=false \
  --bridge=none \
  --ip-masq=false \
  >"$LOG" 2>&1 &

for i in $(seq 1 30); do
  if docker -H unix://$SOCK version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker -H unix://$SOCK buildx prune -f \
  --filter "until=168h" \
  --max-used-space 214748364800