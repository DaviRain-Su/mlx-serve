#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${1:-${MLX_SERVE_TEST_MODEL:-}}"
PORT="${2:-8096}"
BASE="http://127.0.0.1:${PORT}"
LOG_FILE="${TMPDIR:-/tmp}/mlx-serve-smoke-${PORT}.log"
SERVER_PID=""

if [[ -z "${MODEL_DIR}" || ! -d "${MODEL_DIR}" ]]; then
    echo "usage: $0 <model_dir> [port]"
    echo "or set MLX_SERVE_TEST_MODEL"
    exit 2
fi

cleanup() {
    if [[ -n "${SERVER_PID}" ]]; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cd "${ROOT_DIR}"
zig build >/dev/null

"${ROOT_DIR}/zig-out/bin/mlx-serve" \
    --model "${MODEL_DIR}" \
    --serve \
    --host 127.0.0.1 \
    --port "${PORT}" \
    --ctx-size 4096 \
    --reasoning-budget 512 \
    --log-level warn \
    >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 120); do
    if curl -fsS --max-time 2 "${BASE}/health" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "server exited during startup; log:"
        cat "${LOG_FILE}"
        exit 1
    fi
    sleep 1
done

health="$(curl -fsS --max-time 5 "${BASE}/health")"
python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "ok"' <<<"${health}"

props="$(curl -fsS --max-time 5 "${BASE}/props")"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["total_slots"] >= 1; assert d["default_generation_settings"]["n_ctx"] >= 1; assert d["model_info"]["vocab_size"] >= 1' <<<"${props}"

models="$(curl -fsS --max-time 5 "${BASE}/v1/models")"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["object"] == "list"; assert len(d["data"]) >= 1; assert d["data"][0]["id"]' <<<"${models}"

chat="$(curl -fsS --max-time 120 "${BASE}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"mlx-serve","messages":[{"role":"user","content":"Reply with exactly OK."}],"temperature":0,"max_tokens":32}')"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["object"] == "chat.completion"; assert d["choices"][0]["message"]["content"]; assert d["usage"]["prompt_tokens"] >= 1; assert d["usage"]["completion_tokens"] >= 1' <<<"${chat}"

echo "PASS server smoke: health, props, models, chat completions"
