#!/bin/bash
# mlx-serve benchmark suite
#
# Usage:
#   ./bench.sh                          # Run all models with defaults
#   ./bench.sh --model gemma             # Run only gemma model
#   ./bench.sh --binary ./my-build       # Use custom binary
#   ./bench.sh --runs 5                  # Override number of runs
#   ./bench.sh --no-mlx-lm              # Skip mlx-lm reference benchmarks
#   ./bench.sh --only-mlx-lm            # Run only mlx-lm benchmarks
#
# Results are printed in a format ready to paste into BenchmarkLog.md.
# Run 1 is always a warmup (includes model loading from disk) and excluded
# from averages. Averages are computed from runs 2..N.

set -uo pipefail

BINARY="${BINARY:-./zig-out/bin/mlx-serve}"
MODEL_DIR="${MODEL_DIR:-$HOME/.mlx-serve/models}"
RUNS=3
FILTER=""
SKIP_MLX_LM=false
ONLY_MLX_LM=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)       BINARY="$2"; shift 2 ;;
        --runs)         RUNS="$2"; shift 2 ;;
        --model)        FILTER="$2"; shift 2 ;;
        --no-mlx-lm)    SKIP_MLX_LM=true; shift ;;
        --only-mlx-lm)  ONLY_MLX_LM=true; shift ;;
        *)              echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Fixed prompts for reproducibility
PREFILL_PROMPT="Explain the following topics in extreme detail: $(python3 -c "print(', '.join([f'topic {i} about science and technology and its impact on human civilization throughout history' for i in range(1,50)]))")"
DECODE_PROMPT="Write a detailed essay about quantum computing"

# Model configs: name|path|decode_max_tokens
MODELS=(
    "Gemma-4-E4B-4bit|$MODEL_DIR/gemma-4-e4b-it-4bit|256"
    "LFM2.5-350M-8bit|$MODEL_DIR/LFM2.5-350M-MLX-8bit|256"
    "Qwen3.5-4B-4bit|$MODEL_DIR/Qwen3.5-4B-MLX-4bit|256"
)

extract_metric() {
    local label="$1" output="$2"
    echo "$output" | grep "^${label}:" | sed -E "s/.*: [0-9]+ tokens, ([0-9.]+) tokens-per-sec/\1/"
}

extract_memory() {
    local output="$1"
    echo "$output" | grep "^Peak memory:" | sed -E "s/Peak memory: (.+)/\1/"
}

compute_avg() {
    local csv="$1"
    python3 -c "vals=[$csv]; print(f'{sum(vals)/len(vals):.1f}')"
}

# ── mlx-serve benchmark ──

run_bench() {
    local name="$1" model_path="$2" max_tokens="$3"

    if [[ ! -d "$model_path" ]]; then
        echo "  SKIP: $model_path not found"
        return
    fi

    echo ""
    echo "### $name"
    echo ""

    # --- Prefill benchmark ---
    local prefill_vals=()
    local prefill_mem=""
    local prefill_tokens=""

    for i in $(seq 1 "$RUNS"); do
        local out
        out=$("$BINARY" --model "$model_path" --prompt "$PREFILL_PROMPT" --max-tokens 1 --temp 0 2>&1)
        if echo "$out" | grep -q "MLX error\|panic\|unreachable"; then
            echo "  ERROR: model failed — $(echo "$out" | grep -iE 'MLX error|panic|unreachable' | head -1)"
            return
        fi
        local val
        val=$(extract_metric "Prompt" "$out")
        if [[ $i -eq 1 ]]; then
            prefill_mem=$(extract_memory "$out")
            prefill_tokens=$(echo "$out" | grep "^Prompt:" | sed -E "s/Prompt: ([0-9]+) tokens.*/\1/")
            echo "  Prefill warmup (run 1): ${val} tok/s  [${prefill_tokens} tokens]"
        else
            prefill_vals+=("$val")
            echo "  Prefill run $i: ${val} tok/s"
        fi
    done

    local prefill_avg
    prefill_avg=$(compute_avg "$(IFS=,; echo "${prefill_vals[*]}")")

    # --- Decode benchmark ---
    local decode_vals=()
    local decode_mem=""

    for i in $(seq 1 "$RUNS"); do
        local out
        out=$("$BINARY" --model "$model_path" --prompt "$DECODE_PROMPT" --max-tokens "$max_tokens" --temp 0 2>&1)
        local val
        val=$(extract_metric "Generation" "$out")
        if [[ $i -eq 1 ]]; then
            decode_mem=$(extract_memory "$out")
            echo "  Decode warmup (run 1): ${val} tok/s  [${max_tokens} tokens]"
        else
            decode_vals+=("$val")
            echo "  Decode run $i: ${val} tok/s"
        fi
    done

    local decode_avg
    decode_avg=$(compute_avg "$(IFS=,; echo "${decode_vals[*]}")")

    echo ""
    echo "  **Result: prefill=${prefill_avg} tok/s (${prefill_tokens} tokens), decode=${decode_avg} tok/s (${max_tokens} tokens), mem=${decode_mem}**"
}

# ── mlx-lm reference benchmark ──

run_mlx_lm_bench() {
    local name="$1" model_path="$2" max_tokens="$3"

    if [[ ! -d "$model_path" ]]; then
        echo "  SKIP: $model_path not found"
        return
    fi

    echo ""
    echo "### $name (mlx-lm)"
    echo ""

    # --- Prefill benchmark ---
    local prefill_vals=()
    local prefill_tokens=""

    for i in $(seq 1 "$RUNS"); do
        local out
        out=$(python3 -m mlx_lm generate \
            --model "$model_path" \
            --prompt "$PREFILL_PROMPT" \
            --max-tokens 1 \
            --temp 0 \
            --verbose True \
            --ignore-chat-template 2>&1)
        if echo "$out" | grep -qi "error\|traceback"; then
            echo "  ERROR: mlx-lm failed — $(echo "$out" | grep -i 'error' | tail -1)"
            return
        fi
        local val
        val=$(extract_metric "Prompt" "$out")
        if [[ $i -eq 1 ]]; then
            prefill_tokens=$(echo "$out" | grep "^Prompt:" | sed -E "s/Prompt: ([0-9]+) tokens.*/\1/")
            echo "  Prefill warmup (run 1): ${val} tok/s  [${prefill_tokens} tokens]"
        else
            prefill_vals+=("$val")
            echo "  Prefill run $i: ${val} tok/s"
        fi
    done

    local prefill_avg
    prefill_avg=$(compute_avg "$(IFS=,; echo "${prefill_vals[*]}")")

    # --- Decode benchmark ---
    local decode_vals=()
    local decode_mem=""

    for i in $(seq 1 "$RUNS"); do
        local out
        out=$(python3 -m mlx_lm generate \
            --model "$model_path" \
            --prompt "$DECODE_PROMPT" \
            --max-tokens "$max_tokens" \
            --temp 0 \
            --verbose True \
            --ignore-chat-template 2>&1)
        local val
        val=$(extract_metric "Generation" "$out")
        if [[ $i -eq 1 ]]; then
            decode_mem=$(extract_memory "$out")
            echo "  Decode warmup (run 1): ${val} tok/s  [${max_tokens} tokens]"
        else
            decode_vals+=("$val")
            echo "  Decode run $i: ${val} tok/s"
        fi
    done

    local decode_avg
    decode_avg=$(compute_avg "$(IFS=,; echo "${decode_vals[*]}")")

    echo ""
    echo "  **Result: prefill=${prefill_avg} tok/s (${prefill_tokens} tokens), decode=${decode_avg} tok/s (${max_tokens} tokens), mem=${decode_mem}**"
}

# ── Main ──

echo "=== mlx-serve Benchmark ==="
echo "Runs: $RUNS (warmup + $((RUNS-1)) measured)"
echo "Date: $(date -u +%Y-%m-%d)"
echo "System: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown') / $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}')"

if [[ "$ONLY_MLX_LM" == false ]]; then
    echo ""
    echo "## mlx-serve"
    echo "Binary: $BINARY"

    for entry in "${MODELS[@]}"; do
        IFS='|' read -r name path max_tokens <<< "$entry"
        if [[ -n "$FILTER" ]] && ! echo "$name" | grep -qi "$FILTER"; then
            continue
        fi
        run_bench "$name" "$path" "$max_tokens"
    done
fi

if [[ "$SKIP_MLX_LM" == false ]]; then
    if ! python3 -c "import mlx_lm" 2>/dev/null; then
        echo ""
        echo "## mlx-lm (SKIPPED — not installed)"
        echo "  Install with: pip install mlx-lm"
    else
        local_mlx_lm_version=$(python3 -c "import mlx_lm; print(mlx_lm.__version__)" 2>/dev/null)
        echo ""
        echo "## mlx-lm ${local_mlx_lm_version} (reference)"

        for entry in "${MODELS[@]}"; do
            IFS='|' read -r name path max_tokens <<< "$entry"
            if [[ -n "$FILTER" ]] && ! echo "$name" | grep -qi "$FILTER"; then
                continue
            fi
            run_mlx_lm_bench "$name" "$path" "$max_tokens"
        done
    fi
fi

echo ""
echo "=== Done ==="
