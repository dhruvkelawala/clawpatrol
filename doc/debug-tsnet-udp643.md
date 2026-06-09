# PR #643 tsnet exit-node UDP — diagnostics

Throwaway notes for the `debug/tsnet-udp-catchall-diagnostics` branch. Delete
before the real PR.

## ROOT CAUSE (proven 2026-06-09)

The gateway side of #643 works. The failure is **client-side**, in Tailscale's
own inbound packet filter, and #643's gateway `GetUDPHandlerForFlow` cannot fix
it.

Evidence chain:

1. Gateway emits the DNS reply cleanly. Netstack counter delta across the
   writeback: `counter_udp_packets_sent 0→1`, `counter_ip_packets_sent +1`,
   every error/drop/forward counter stays `0`.
2. Client never receives it: daemon netstack `counter_udp_packets_received: 0`
   (and `counter_udp_packets_sent: 1` for the query that went out).
3. Control under identical client filter state (`statefulFiltering=false`,
   `netmap packet filter: 0 filters`): **TCP** DNS `@8.8.8.8 +tcp` succeeds,
   **UDP** DNS `@8.8.8.8` times out.

Why: `tailscale.com/wgengine/filter`.`runIn4`:

```go
case ipproto.TCP:
    if !q.IsTCPSyn() { return Accept, "tcp non-syn" }   // returns always allowed
    ...
case ipproto.UDP, ipproto.SCTP:
    t := flowtrack.MakeTuple(q.IPProto, q.Src, q.Dst)
    if _, ok := f.state.lru.Get(t); ok { return Accept, "cached" } // needs recorded outbound flow
    if f.matches4.match(...) { return Accept, "ok" }               // or an ACL rule
    ... // else noVerdict → dropped
```

Inbound UDP is accepted only if the reverse flow tuple was recorded on the
outbound path (`runOut` → `f.state.lru.Add`) or an ACL rule matches. The
outbound flow is **never recorded** for a tsnet `clawpatrol run` client,
because netstack-originated peer traffic is emitted via
`netstack.Impl` → `tundev.InjectOutboundPacketBuffer` (netstack.go ~L1050),
and the injected path **bypasses the filter** (tstun `wrap.go` L1082:
"injectedRead handles injected reads, which bypass filters"). So `RunOut`
never runs, the LRU never learns the flow, and with `0 filters` there is no
ACL fallback. TCP is unaffected because of the unconditional `tcp non-syn`
allowance.

Consequences:

- A pure gateway-side native-UDP catch-all (#643) cannot deliver UDP replies
  to tsnet exit-node clients; the reply is dropped on the client before the
  app sees it.
- This is exactly why the **DNS-over-TCP bridge** and the **#640
  UDP-over-TCP relay** work: they ride a TCP connection, whose returns the
  client filter always accepts.
- A real (non-tsnet) Tailscale exit-node client doesn't hit this: its
  outbound UDP traverses the kernel TUN → tstun Read path → `RunOut`, which
  records the flow, so returns are accepted. The tsnet inject path is the gap.

Fix options (in order of robustness for clawpatrol):

1. Keep carrying UDP over TCP (DNS-over-TCP / #640 relay). Sidesteps the
   client filter entirely. Proven working.
2. Upstream tailscale change so tsnet netstack outbound records the flow (or
   exposes a hook to allow inbound returns). Out of clawpatrol's tree.
3. An ACL rule permitting the return is **not** generally viable: the reply's
   src is an arbitrary internet IP (8.8.8.8, …), which Tailscale ACL `src`
   sets don't express.

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
