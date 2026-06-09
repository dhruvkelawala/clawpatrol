# tsnet exit-node UDP — investigation (PR #643 vs PR #640)

Working notes for the throwaway debug branches. Keep this file until both PRs
are resolved; it is the source of truth for the eventual PR comments.

- PR #643 — `gateway: handle tsnet exit-node UDP via GetUDPHandlerForFlow`
  (upstream branch `denoland/clawpatrol:tsnet-udp-catchall`).
  Debug branch: `fork/debug/tsnet-udp-catchall-diagnostics`.
- PR #640 — `feat(tsnet): add Linux UDP relay` (UDP-over-TCP relay,
  `@dhruvkelawala`). Branch: `fork/feature/tsnet-udp-relay`.
  Debug branch: `fork/debug/tsnet-udp-relay-diagnostics`.

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
- **#640 (UDP framed inside a TCP relay) works** — CONFIRMED live for both DNS
  and arbitrary (NTP) UDP. The reply rides a TCP stream whose inbound segments
  the client filter always accepts.
- A real (non-tsnet, kernel-TUN) Tailscale exit-node client does not hit this,
  because its outbound UDP traverses the TUN read path → `RunOut` → the flow is
  recorded → returns are accepted. The tsnet inject path is the gap.

---

## ROOT CAUSE (proven 2026-06-09)

### Evidence chain (#643 native UDP)

1. **Gateway emits the reply cleanly.** Netstack counter delta across the
   writeback (gateway debug binary, ~09:06:31Z):
   `counter_udp_packets_sent 0→1`, `counter_ip_packets_sent +1`, and every
   error/drop/forward counter stays `0`.
2. **Client never receives it.** Daemon netstack counters after the probe:
   `counter_udp_packets_received: 0`, `counter_udp_packets_sent: 1`,
   `counter_dropped_packets: 0`.
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
    // else: return noVerdict, "no rules matched"  → dropped
```

`runOut` populates that LRU (src/dst reversed so the return matches), but on a
tsnet client the agent's outbound UDP never reaches `runOut`:

- `wgengine/netstack/netstack.go` (~L1050) sends netstack-originated
  peer-bound packets via `ns.tundev.InjectOutboundPacketBuffer(pkt)`.
- `net/tstun/wrap.go` L1082: *"injectedRead handles injected reads, which
  bypass filters."* The normal `Read` path calls
  `filterPacketOutboundToWireGuard` → `RunOut`; the injected path does not.

So: outbound UDP → injected → no `RunOut` → no LRU entry → inbound reply →
`runIn` LRU miss → `0 filters` ACL miss → **dropped**. TCP escapes via the
`"tcp non-syn"` shortcut.

### Why an ACL change does not fix it

The dropped reply's source is an arbitrary internet IP (8.8.8.8, 1.1.1.1, …).
Tailscale ACL `src` sets express tailnet identities, not arbitrary public IPs,
so there is no general grant that admits the return.

---

## #643 vs #640 — why one fails and the other works

| | #643 (`GetUDPHandlerForFlow`) | #640 (UDP-over-TCP relay) |
| --- | --- | --- |
| Client data path | `transport.Dial(ctx,"udp",dst)` → tsnet netstack → **native UDP** (debug: `type=*gonet.UDPConn`) | `transport.Dial(ctx,"udp",dst)` → `dialTsnetUDPRelay` → **TCP** to `gateway:45353`; UDP framed inside (debug: `type=*main.udpRelayStreamConn`) |
| Reply L4 reaching the client | native UDP datagram `src=dst:port` | TCP segments `src=gateway:45353` |
| Client inbound filter verdict | UDP: LRU miss + `0 filters` → **drop** | TCP non-SYN → **accept** (`"tcp non-syn"`) |
| Result | reply dropped on client → timeout (**proven**) | reply delivered (**confirmed live**) |
| Extra requirement | none (still fails) | gateway ACL must admit client → `gateway:45353` TCP (confirmed open) |

Bottom line: #643's catch-all is a correct, useful gateway primitive but **not
sufficient on its own** for tsnet `clawpatrol run` clients. UDP must be
TCP-framed (#640), or tailscale must change how tsnet netstack outbound is
filtered.

---

## PR #640 investigation — RESULTS (confirmed 2026-06-09)

Both ends on the #640 debug binary (`fork/debug/tsnet-udp-relay-diagnostics`),
gateway run lean (no `TS_DEBUG_NETSTACK`).

- [x] **UDP DNS through #640 relay**: `dig @8.8.8.8 chatgpt.com` → `104.18.32.47`,
  `172.64.155.209` (`rc=0`). Client log: `write payload=52 (udp-relay) ok` →
  `read reply (udp-relay) bytes=83`.
- [x] **Arbitrary UDP echo through #640 relay** (NTP/123, exercises `relayUDP`,
  not dnsvip): `NTP_OK from 162.159.200.123 48B rtt=4ms`. Client log:
  `write payload=48` → `read reply bytes=48`.
- [x] **Relay handshake/auth**: client `relay tcp connected gateway=…:45353` →
  `relay hello sent … handshake ok`; gateway did not reject (no EOF), served
  the flow, framed reply returned.
- [x] **Gateway ACL admits client → `gateway:45353` TCP**: relay port open and
  connect succeeded.

Conclusion: **#640 delivers UDP (DNS and arbitrary) end-to-end through
`clawpatrol run` on the same tailnet where #643 times out.** This is the
expected result: the relay rides TCP, which the client filter always accepts.

### Stability / leak — soak result (no leak)

Lean-gateway soak: 2 bursts, 2300 relay flows total (NTP + DNS mix, up to 40
concurrent), 2295/2300 ok (5 transient NTP timeouts), ~105–155 flows/s.

Gateway goroutines (pprof) vs RSS:

| time | event | goroutines | rss |
| --- | --- | --- | --- |
| baseline | idle | 85 | 67 MB |
| burst-1 peak (800) | load | 1677 | 97 MB |
| burst-1 settled | idle | 87 | 99 MB |
| burst-2 peak (1500) | load | 3067 | 135 MB |
| burst-2 settled | idle | 88 | 138 MB |

Forced-GC heap (idle, after both bursts): `HeapAlloc≈41.7MB`,
`HeapInuse≈46.9MB`, `HeapObjects=40305`, `HeapSys≈201.9MB`,
`HeapReleased≈4.1MB`.

Verdict: **no goroutine/connection leak and no heap leak.** Goroutines return
to baseline after every burst (so every `handleTsnetUDPRelayConn` /
`dnsvip.ServeUDP` / `relayUDP` flow is reclaimed), and after a forced GC the
live heap is back to a normal working set (~42 MB / 40k objects). The elevated
RSS/`HeapSys` is Go runtime arena retention (low `HeapReleased` = the scavenger
hasn't returned the peak-burst arenas yet; it does so lazily / under pressure),
not a leak.

The earlier mid-test crashes happened only under the verbose gateway
(`TS_DEBUG_NETSTACK=1`) — the gVisor per-packet `[v2]` firehose amplifying
memory/log volume — not under the lean run. Run the gateway lean; reserve
`DEBUG_VERBOSE=1` for short windows.

---

## Reproduction

### #643 debug branch

```bash
cd ~/clawpatrol
git fetch https://github.com/dhruvkelawala/clawpatrol debug/tsnet-udp-catchall-diagnostics
git checkout -B debug/tsnet-udp-catchall-diagnostics FETCH_HEAD
./scripts/debug-tsnet-udp-gateway.sh        # sets TS_DEBUG_NETSTACK + CLAWPATROL_DEBUG_TSNET
./scripts/debug-tsnet-udp-client.sh
```

Signals: gateway `udp_packets_sent` ticks up with no error; client
`udp_packets_received` stays 0; TCP control (`dig +tcp`) succeeds.

### #640 debug branch

```bash
cd ~/clawpatrol
git fetch https://github.com/dhruvkelawala/clawpatrol debug/tsnet-udp-relay-diagnostics
git checkout -B debug/tsnet-udp-relay-diagnostics FETCH_HEAD
./scripts/debug-tsnet-udp-gateway.sh        # lean; DEBUG_VERBOSE=1 to opt into tsnet logs
# client (DNS):
clawpatrol run -- sh -lc 'dig @8.8.8.8 +time=5 +tries=1 chatgpt.com A +short'
# client (arbitrary UDP / NTP → relayUDP path):
clawpatrol run -- python3 scripts/udp-ntp-probe.py
```

Relay trace lines are always on:
`grep -aE 'DEBUG-UDP640|udp-relay' /tmp/clawpatrol.log` (gateway),
`grep -aE 'DEBUG-UDP640' "$XDG_RUNTIME_DIR/clawpatrol/daemon.log"` (client).

---

## Cleanup / binary provenance

- Local clean #643 binary sha256: `8ba9b0cd0b39e065ef631d5092322e6d5688db2c0f5436228fff6866019805d9`.
- Gateway pre-#643 backup: `/usr/local/bin/clawpatrol.backup-before-tsnet-udp-catchall-20260609T075759Z`.
- Both debug branches are throwaway: the `[DEBUG-UDP64x]` instrumentation,
  `scripts/debug-tsnet-udp-*.sh`, `scripts/udp-ntp-probe.py`, and this doc must
  be removed before any real PR.
