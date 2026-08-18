#!/usr/bin/env python3
#
# One-directional UDP proxy for the lost-ANNOUNCE test (tests/e2e_lostannounce.sh).
# Listens on IN and forwards every datagram to OUT, except it drops the first
# <count> ANNOUNCE (type=1) packets. This models the cold-path failure from
# issue #42: the sender's initial ANNOUNCE burst is lost while every DATA packet
# still arrives, so the receiver can only latch from a later re-broadcast and
# must then recover the parts it missed through RESENDs.
#
#   announce_drop_proxy.py <in_port> <out_host> <out_port> <count>
#
# The receiver's RESENDs go straight to the sender (not through this proxy), so
# recovery traffic is unaffected.

import socket
import sys

MAGIC = b"FCST"
TYPE_ANNOUNCE = 1
HEADER_SIZE = 10  # magic(4) + version(1) + type(1) + session(4)


def main(argv):
    if len(argv) < 5:
        print("usage: announce_drop_proxy.py <in_port> <out_host> <out_port> <count>",
              file=sys.stderr)
        return 2
    in_port, out_host, out_port, count = int(argv[1]), argv[2], int(argv[3]), int(argv[4])

    r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    r.bind(("127.0.0.1", in_port))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    dropped = 0
    while True:
        data, _ = r.recvfrom(65535)
        if (dropped < count and len(data) >= HEADER_SIZE
                and data[:4] == MAGIC and data[5] == TYPE_ANNOUNCE):
            dropped += 1
            print(f"dropped ANNOUNCE {dropped}/{count}", file=sys.stderr, flush=True)
            continue
        s.sendto(data, (out_host, out_port))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        pass  # the test kills us; exit quietly
