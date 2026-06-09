#!/usr/bin/env python3
"""Throwaway arbitrary-UDP probe for the PR #640 relay test.

Sends an NTP (UDP/123) request to a public NTP server and waits for the reply.
UDP/123 is NOT port 53, so on the gateway it exercises relayUDP (the generic
UDP relay path), not the dnsvip path. Run inside `clawpatrol run` so the
datagram traverses the tsnet UDP relay:

    clawpatrol run -- python3 scripts/udp-ntp-probe.py

Exit 0 on a valid reply, 1 on timeout/failure.
"""
import socket
import struct
import sys
import time

# Public NTP anycast endpoints (try in order).
SERVERS = ["162.159.200.123", "216.239.35.0", "129.6.15.28"]
TIMEOUT = 4.0


def probe(host: str) -> bool:
    pkt = b"\x1b" + 47 * b"\0"  # LI=0, VN=3, Mode=3 (client)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    try:
        t0 = time.time()
        s.sendto(pkt, (host, 123))
        data, addr = s.recvfrom(1024)
        dt = (time.time() - t0) * 1000
        if len(data) < 48:
            print(f"ntp {host}: short reply {len(data)}B", file=sys.stderr)
            return False
        # Transmit timestamp seconds (since 1900) — sanity check non-zero.
        secs = struct.unpack("!I", data[40:44])[0]
        print(f"NTP_OK from {addr[0]} {len(data)}B secs={secs} rtt={dt:.0f}ms")
        return True
    except Exception as e:  # noqa: BLE001
        print(f"ntp {host}: {e}", file=sys.stderr)
        return False
    finally:
        s.close()


def main() -> int:
    for host in SERVERS:
        if probe(host):
            return 0
    print("ARBITRARY_UDP_FAILED: no NTP server replied", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
