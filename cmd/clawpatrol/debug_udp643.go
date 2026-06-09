package main

// Throwaway diagnostics for the PR #643 tsnet exit-node UDP investigation.
// Everything here is gated so it can be merged onto the debug branch without
// touching normal behaviour, and stripped before the real PR.
//
// Two knobs:
//
//   - The app-level [DEBUG-UDP643] / [DEBUG-UDP643-GW] lines are always on
//     for this branch (low volume; one line per UDP datagram / flow).
//   - CLAWPATROL_DEBUG_TSNET=1 additionally:
//       * routes tsnet's internal logs (magicsock, wgengine, netstack) to
//         our log with a prefix, on BOTH the daemon and the gateway, and
//       * starts a periodic gateway netstack-counter dump.
//     Pair it with TS_DEBUG_NETSTACK=1 (read by gVisor at process start) to
//     get the per-packet "[v2]" netstack trace as well.

import (
	"log"
	"os"
	"strings"
	"time"

	"tailscale.com/wgengine/netstack"
)

// debugTsnetVerbose reports whether CLAWPATROL_DEBUG_TSNET requests the
// noisy tsnet-internal + netstack-counter diagnostics.
func debugTsnetVerbose() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CLAWPATROL_DEBUG_TSNET"))) {
	case "", "0", "false", "no", "off":
		return false
	}
	return true
}

// tsnetDebugLogf builds the Logf to hand a tsnet.Server.
//
// side labels the source ("daemon" / "gateway"). quietWhenOff preserves the
// daemon's prior behaviour (fully silent) when verbose logging is disabled;
// the gateway passes false so tsnet keeps its default log.Printf sink.
func tsnetDebugLogf(side string, quietWhenOff bool) func(string, ...any) {
	if debugTsnetVerbose() {
		prefix := "[DEBUG-UDP643-TS " + side + "] "
		return func(format string, args ...any) {
			log.Printf(prefix+format, args...)
		}
	}
	if quietWhenOff {
		return func(string, ...any) {}
	}
	return nil
}

// startNetstackStatsDumper periodically logs the gateway netstack's IP /
// UDP / forwarding counters as JSON. The forwarding + outgoing-error
// counters are the tell for a dropped UDP return packet (src=8.8.8.8 with
// no route back out of the stack). No-op unless verbose logging is on.
func startNetstackStatsDumper(ns *netstack.Impl) {
	if ns == nil || !debugTsnetVerbose() {
		return
	}
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for range t.C {
			log.Printf("[DEBUG-UDP643-GW] netstack stats: %s", ns.ExpVar().String())
		}
	}()
}

// logNetstackStats dumps a one-shot counter snapshot tagged with a label,
// for before/after deltas around a single DNS flow.
func (g *Gateway) logNetstackStats(tag string) {
	if g == nil || g.tsNetstack == nil {
		return
	}
	log.Printf("[DEBUG-UDP643-GW] netstack stats (%s): %s", tag, g.tsNetstack.ExpVar().String())
}
