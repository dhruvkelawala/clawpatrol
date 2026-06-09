# PR #643 tsnet exit-node UDP — diagnostics

Throwaway notes for the `debug/tsnet-udp-catchall-diagnostics` branch. Delete
before the real PR.

## What we already know (don't re-test)

- Client `clawpatrol run` UDP DNS → times out.
- Inside `clawpatrol run`, **TCP** through the same exit node works
  (`dig +tcp`, dashboard, boot probe all succeed).
- Client daemon side: the run UDP forwarder gets the packet, dials the
  destination over the tsnet transport, and `Write` succeeds. The reply
  read times out.
- Gateway side: `GetUDPHandlerForFlow` fires with `disposition=dns`, reads
  the 52-byte query, `dnsvip` builds an 83-byte answer, and the writeback
  (`Conn.Write` and `WriteTo(resp, from)`) both report success.

So both the request path and the gateway's answer are fine. **The missing
piece is the UDP return packet getting from the gateway back to the client.**
TCP returns work; UDP returns don't.

## Run the two scripts (one gateway, one client)

Gateway (rebuild + restart with verbose tsnet/netstack logging):

```bash
cd ~/clawpatrol
git fetch https://github.com/dhruvkelawala/clawpatrol debug/tsnet-udp-catchall-diagnostics
git checkout -B debug/tsnet-udp-catchall-diagnostics FETCH_HEAD
./scripts/debug-tsnet-udp-gateway.sh
```

Client (stop stale daemon, probe with verbose logging):

```bash
./scripts/debug-tsnet-udp-client.sh
```

Then collect:

```bash
# gateway
grep -E 'DEBUG-UDP643|DEBUG-UDP643-GW|DEBUG-UDP643-TS' /tmp/clawpatrol.log
# client
grep -E 'DEBUG-UDP643|DEBUG-UDP643-TS' "${XDG_RUNTIME_DIR:-/tmp/clawpatrol-$(id -u)}/clawpatrol/daemon.log"
```

## What each new signal tells us

| Signal | Where | Meaning |
| --- | --- | --- |
| `dial ... ok type=*gonet.UDPConn` | client | Confirms the dial went through tsnet netstack (exit-node path), not a system dial. A non-netstack type means `UseNetstackForIP`/exit-node routing isn't engaging. |
| `waiting for reply ...` then `read response ... i/o timeout` | client | Client never received the reply datagram. |
| `read response bytes=N` | client | Reply *did* arrive — problem is elsewhere (e.g. TUN writeback). |
| `netstack stats (after-dns-writeback ...)` | gateway | Compare to `before-...`. Watch `counter_ip_packets_sent`, `counter_ip_outgoing_packet_errors`, `counter_ip_forward_*`, `counter_dropped_packets`. A bump in an error/dropped counter on the write = the gateway stack refused to emit the reply (e.g. no route for source 8.8.8.8). A bump in `packets_sent` with no error = the reply left the gateway and the loss is on the wire/client. |
| `[DEBUG-UDP643-TS gateway] ... wrote UDP packet` / filter drop | gateway | gVisor `[v2]` trace (needs `TS_DEBUG_NETSTACK=1`, set by the script). Shows packet-level send. |
| `[DEBUG-UDP643-TS daemon] ...` filter/drop lines | client | Client-side magicsock/netstack view. A "packet dropped" / filter line for `src=8.8.8.8` = the client's Tailscale packet filter is rejecting the return datagram → **ACL problem**. |

## Decision table

1. **Gateway `after-...` stats show an outgoing error / drop delta** →
   gateway can't emit the reply. Root cause is the writeback endpoint /
   source-address routing in netstack, not the ACL. Fix is on the gateway
   write path (how we send the answer back on the intercepted flow).

2. **Gateway `packets_sent` increments, no error; client logs a filter /
   "packet dropped" line for `src=8.8.8.8`** → the reply reaches the client
   but its Tailscale packet filter drops it. **This is the ACL.** UDP return
   from the exit node isn't permitted while TCP (stateful) is.

3. **Gateway `packets_sent` increments, no error; client shows no inbound
   packet at all** → lost on the wire between the two nodes. Note the path:
   `tailscale ping 100.64.91.47` earlier said `via DERP(lhr)`, i.e. relayed,
   not a direct connection. Worth re-checking whether a direct path changes
   anything.

## ACL checks (for case 2)

Exit-node return traffic is governed by the tailnet ACL. TCP works because
Tailscale's filter is stateful for TCP; a UDP-only gap shows up as "request
in, reply dropped". Check, in the Tailscale admin console (Access Controls):

- The grant that lets the agent node use the gateway as an exit node. A
  `proto` restriction (e.g. `"proto": "tcp"`) on the relevant `acls`/`grants`
  rule will pass TCP and drop UDP.
- `autogroup:internet` rules — exit-node destinations resolve to
  `autogroup:internet`; confirm UDP isn't excluded.
- The simplest confirmation: temporarily widen the rule to all protocols
  (remove any `proto`) and re-run the client probe.

CLI cross-checks from the gateway host:

```bash
# Inbound filter the control plane pushed to THIS node (gateway):
tailscale debug netmap 2>/dev/null | grep -iA3 -E 'packetFilter|filterRule' | head -40
# Self/exit-node prefs:
tailscale status --json | jq '.Self.Capabilities, .ExitNodeStatus'
```

And from the client host:

```bash
# Does the client consider the gateway an approved exit node?
tailscale status --json | jq '.Peer[] | select(.ExitNode==true)'
```
