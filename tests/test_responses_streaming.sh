#!/bin/bash
# Integration test: /v1/responses streaming emits deltas incrementally.
#
# Regression for the bug surfaced by Local LLM Bench run #6 where
# /v1/responses with stream=true would generate the full output then
# emit a single response.output_text.delta with the entire text. That
# made TTFT == total generation time and produced absurd decode tok/s
# (e.g. 1.7M tok/s) because the bench measured deltas-per-second.
#
# Real streaming should emit many delta events spaced over the decode
# window — mirroring what /v1/chat/completions and /v1/messages do.
#
# Usage: ./tests/test_responses_streaming.sh [model_dir] [port]

set -u

MODEL_DIR=${1:-~/.mlx-serve/models/gemma-4-e4b-it-8bit}
PORT=${2:-8099}
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0
TOTAL=0

if [ ! -d "$MODEL_DIR" ]; then
    echo "SKIP: Model not found at $MODEL_DIR"
    exit 0
fi

if [ ! -x "./zig-out/bin/mlx-serve" ]; then
    echo "FAIL: ./zig-out/bin/mlx-serve not built"
    exit 1
fi

echo "=== /v1/responses Streaming Increment Test ==="
echo "Model: $MODEL_DIR"
echo "Port: $PORT"
echo ""

echo "Starting server..."
./zig-out/bin/mlx-serve --model "$MODEL_DIR" --serve --port $PORT --log-level info \
    >/tmp/mlx-serve-stream-test.log 2>&1 &
SERVER_PID=$!
sleep 2

for i in $(seq 1 30); do
    if curl -sf "$BASE/health" > /dev/null 2>&1; then
        echo "Server ready (PID $SERVER_PID)"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "FAIL: Server did not start within 30s"
        kill $SERVER_PID 2>/dev/null
        exit 1
    fi
    sleep 1
done
echo ""

cleanup() {
    echo ""
    echo "Stopping server (PID $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}
trap cleanup EXIT

run_test() {
    local name="$1"
    local result="$2"
    local detail="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$result" = "PASS" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name — $detail"
    fi
}

# Capture an SSE stream with relative wall-clock timestamps per line.
# Output lines: <ms_since_request_start>\t<sse_line>
sse_with_timestamps() {
    local body="$1"
    python3 - "$BASE" "$body" <<'PY'
import sys, json, time, urllib.request
base = sys.argv[1]
body = sys.argv[2].encode()
req = urllib.request.Request(
    base + "/v1/responses",
    data=body,
    headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
    method="POST",
)
start = time.monotonic()
with urllib.request.urlopen(req, timeout=120) as resp:
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        ms = int((time.monotonic() - start) * 1000)
        sys.stdout.write(f"{ms}\t{line}\n")
        sys.stdout.flush()
PY
}

# ── Test A: text streaming emits multiple output_text.delta events ──
echo "--- Test A: incremental output_text.delta events ---"
BODY='{"model":"mlx-serve","input":"Count from 1 to 20 separated by commas.","max_output_tokens":80,"temperature":0,"stream":true}'
SSE=$(sse_with_timestamps "$BODY")

DELTA_COUNT=$(echo "$SSE" | grep -c $'\tdata: {"type":"response.output_text.delta"' || true)
echo "  observed output_text.delta events: $DELTA_COUNT"
if [ "$DELTA_COUNT" -ge 3 ]; then
    run_test "incremental output_text.delta (>=3)" "PASS" ""
else
    run_test "incremental output_text.delta (>=3)" "FAIL" "got $DELTA_COUNT (expected ≥3 for ~20-token output)"
fi

# Span between first and last delta should reflect actual decode time.
# With buffered emission, all deltas land within a few ms of each other
# at the end of generation; with real streaming they span ≥100ms.
SPAN_MS=$(echo "$SSE" | python3 -c '
import sys
firsts = []
for line in sys.stdin:
    parts = line.split("\t", 1)
    if len(parts) != 2: continue
    ms, payload = parts
    if "response.output_text.delta" in payload:
        firsts.append(int(ms))
if len(firsts) < 2:
    print(0)
else:
    print(firsts[-1] - firsts[0])
')
echo "  span(first delta → last delta): ${SPAN_MS}ms"
if [ "$SPAN_MS" -ge 100 ]; then
    run_test "deltas spread across decode window (>=100ms)" "PASS" ""
else
    run_test "deltas spread across decode window (>=100ms)" "FAIL" "span=${SPAN_MS}ms (deltas bunched — buffered emission)"
fi
echo ""

# ── Test B: reasoning streaming emits multiple summary_text.delta events ──
echo "--- Test B: incremental reasoning_summary_text.delta events ---"
BODY='{"model":"mlx-serve","input":"What is 12 + 34? Think step by step.","reasoning":{"effort":"medium"},"max_output_tokens":256,"temperature":0,"stream":true}'
SSE=$(sse_with_timestamps "$BODY")

R_DELTA_COUNT=$(echo "$SSE" | grep -c $'\tdata: {"type":"response.reasoning_summary_text.delta"' || true)
T_DELTA_COUNT=$(echo "$SSE" | grep -c $'\tdata: {"type":"response.output_text.delta"' || true)
echo "  observed reasoning_summary_text.delta: $R_DELTA_COUNT"
echo "  observed output_text.delta:            $T_DELTA_COUNT"

# We accept either reasoning OR text emitted incrementally — model may
# decide to skip reasoning. The combined count must show streaming.
COMBINED=$((R_DELTA_COUNT + T_DELTA_COUNT))
if [ "$COMBINED" -ge 3 ]; then
    run_test "incremental reasoning/text deltas (>=3 combined)" "PASS" ""
else
    run_test "incremental reasoning/text deltas (>=3 combined)" "FAIL" "got $COMBINED (expected ≥3)"
fi
echo ""

echo "=== Result: $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ]
