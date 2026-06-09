package main

// Throwaway diagnostics for the PR #640 tsnet UDP-over-TCP relay investigation.
// Mirrors the #643 debug instrumentation so the two approaches can be compared
// side by side. Strip before the real PR.
//
// Knobs:
//   - [DEBUG-UDP640] / [DEBUG-UDP640-GW] app lines are always on for this
//     branch (one line per UDP datagram / relay flow).
//   - CLAWPATROL_DEBUG_TSNET=1 additionally routes tsnet internals
//     (magicsock / wgengine / netstack) to the log with a prefix on both the
//     daemon and the gateway, and starts a periodic netstack-counter dump.
//     Pair with TS_DEBUG_NETSTACK=1 for the gVisor per-packet "[v2]" trace.

import (
	"log"
	"os"
	"strings"
	"time"

	"tailscale.com/tsnet"
	"tailscale.com/wgengine/netstack"
)

// debugTsnetVerbose reports whether CLAWPATROL_DEBUG_TSNET requests the noisy
// tsnet-internal + netstack-counter diagnostics.
func debugTsnetVerbose() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CLAWPATROL_DEBUG_TSNET"))) {
	case "", "0", "false", "no", "off":
		return false
	}
	return true
}

// tsnetDebugLogf builds the Logf to hand a tsnet.Server. side labels the
// source ("daemon" / "gateway"). quietWhenOff preserves the daemon's prior
// fully-silent behaviour; the gateway passes false so tsnet keeps its default
// log.Printf sink.
func tsnetDebugLogf(side string, quietWhenOff bool) func(string, ...any) {
	if debugTsnetVerbose() {
		prefix := "[DEBUG-UDP640-TS " + side + "] "
		return func(format string, args ...any) {
			log.Printf(prefix+format, args...)
		}
	}
	if quietWhenOff {
		return func(string, ...any) {}
	}
	return nil
}

// debugUDP640Logf logs an app-level diagnostic line for the relay path.
func debugUDP640Logf(format string, args ...any) {
	log.Printf("[DEBUG-UDP640] "+format, args...)
}

// startNetstackStatsDumper periodically logs a netstack's IP / UDP / TCP
// counters as JSON. For the relay path the interesting counters are the TCP
// ones (the relay rides a TCP stream): tcp_segments_sent / valid_segments_received
// moving on both ends means the framed UDP is flowing. No-op unless verbose.
func startNetstackStatsDumper(ns *netstack.Impl, tag string) {
	if ns == nil || !debugTsnetVerbose() {
		return
	}
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for range t.C {
			log.Printf("[DEBUG-UDP640-%s] netstack stats: %s", tag, ns.ExpVar().String())
		}
	}()
}

// startTsnetNetstackStatsDumper extracts a tsnet server's underlying gVisor
// netstack and starts the periodic counter dump. tag distinguishes "GW" from
// "DAEMON". No-op unless verbose.
func startTsnetNetstackStatsDumper(s *tsnet.Server, tag string) {
	if s == nil || !debugTsnetVerbose() {
		return
	}
	sys := s.Sys()
	if sys == nil {
		log.Printf("[DEBUG-UDP640-%s] netstack stats skipped — Sys() nil", tag)
		return
	}
	impl, ok := sys.Netstack.GetOK()
	if !ok {
		log.Printf("[DEBUG-UDP640-%s] netstack stats skipped — netstack not registered", tag)
		return
	}
	ns, ok := impl.(*netstack.Impl)
	if !ok {
		log.Printf("[DEBUG-UDP640-%s] netstack stats skipped — %T not *netstack.Impl", tag, impl)
		return
	}
	startNetstackStatsDumper(ns, tag)
}
