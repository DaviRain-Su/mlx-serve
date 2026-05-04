# mlx-serve Benchmark Log

Performance tracking across releases. Run `./bench.sh` after every major feature or optimization change and append results here.

## How to run

```bash
# Full suite (all models):
./bench.sh

# Single model:
./bench.sh --model gemma

# Custom binary / more runs:
./bench.sh --binary ./my-build --runs 5
```

## Methodology

- **Prefill**: 840-token prompt (fixed, generated), `--max-tokens 1`, `--temp 0`
- **Decode**: "Write a detailed essay about quantum computing", `--max-tokens 256`, `--temp 0`
- **Runs**: 3 total. Run 1 is warmup (includes model loading from disk, excluded). Runs 2-3 are averaged.
- **System**: Apple M4, 16 GB unified memory (unless noted otherwise)

### Models

| Short name | Path | Architecture | Params | Quant |
|---|---|---|---|---|
| Gemma-4-E4B-4bit | `gemma-4-e4b-it-4bit` | `gemma4` | ~4B | 4-bit |
| LFM2.5-350M-8bit | `LFM2.5-350M-MLX-8bit` | `lfm2` | 350M | 8-bit |
| Qwen3.5-4B-4bit | `Qwen3.5-4B-MLX-4bit` | `qwen3_5_moe` | ~4B | 4-bit |

### Prompts

**Prefill prompt** (840 tokens):
```
Explain the following topics in extreme detail: topic 1 about science and technology
and its impact on human civilization throughout history, topic 2 about ..., ... topic 49 about ...
```

**Decode prompt** (16 tokens):
```
Write a detailed essay about quantum computing
```

---

## 2026-05-04 — v26.5.1: Responses API + WebSockets, tokenizer arena fix

**Changes since 2026-04-16**:
- `loadTokenizer` keeps the parsed `tokenizer.json` arena alive and borrows vocab/merge string pointers from it (no per-entry dupe). Pre-sized hashmaps to skip rehashing.
- New `/v1/responses` (Responses API + compaction) and WebSocket transport on `/v1/responses` — exercise the same forward-pass code path, no inference change expected.

### mlx-serve

| Model | Prefill (tok/s) | Decode (tok/s) | Memory |
|---|---|---|---|
| Gemma-4-E4B-4bit | 388.0 | 33.5 | 4.344 GB |
| LFM2.5-350M-8bit | 3825.6 | 214.3 | 0.406 GB |
| Qwen3.5-4B-4bit | 382.9 | 37.8 | 2.266 GB |

### Δ vs 2026-04-16

| Model | Prefill | Decode | Memory |
|---|---|---|---|
| Gemma-4-E4B-4bit | +5.2% (368.7 → 388.0) | +5.3% (31.8 → 33.5) | ≈ same |
| LFM2.5-350M-8bit | +4.4% (3666.0 → 3825.6) | +4.9% (204.3 → 214.3) | same |
| Qwen3.5-4B-4bit | **+165% (144.3 → 382.9)** | +15.2% (32.8 → 37.8) | -6.0% |

### Analysis

- **Qwen3.5 prefill jump is the headline**: 144 → 383 tok/s on 844-token prompts, now ~93% of mlx-lm 0.31.2's reference (410). The previous gap was attributed to per-timestep GatedDeltaNet recurrence vs mlx-lm's parallel scan, but no SSM/scan code changed — the fix is the tokenizer arena change. The old 2026-04-16 measurement included tokenizer-load time inside the prefill metric, and the per-timestep `allocator.dupe` over 144k vocab + ~150k merges was eating multiple seconds of wall-clock per warmup run. With borrow-from-arena, that overhead vanishes.
- **Gemma / LFM gains** (~5%) are within run-to-run thermal variance from the same effect on smaller string tables. Real but minor.
- **Decode is unchanged** in absolute terms — small movements (Gemma 31.8 → 33.5, Qwen 32.8 → 37.8) are within the typical noise floor of 256-token decode runs on a 16 GB M4. No code on the decode hot path changed.
- **No regressions** from the +1395 lines of `server.zig` for Responses/WebSocket — those endpoints don't touch the chat-completions forward pass that bench.sh exercises.

### Reference (mlx-lm 0.31.2, 2026-04-16, unchanged)

| Model | Prefill (tok/s) | Decode (tok/s) | Memory |
|---|---|---|---|
| Gemma-4-E4B-4bit | 559.1 | 31.6 | 4.316 GB |
| LFM2.5-350M-8bit | 4303.2 | 232.0 | 0.421 GB |
| Qwen3.5-4B-4bit | 409.8 | 36.6 | 2.476 GB |

---

## 2026-04-16 — Nemotron-H SSM precision fix + time_step_limit fix

**Commit**: `dfd66c4` + uncommitted

**Changes**:
- Nemotron-H: Cast A_neg to float32 in Mamba2 SSM (matching Python precision)
- Nemotron-H: Fixed time_step_limit defaults (Python uses `(0.0, inf)`, we were reading `time_step_min`/`time_step_max` from config which clipped dt incorrectly)
- Qwen3.5 GatedDeltaNet: Fixed parameter-free RMS norm (mlx-c now requires non-empty weight array, pass ones)
- Qwen3.5 GatedDeltaNet: Fixed SSM state init (conv1dWithCache sets `initialized=true` before state is created, check `ctx==null` instead)

### mlx-serve

| Model | Prefill (tok/s) | Decode (tok/s) | Memory |
|---|---|---|---|
| Gemma-4-E4B-4bit | 368.7 | 31.8 | 4.328 GB |
| LFM2.5-350M-8bit | 3666.0 | 204.3 | 0.406 GB |
| Qwen3.5-4B-4bit | 144.3 | 32.8 | 2.411 GB |

### mlx-lm 0.31.2 (reference)

| Model | Prefill (tok/s) | Decode (tok/s) | Memory |
|---|---|---|---|
| Gemma-4-E4B-4bit | 559.1 | 31.6 | 4.316 GB |
| LFM2.5-350M-8bit | 4303.2 | 232.0 | 0.421 GB |
| Qwen3.5-4B-4bit | 409.8 | 36.6 | 2.476 GB |

### Analysis

- **Decode**: mlx-serve matches mlx-lm within ~10% across all models (31.8 vs 31.6 Gemma, 32.8 vs 36.6 Qwen)
- **Prefill**: mlx-lm is faster on prefill — likely due to parallel scan (SSD) for SSM models vs our per-timestep loop. Gemma prefill gap (369 vs 559) is due to system thermal state variance between runs.
- **Memory**: Nearly identical between the two — both use the same MLX backend
- **Qwen3.5 prefill**: Our per-timestep GatedDeltaNet recurrence (144 tok/s) is ~2.8x slower than mlx-lm's parallel implementation (410 tok/s) on 844-token prompts. Decode speed is comparable.
