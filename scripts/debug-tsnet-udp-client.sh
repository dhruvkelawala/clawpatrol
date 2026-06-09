#!/usr/bin/env bash
set -uo pipefail

# Throwaway client-side probe for the PR #640 UDP-relay diagnosis. Stops any
# stale `clawpatrol` daemon (so a fresh one inherits the debug env), runs one
# probe through `clawpatrol run`, then prints the daemon-log tail.
#
# Default probe is UDP DNS (exercises the relay's dnsvip path). For the
# arbitrary-UDP (non-DNS) path, pass a custom PROBE, e.g. the bundled NTP probe:
#   PROBE="python3 $PWD/scripts/udp-ntp-probe.py" ./scripts/debug-tsnet-udp-client.sh
#
# Override when needed:
#   CLAWPATROL_BIN=$HOME/.local/bin/clawpatrol
#   PROBE='dig @8.8.8.8 +time=3 +tries=1 chatgpt.com A +short'

bin="${CLAWPATROL_BIN:-$HOME/.local/bin/clawpatrol}"
probe="${PROBE:-dig @8.8.8.8 +time=3 +tries=1 chatgpt.com A +short}"

runtime_dir="${XDG_RUNTIME_DIR:-/tmp/clawpatrol-$(id -u)}"
case "$runtime_dir" in
  */clawpatrol) ;;
  *) runtime_dir="$runtime_dir/clawpatrol" ;;
esac
log="$runtime_dir/daemon.log"

echo "stopping any stale clawpatrol daemon so a fresh one inherits debug env"
pkill -f 'clawpatrol daemon-internal' 2>/dev/null || true
sleep 2
pkill -9 -f 'clawpatrol daemon-internal' 2>/dev/null || true
sleep 1

echo "daemon log: $log"
[ -f "$log" ] && : >"$log" || true

echo "running probe through clawpatrol run (debug env on):"
echo "  $probe"
env -u RES_OPTIONS \
  CLAWPATROL_DEBUG_TSNET=1 \
  TS_DEBUG_NETSTACK=1 \
  "$bin" run -- sh -lc "$probe"
echo "probe_exit=$?"

echo
echo "daemon log tail:"
tail -200 "$log" 2>/dev/null | sed -E 's/(AuthKey|api-token|token|password|secret)[^ ]*/\1=<redacted>/Ig'

echo
echo "filter the relay lines with:"
echo "  grep -aE 'DEBUG-UDP640' $log"
