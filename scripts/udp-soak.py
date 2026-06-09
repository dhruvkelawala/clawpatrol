#!/usr/bin/env python3
"""Throwaway soak for the PR #640 relay leak check.

Drives many short-lived UDP flows through `clawpatrol run` so each one opens a
fresh relay TCP connection on the gateway (new ephemeral source port => new
flow => new handleTsnetUDPRelayConn goroutine + dnsvip/relayUDP). Watch the
gateway's goroutine count + RSS before / right-after / after-idle to tell a
real leak from normal churn.

    clawpatrol run -- python3 scripts/udp-soak.py [TOTAL] [CONCURRENCY]

Defaults: TOTAL=400 flows, CONCURRENCY=20. Mixes NTP (relayUDP path) and DNS
(dnsvip path).
"""
import concurrent.futures
import socket
import struct
import sys
import time

NTP_SERVERS = ["162.159.200.123", "216.239.35.0"]
# A tiny DNS query for example.com A, txid 0x1234.
DNS_QUERY = bytes.fromhex(
    "1234 0100 0001 0000 0000 0000".replace(" ", "")
) + b"\x07example\x03com\x00" + bytes.fromhex("0001 0001".replace(" ", ""))


def ntp_once(host: str) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    try:
        s.sendto(b"\x1b" + 47 * b"\0", (host, 123))
        d, _ = s.recvfrom(1024)
        return len(d) >= 48
    except Exception:
        return False
    finally:
        s.close()


def dns_once() -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    try:
        s.sendto(DNS_QUERY, ("8.8.8.8", 53))
        d, _ = s.recvfrom(2048)
        return len(d) >= 12
    except Exception:
        return False
    finally:
        s.close()


def one(i: int) -> bool:
    if i % 2 == 0:
        return ntp_once(NTP_SERVERS[i // 2 % len(NTP_SERVERS)])
    return dns_once()


def main() -> int:
    total = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    conc = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    print(f"soak: total={total} concurrency={conc}")
    t0 = time.time()
    ok = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=conc) as ex:
        for n, res in enumerate(ex.map(one, range(total)), 1):
            ok += 1 if res else 0
            if n % 50 == 0:
                print(f"  {n}/{total} ok={ok} ({time.time()-t0:.1f}s)")
    dt = time.time() - t0
    print(f"soak done: ok={ok}/{total} fail={total-ok} in {dt:.1f}s ({total/dt:.0f}/s)")
    return 0 if ok >= total * 0.9 else 1


if __name__ == "__main__":
    sys.exit(main())
