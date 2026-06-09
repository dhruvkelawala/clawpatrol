#!/usr/bin/env bash
set -euo pipefail

# Throwaway helper for PR #643 UDP-catchall diagnosis. It builds the current
# checkout, installs it over the gateway binary with a timestamped backup,
# restarts the manually-run gateway, and prints the debug log tail.
#
# Override when needed:
#   CLAWPATROL_BIN=/usr/local/bin/clawpatrol
#   CLAWPATROL_CONFIG=/opt/clawpatrol/gateway.hcl
#   CLAWPATROL_USER=clawpatrol
#   CLAWPATROL_LOG=/tmp/clawpatrol.log

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bin="${CLAWPATROL_BIN:-/usr/local/bin/clawpatrol}"
config="${CLAWPATROL_CONFIG:-/opt/clawpatrol/gateway.hcl}"
user="${CLAWPATROL_USER:-clawpatrol}"
log="${CLAWPATROL_LOG:-/tmp/clawpatrol.log}"

if [[ ! -d dashboard/dist ]]; then
  echo "dashboard/dist missing; building dashboard first"
  (cd dashboard && deno install && deno task build)
fi

echo "building clawpatrol from $(git rev-parse --short HEAD)"
go build -o clawpatrol ./cmd/clawpatrol

backup="$bin.backup-before-debug-udp643-gw-$(date -u +%Y%m%dT%H%M%SZ)"
echo "installing $bin (backup: $backup)"
sudo cp -a "$bin" "$backup"
mode="$(stat -c '%a' "$backup")"
owner="$(stat -c '%u:%g' "$backup")"
sudo install -m "$mode" ./clawpatrol "$bin"
sudo chown "$owner" "$bin"

echo "stopping existing gateway processes for $bin gateway"
if pids="$(pgrep -f "$bin gateway" || true)"; [[ -n "$pids" ]]; then
  printf '%s\n' $pids | xargs -r sudo kill -TERM
  sleep 2
fi
if pids="$(pgrep -f "$bin gateway" || true)"; [[ -n "$pids" ]]; then
  printf '%s\n' $pids | xargs -r sudo kill -KILL
  sleep 1
fi

echo "starting gateway as $user with config $config (TS_DEBUG_NETSTACK + CLAWPATROL_DEBUG_TSNET on)"
: >"$log"
# DEBUG-UDP643: TS_DEBUG_NETSTACK is read by gVisor at process start, so it
# must be exported into the gateway process here (not toggled at runtime).
# CLAWPATROL_DEBUG_TSNET routes tsnet-internal logs + the netstack counter
# dump into the gateway log.
sudo -u "$user" \
  TS_DEBUG_NETSTACK=1 \
  CLAWPATROL_DEBUG_TSNET=1 \
  nohup "$bin" gateway "$config" >"$log" 2>&1 &
sleep 5

echo
echo "running gateway processes:"
pgrep -af "$bin gateway" || true

echo
echo "log tail ($log):"
tail -120 "$log" || true

echo
echo "debug grep command:"
echo "  grep DEBUG-UDP643-GW $log"
echo
echo "backup: $backup"
