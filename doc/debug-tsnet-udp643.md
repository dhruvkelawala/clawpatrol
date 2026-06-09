# tsnet exit-node UDP — investigation (PR #643 vs PR #640)

Working notes for the throwaway debug branches. Keep this file until both PRs
are resolved; it is the source of truth for the eventual PR comments.

- PR #643 — `gateway: handle tsnet exit-node UDP via GetUDPHandlerForFlow`
  (upstream branch `denoland/clawpatrol:tsnet-udp-catchall`).
  Debug branch: `fork/debug/tsnet-udp-catchall-diagnostics`.
- PR #640 — `feat(tsnet): add Linux UDP relay` (UDP-over-TCP relay,
  `@dhruvkelawala`). Branch: `fork/feature/tsnet-udp-relay`.
  Debug branch: `fork/debug/tsnet-udp-relay-diagnostics` (this investigation).

---

## TL;DR (paste-ready conclusion)

The tsnet UDP failure is **specific to #643's native-UDP design**, and it is a
**client-side** problem that no amount of gateway code can fix:

> On a tsnet `clawpatrol run` client, the agent's outbound UDP is emitted by
> the embedded netstack via `tundev.InjectOutboundPacketBuffer`, which
> **bypasses the wgengine packet filter's outbound path** (`RunOut`). Because
> `RunOut` never runs, the filter never records the UDP flow tuple in its LRU.
> When the gateway's UDP reply comes back (`src=8.8.8.8:53`), the client's
> **inbound** filter (`runIn`) finds no cached flow and no matching ACL rule
> (the node has `0 filters`), so it drops the datagram before it reaches the
> app. TCP is unaffected because `runIn` accepts any inbound non-SYN TCP
> unconditionally (`"tcp non-syn"`).

Therefore:

- **#643 (native UDP through the exit node) cannot work** for tsnet clients —
  proven below with packet counters on both ends.
- **#640 (UDP framed inside a TCP relay) sidesteps the exact filter rule**,
  because the reply rides a TCP stream whose inbound segments the client filter
  always accepts. This is the same reason the earlier DNS-over-TCP bridge
  passed its live canary.
- A real (non-tsnet, kernel-TUN) Tailscale exit-node client does not hit this,
  because its outbound UDP traverses the TUN read path → `RunOut` → the flow is
  recorded → returns are accepted. The tsnet inject path is the gap.

Status of the #640 confirmation: see "PR #640 investigation" near the bottom.

---

## ROOT CAUSE (proven 2026-06-09)

### Evidence chain

1. **Gateway emits the reply cleanly.** Netstack counter delta across the
   writeback (gateway debug binary, lines around 09:06:31Z):
   `counter_udp_packets_sent 0→1`, `counter_ip_packets_sent +1`, and every
   error/drop/forward counter (`counter_dropped_packets`,
   `counter_ip_outgoing_packet_errors`, `counter_ip_forward_*`,
   `counter_udp_packet_send_errors`) stays `0`.
2. **Client never receives it.** Daemon netstack counters after the probe:
   `counter_udp_packets_received: 0`, `counter_udp_packets_sent: 1` (the query
   that went out), `counter_dropped_packets: 0`.
3. **Control under identical client state** (`statefulFiltering=false`,
   `netmap packet filter: 0 filters`): TCP DNS `@8.8.8.8 +tcp` **succeeds**
   (`104.18.32.47`), UDP DNS `@8.8.8.8` **times out**. Same daemon, same
   filter, only the L4 protocol differs.

### Mechanism (tailscale source, v1.96.5)

`tailscale.com/wgengine/filter`.`runIn4` / `runIn6`:

```go
case ipproto.TCP:
    if !q.IsTCPSyn() { return Accept, "tcp non-syn" }   // returns ALWAYS allowed
    if f.matches4.match(q, f.srcIPHasCap) { return Accept, "tcp ok" }
case ipproto.UDP, ipproto.SCTP:
    t := flowtrack.MakeTuple(q.IPProto, q.Src, q.Dst)
    if _, ok := f.state.lru.Get(t); ok { return Accept, "cached" } // needs recorded outbound flow
    if f.matches4.match(q, f.srcIPHasCap) { return Accept, "ok" }  // or an ACL rule
    // else falls through to: return noVerdict, "no rules matched"  → dropped
```

`runOut` is what populates that LRU (note src/dst reversed so the return
matches):

```go
func (f *Filter) runOut(q *packet.Parsed) (r Response, why string) {
    switch q.IPProto {
    case ipproto.UDP, ipproto.SCTP:
        tuple := flowtrack.MakeTuple(q.IPProto, q.Dst, q.Src) // reversed
        f.state.lru.Add(tuple, struct{}{})
    }
    return Accept, "ok out"
}
```

But on a tsnet client the agent's outbound UDP never reaches `runOut`:

- `wgengine/netstack/netstack.go` (~L1050) sends netstack-originated
  peer-bound packets via `ns.tundev.InjectOutboundPacketBuffer(pkt)`.
- `net/tstun/wrap.go` L1082: *"injectedRead handles injected reads, which
  bypass filters."* The normal `Read` path calls
  `filterPacketOutboundToWireGuard` → `filt.RunOut(...)`; the injected path
  does not.

So: outbound UDP → injected → no `RunOut` → no LRU entry → inbound reply →
`runIn` LRU miss → `0 filters` ACL miss → **dropped**. TCP escapes via the
`"tcp non-syn"` shortcut.

### Why an ACL change does not fix it

The dropped reply's source is an arbitrary internet IP (8.8.8.8, 1.1.1.1, …).
Tailscale ACL `src` sets express tailnet identities, not arbitrary public IPs,
so there is no general grant that admits the return. (Confirmed the agent node
shows `0 filters` and `statefulFiltering=false`.)

### Fix options (most robust first)

1. **Carry UDP over TCP** (DNS-over-TCP bridge / #640 relay). The reply rides a
   TCP stream the client filter always accepts. Proven working for DNS via the
   earlier live canary; #640 generalizes it to arbitrary UDP.
2. **Upstream tailscale change** so tsnet netstack outbound records the flow
   (or a tsnet hook to admit inbound returns). Out of clawpatrol's tree.
3. ACL rule — **not viable** (see above).

---

## #643 vs #640 — why one fails and the other should not

| | #643 (`GetUDPHandlerForFlow`) | #640 (UDP-over-TCP relay) |
| --- | --- | --- |
| Client data path | `transport.Dial(ctx,"udp",dst)` → tsnet netstack → **native UDP** through exit node (debug: `type=*gonet.UDPConn`) | `dialTsnetUDPRelay` → **TCP** to `gateway:45353`; UDP datagrams framed inside the TCP stream |
| Reply L4 on the wire to the client | native UDP datagram `src=dst:port` | TCP segments `src=gateway:45353` |
| Client inbound filter verdict | UDP: LRU miss + `0 filters` → **drop** | TCP non-SYN → **accept** (`"tcp non-syn"`) |
| Result | reply dropped on client → timeout (**proven**) | reply delivered (**expected**; confirm live) |
| Gateway code quality | clean, but insufficient alone | heavier (framing, `:45353`, auth, HOL) but functional |
| Extra requirement | none (and still fails) | gateway ACL must admit client → `gateway:45353` TCP |

Bottom line for the PRs: #643's catch-all is a correct and useful gateway
primitive, but **not sufficient on its own** for tsnet `clawpatrol run`
clients. The transport for UDP must be TCP-framed (or tailscale must change how
tsnet netstack outbound is filtered).

---

## Reproduction — #643 debug branch

Gateway (rebuild + restart with verbose tsnet/netstack logging):

```bash
cd ~/clawpatrol
git fetch https://github.com/dhruvkelawala/clawpatrol debug/tsnet-udp-catchall-diagnostics
git checkout -B debug/tsnet-udp-catchall-diagnostics FETCH_HEAD
./scripts/debug-tsnet-udp-gateway.sh        # exports TS_DEBUG_NETSTACK=1 CLAWPATROL_DEBUG_TSNET=1
```

Client (stop stale daemon, probe with verbose logging):

```bash
./scripts/debug-tsnet-udp-client.sh         # default probe: dig @8.8.8.8 ... chatgpt.com
```

Collect:

```bash
grep -aE 'DEBUG-UDP643' /tmp/clawpatrol.log                                   # gateway
grep -aE 'DEBUG-UDP643' "${XDG_RUNTIME_DIR:-/tmp/clawpatrol-$(id -u)}/clawpatrol/daemon.log"  # client
```

Key signals: gateway `udp_packets_sent` ticks up with no error; client
`udp_packets_received` stays 0; TCP control (`dig +tcp`) succeeds.

### Decision table (kept for reference)

1. Gateway after-writeback stats show an outgoing error/drop delta → gateway
   emit problem (NOT our case; counters were clean).
2. Gateway `packets_sent` up, no error; client never receives (`udp_packets_received: 0`)
   → dropped on the client by the packet filter (**our case**), or lost on the
   wire. Distinguished from wire-loss by: deterministic 100% failure + TCP works
   on the same path + filter source shows UDP-without-state is dropped.
3. Client `read response bytes=N` would mean the reply arrived and the bug is
   in TUN writeback (NOT our case).

---

## PR #640 investigation (in progress)

Goal: confirm that the UDP-over-TCP relay actually delivers UDP both for DNS
and arbitrary (non-DNS) UDP through `clawpatrol run`, on the same tailnet where
#643 fails.

Debug branch: `fork/debug/tsnet-udp-relay-diagnostics` (based on
`feature/tsnet-udp-relay`).

Scripts:

- `scripts/debug-tsnet-udp-gateway.sh` (shared) — build/install/restart the
  gateway with verbose logging.
- `scripts/debug-tsnet-udp-client.sh` (shared) — stop stale daemon, run a probe
  with debug env, tail the daemon log. Override the probe with `PROBE=...`.

Test matrix to run once both ends are on the #640 debug binary:

1. UDP DNS: `dig @8.8.8.8 +time=3 +tries=1 chatgpt.com A +short` → expect an answer.
2. Arbitrary UDP echo: a non-DNS UDP round-trip through `clawpatrol run` →
   expect the echo back.
3. TCP control still works.

Expected (per the analysis above): all succeed, because the relay carries UDP
inside a TCP connection. Record the actual results here:

- [ ] UDP DNS through #640 relay: _result_
- [ ] Arbitrary UDP echo through #640 relay: _result_
- [ ] Relay accept/auth confirmed on gateway logs: _result_
- [ ] Gateway ACL admits client → `gateway:45353` TCP: _result_

---

## Cleanup / binary provenance

- Local clean #643 binary sha256: `8ba9b0cd0b39e065ef631d5092322e6d5688db2c0f5436228fff6866019805d9`.
- Gateway pre-#643 backup: `/usr/local/bin/clawpatrol.backup-before-tsnet-udp-catchall-20260609T075759Z`.
- Both debug branches are throwaway: the `[DEBUG-UDP643*]` instrumentation,
  `scripts/debug-tsnet-udp-*.sh`, and this doc must be removed before any real
  PR.
