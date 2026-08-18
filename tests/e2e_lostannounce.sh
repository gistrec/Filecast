#!/usr/bin/env bash
#
# Lost-ANNOUNCE end-to-end test: a proxy drops the sender's initial ANNOUNCE
# burst (plus the pre-FINISH repeat) while letting all DATA through. The
# receiver must warn about un-announced DATA, latch from a later re-broadcast,
# recover every missed part via RESEND, and finish verified.
#
# Run via:
#   ctest --test-dir build --output-on-failure
#
# Or directly:
#   BINARY=build/filecast bash tests/e2e_lostannounce.sh
#
set -euo pipefail

BINARY="${BINARY:-./filecast}"
PYTHON="${PYTHON:-python3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$BINARY" ]; then
    echo "Error: $BINARY not found or not executable. Build first." >&2
    exit 1
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "Error: $PYTHON not found in PATH; the announce-drop proxy needs Python 3." >&2
    exit 1
fi

WORKDIR="$(mktemp -d -t fb-e2e-lostannounce.XXXXXX)"
PROXY_PID=""
RECV_PID=""

cleanup() {
    [ -n "$RECV_PID"  ] && kill "$RECV_PID"  2>/dev/null || true
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Own 339xx port block so ctest -j doesn't collide with the other e2e tests.
# Topology (all on 127.0.0.1):
#   sender bind = 33902, sender target -> 33903 (proxy in)
#   proxy: 33903 -> 33901 (drops the first ANNOUNCEs, forwards the rest)
#   receiver bind = 33901, receiver target -> 33902 (RESENDs go straight back)
RECV_BIND=33901
SEND_BIND=33902
PROXY_IN=33903

# 3 burst ANNOUNCEs + the pre-FINISH repeat: drop all 4 so the receiver can
# only latch from a resend-phase re-broadcast.
DROP_COUNT=4

src="$WORKDIR/src.bin"
dst="$WORKDIR/out.bin"
recv_log="$WORKDIR/recv.log"
send_log="$WORKDIR/send.log"
proxy_log="$WORKDIR/proxy.log"

echo "==> generating 200 KiB file"
dd if=/dev/urandom of="$src" bs=1024 count=200 status=none

echo "==> starting announce-drop proxy ($PROXY_IN -> $RECV_BIND, dropping first $DROP_COUNT ANNOUNCEs)"
"$PYTHON" "$SCRIPT_DIR/announce_drop_proxy.py" \
    "$PROXY_IN" 127.0.0.1 "$RECV_BIND" "$DROP_COUNT" \
    > "$proxy_log" 2>&1 &
PROXY_PID=$!
sleep 0.5  # let the proxy bind

echo "==> starting receiver (bind=$RECV_BIND, target=$SEND_BIND)"
"$BINARY" receive "$dst" --to 127.0.0.1 --verbose \
          --bind-port "$RECV_BIND" --port "$SEND_BIND" \
          --ttl 15 --delay-ms 0 \
    > "$recv_log" 2>&1 &
RECV_PID=$!
sleep 1

echo "==> starting sender (bind=$SEND_BIND, target=$PROXY_IN)"
if ! "$BINARY" send "$src" --to 127.0.0.1 \
               --bind-port "$SEND_BIND" --port "$PROXY_IN" \
               --ttl 10 --delay-ms 0 \
        > "$send_log" 2>&1; then
    echo "FAIL: sender exited non-zero"
    echo "--- sender log (tail):"; tail -30 "$send_log"
    echo "--- proxy log (tail):";  tail -30 "$proxy_log"
    exit 1
fi

if ! wait "$RECV_PID"; then
    echo "FAIL: receiver exited non-zero (stranded by the lost ANNOUNCE burst?)"
    echo "--- receiver log (tail):"; tail -30 "$recv_log"
    echo "--- proxy log (tail):";    tail -30 "$proxy_log"
    exit 1
fi
RECV_PID=""

kill "$PROXY_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""

if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    echo "FAIL: received file missing or does not match source"
    echo "--- receiver log (tail):"; tail -30 "$recv_log"
    exit 1
fi
if ! grep -q "sha256 verified" "$recv_log"; then
    echo "FAIL: receiver did not verify the transfer"
    tail -20 "$recv_log"
    exit 1
fi

# Proof the scenario was exercised, not just missed by timing.
if ! grep -q "dropped ANNOUNCE $DROP_COUNT/$DROP_COUNT" "$proxy_log"; then
    echo "FAIL: proxy did not drop $DROP_COUNT ANNOUNCEs (scenario not exercised)"
    tail -20 "$proxy_log"
    exit 1
fi
if ! grep -q "receiving data without an announcement" "$recv_log"; then
    echo "FAIL: receiver never warned about DATA arriving without an ANNOUNCE"
    tail -20 "$recv_log"
    exit 1
fi
resend_count=$(grep -c "Request part of file with index" "$recv_log" || true)
if [ "$resend_count" -eq 0 ]; then
    echo "FAIL: file matched but the RESEND recovery path was never exercised"
    tail -20 "$recv_log"
    exit 1
fi

echo "PASS: lost ANNOUNCE burst survived — receiver warned, latched late, recovered $resend_count part request(s), sha256 verified"
echo
echo "Lost-ANNOUNCE E2E test passed."
