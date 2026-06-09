#!/usr/bin/env bash
set -euo pipefail

# Throwaway helper for the PR #640 UDP-relay diagnosis. Builds the current
# checkout, installs it over the gateway binary with a timestamped backup,
# restarts the manually-run gateway with verbose tsnet/netstack logging, and
# prints the log tail.
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

backup="$bin.backup-before-debug-udp640-gw-$(date -u +%Y%m%dT%H%M%SZ)"
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

# The [DEBUG-UDP640-GW] relay lines (accept / hello / auth / dispatch) are
# ALWAYS on, so the relay diagnosis needs no debug env. The verbose tsnet +
# gVisor packet trace (TS_DEBUG_NETSTACK) is a firehose that can fill /tmp on a
# small instance, so it is opt-in: re-run with DEBUG_VERBOSE=1 only if needed.
verbose_env=()
if [[ "${DEBUG_VERBOSE:-0}" != "0" ]]; then
  echo "DEBUG_VERBOSE on: enabling CLAWPATROL_DEBUG_TSNET (no TS_DEBUG_NETSTACK firehose)"
  verbose_env=(CLAWPATROL_DEBUG_TSNET=1)
fi
echo "starting gateway as $user with config $config"
: >"$log"
sudo -u "$user" "${verbose_env[@]}" nohup "$bin" gateway "$config" >"$log" 2>&1 &
sleep 5

echo
echo "running gateway processes:"
pgrep -af "$bin gateway" || true

echo
echo "log tail ($log):"
tail -60 "$log" || true

echo
echo "watch the relay with:"
echo "  grep -aE 'DEBUG-UDP640|udp relay' $log"
echo
echo "backup: $backup"
