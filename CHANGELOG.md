# Changelog

## v26.4.30 — Gemma 4 Vision Fix, /v1/models Capabilities, Responses Streaming, Browse extractText

### Gemma 4 Vision — Image Tokens Now Land in the Right Place
- **Hard-coded Gemma 3 token IDs replaced with an architecture-aware marker**: `insertImageTokens` previously scanned for `[106, 1645]` (`<start_of_turn> user`), the Gemma 3 pattern. In every Gemma 4 tokenizer those IDs are entirely different (`<|turn>` is 105, `user` is 2364, `\n` is 107), so the search never matched and image tokens were inserted via the end-anchored fallback — i.e., inside the trailing `<|turn>model\n` generation prefix, where the model never sees them. Net effect: Gemma 4 was effectively blind to attached images even though the vision encoder ran successfully on every request.
- **`populateUserTurnMarker` at startup**: New `ModelConfig.user_turn_marker_ids` is filled by encoding an architecture-specific user-turn prefix string with the actual tokenizer at server boot, then `insertImageTokens` searches for that subsequence with `std.mem.eql`. The prefix is picked from `chat_template` content so a model that ships an unusual template still tokenizes correctly:
  - `<|turn>` in template → `<|turn>user\n` (Gemma 4)
  - `<start_of_turn>` → `<start_of_turn>user\n` (Gemma 3)
  - `<|im_start|>` → `<|im_start|>user\n` (Qwen / generic ChatML)
  - `<|start_header_id|>` → `<|start_header_id|>user<|end_header_id|>\n\n` (Llama 3)
  - none of the above → marker stays empty, fallback heuristic logs a warning so the silent miscompile no longer happens
- **Verified end-to-end** on `gemma-4-e4b-it-4bit`: server now logs `User turn marker: "<|turn>user\n" -> 3 tokens` and `Inserted BOI + 256 image tokens + EOI at position 4` (right after BOS + 3-token marker), and the model produces real image descriptions instead of generic "I can't see images" text.

### `/v1/models` Capabilities, Modalities, and Real Model IDs
- **New `capabilities` array per model**: `chat`, `tool_use`, `streaming`, `vision`, `reasoning`, `json_schema`, `embeddings` — derived at request time from chat-template presence, vision-encoder loaded state, encoder-only mode, and a `chatTemplateSupportsThinking` heuristic that scans for `enable_thinking` / `<think>` / `thought` / `<|channel>`.
- **`input_modalities` array**: `["text"]` or `["text","image"]` so clients know which content blocks they should send.
- **`meta.architecture` field**: Exposes `model_type` (e.g. `gemma4`, `qwen3_5_moe`) alongside the existing vocab/hidden/layers/quantization/context_length values.
- **Model id is now the directory basename** (e.g. `gemma-4-e4b-it-4bit`) instead of the architecture family — clients can finally distinguish quantizations of the same architecture. Falls back to the architecture family if `model_dir` is unavailable.
- **`tests/test_models_capabilities.sh`**: New integration script asserting capability and modality presence per architecture.

### Anthropic `/v1/messages` — Vision Support
- **Base64 and URL image blocks accepted**: `{type:"image", source:{type:"base64", media_type, data}}` and `{type:"image", source:{type:"url", url}}` are now parsed alongside `text` blocks within the same user turn and routed through the existing vision pipeline (stb_image / libwebp decode → 768×768 float32 CHW → SigLIP encoder). Previously image blocks were silently dropped on the Anthropic endpoint.
- **Same-message text + image bundling**: All blocks of a single user message are joined into one `Message` so vision embeddings attach to the right turn — fixes prompt-position drift when text and image arrive in one block.
- **`tests/test_anthropic_vision.sh`**: New round-trip test against `/v1/messages` with a base64 image.

### OpenAI `/v1/responses` — Live Streaming Deltas
- **Reasoning, message, and function-call output items now stream incrementally**. New helpers `emitResponsesReasoningStart` / `emitResponsesReasoningDelta` / `emitResponsesReasoningEnd` (and matching message helpers) emit `output_item.added` + `reasoning_summary_part.added` / `content_part.added` once, fan out `reasoning_summary_text.delta` / `output_text.delta` per token chunk, and close with the matching `.done` events. Previously the entire reasoning/message text was buffered server-side and emitted as a single block at the end — defeating the point of SSE.
- **Think-block streaming parity with chat completions**: 9-byte look-behind buffer for the longest close tag (`</think>` / `<channel|>`), template-pre-injected opener detection, dual-tag scan — same machinery as the chat-completions and Anthropic streaming paths, so reasoning is split cleanly from the final answer in all three endpoints.
- **UTF-8 carry across BPE token boundaries**: Streaming path holds back partial multi-byte sequences so chunks always end on a valid codepoint.
- **Tool-active requests still buffer fully**: We can't stream content deltas before knowing whether the output is a tool call.
- **Chat-style `response_format` alias accepted**: Clients that point their existing `/v1/chat/completions` adapter at `/v1/responses` send `response_format = {type, json_schema:{schema}}` instead of `text.format = {type, schema}`. New `parseResponseFormatAlias` accepts both shapes (flat and nested under `json_schema`) on both fields, so the schema constraint isn't silently dropped. `parseTextFormat` also gained the nested-`json_schema` fallback.
- **`tests/test_responses_streaming.sh`** + 4 new Zig tests in `responses.zig` covering nested and flat schema shapes on both fields.

### Browse Tool — `extractText` for Data-Dense Pages
- **Root cause of agent loops on small models**: Gemma 4 e4b looped 9 times trying to read GitHub trending. `readText` returned the first 3000 chars of `body.innerText`, dominated on `github.com/trending` by a `<details>` language picker (~200 language names) — actual `article.Box-row` repo entries appeared AFTER it, beyond the 3000-char cap. The repetition tracker eventually rate-limited the model. The model wasn't dumb; the tool was inadequate for data-dense pages.
- **`readText` is now content-aware**: Picks `document.querySelector('main') || [role="main"] || article || document.body` as the root and adds `details, menu, datalist, [role="listbox"], [role="combobox"]` to the strip list so language pickers and combobox menus don't crowd out real content.
- **New `extractText(selector)` browse action**: Runs `document.querySelectorAll(selector)`, joins the `innerText` of up to 50 matching elements with `\n---\n`, caps at 2900 chars. Returns `"No elements match selector: <sel>"` on empty so the model gets an unambiguous failure signal and can re-discover.
- **Updated `web-interact` skill**: Step 1 now teaches `extractText` as the primary path for "give me X from this page" tasks with concrete selectors (`article.Box-row` / `tr.athing` / `.result, .g, [data-testid="result"]`). Drops the misleading "navigate → readHTML" advice (`readHTML` returns mostly `<head>`).
- **Tool description rewritten**: Browse description in `AgentPrompt.swift` lists `extractText` and steers the model toward it for data-listing pages while keeping the existing key-order guarantees.

### Schema Enforcement — Dropped-Schema Repair
- **Bench runs surfaced silent schema drops**: Probing showed (a) flat `text.format.schema` was enforced, (b) nested `text.format.json_schema.schema` was silently dropped (no grammar log), (c) top-level `response_format` on `/v1/responses` was silently dropped, and (d) `tools + tool_choice:"none" + schema` skipped the mask. Fixed by `parseTextFormat` / `parseResponseFormatAlias` accepting both shapes on both fields.
- **`tests/test_json_schema_enforcement.sh`**: New test that biases the model toward markdown code-fences and `additionalProperties` violations across all four request shapes — strong signal that the grammar mask is doing the work, not just the prompt-side instruction.

### MLX Core App — Lifecycle & UX
- **Default port 8080 → 11234**: Avoids conflict with the long list of dev tools that squat on 8080. Updated in `--port` default, `ServerManager.port`, README, and the displayed endpoints panel.
- **Orphan-process reaper**: `ServerManager.startServer` now runs `lsof -nP -iTCP:<port> -sTCP:LISTEN -t`, filters PIDs whose `ps -o comm=` ends in `mlx-serve`, and SIGTERMs (then SIGKILLs after 2 s) any survivors before launching its own child. Recovers cleanly from a previous crash that left the port held, with no risk to unrelated apps that happen to bind the same port.
- **Endpoints panel refreshed**: Replaced `/v1/completions` (rarely used) with `/v1/responses` (newly streaming) and reordered for the typical agent workflow.
- **Chat input background uses `NSColor.textBackgroundColor`**: System-aware light/dark background instead of a hard-coded near-black, so light-mode users actually see the field.

### Testing
- **+10 new Zig unit tests** across `src/model.zig` (5: `pickUserTurnPrefix` for Gemma 3/4, ChatML, Llama 3, unknown; `userTurnMarkerSlice` length respect), `src/server.zig` (4: `insertImageTokens` happy path, multi-user-turn ordering, no-marker fallback, no-op cases), and `src/responses.zig` (4: text-format / response-format alias shapes).
- **+4 new shell integration scripts**: `test_anthropic_vision.sh`, `test_json_schema_enforcement.sh`, `test_models_capabilities.sh`, `test_responses_streaming.sh`.
- `zig build test` 0 failures, full Swift test suite green.

---

## v26.4.28 — Grammar-Constrained JSON Schema Decoding

### Strict `response_format.json_schema` Enforcement
- **Token-level mask**: When a request includes `response_format: {type: "json_schema", json_schema: {schema: …}}`, every sampled token is now filtered against a streaming JSON grammar derived from the schema. Tokens whose bytes would violate the grammar have their logits set to `-inf` before sampling, so non-conforming output is structurally unreachable. Previously the schema was injected into the system prompt as a "soft" instruction and quantized models routinely produced trailing prose, missing closing braces, or wrong types — which triggered backend `JSON.parse` retries on the consumer side.
- **Supported subset (the common case)**: `type` (object, array, string, integer, number, boolean, null), `properties`, `required`, `additionalProperties` (defaults to `false`, OpenAI-strict), `items`, `enum`, `const`, `minLength` / `maxLength`, `minimum` / `maximum`, `exclusiveMinimum` / `exclusiveMaximum`, `pattern` (regex). `anyOf` / `oneOf` are relaxed to "any JSON value" at branch points; the prompt instruction still nudges the model toward the right shape.
- **EOS gating**: The end-of-sequence token is masked off until the grammar reports the root value as fully parsed, eliminating premature truncation of partial JSON.
- **Graceful fallback**: If the grammar enters a dead state (e.g. an unsupported schema feature surfaces mid-decode), the mask flips to "everything allowed" and a warning is logged — the request still completes instead of stalling.
- **Token-byte cache**: The vocabulary's per-id byte sequences are computed once at first use (~50 ms for a 100k-vocab tokenizer) and reused across all subsequent requests, so per-token mask building is just a vocab-sized speculative replay (~1–5 ms on M-series silicon).

### Implementation
- New modules: `src/json_schema.zig` (schema IR + parser), `src/regex.zig` (Thompson-NFA engine for `pattern`), `src/json_grammar.zig` (streaming JSON FSM with snapshot/restore for speculative trial), `src/token_mask.zig` (mask builder using `acceptByteFast` over a single outer snapshot).
- `generate.zig` gains a `Constraint` type and a `constraint` field on `SamplingParams`. When set, `Generator.init` skips the lazy first-sample fast path and `Generator.next` dispatches to a synchronous `nextConstrained` path: build mask → `mlx_where(mask, logits, -inf)` → categorical sample → eval → advance grammar by sampled token's bytes → async-launch next forward to overlap with the next mask build.
- `server.zig` parses `response_format.json_schema`, lazily builds the global `TokenBytes` table, allocates a per-request mask buffer of `vocab_size` booleans, instantiates a `Grammar`, and threads a `Constraint` through `SamplingParams`. The existing prompt-side schema instruction is kept as a soft guide for the union/`anyOf` cases the grammar relaxes.

### Testing
- New unit-test modules covering schema IR (32 cases), regex NFA (counted quantifiers, character classes, alternation), streaming JSON grammar (snapshot/restore, depth tracking, cruise-app-style nested schemas), and token mask building (object/enum/dead-grammar fallback, multi-byte tokens straddling a key boundary).
- New `tests/test_json_schema.sh` integration script: object schema, enum, nested array-of-string, and a streaming round-trip — all asserting that the assembled output round-trips through `json.loads` and matches the requested shape.

## v26.4.27 — Multi-CLI Launcher (Claude Code / pi / OpenCode)

### CLI Launcher
- **Menu-bar dropdown** replaces the single "Launch Claude Code" button. Detects installed CLIs on PATH (through a login `zsh -l` so nvm / Homebrew / `~/.local/bin` / `~/.opencode/bin` are honored) and shows one entry per installed agent: **Claude Code**, **pi**, **OpenCode**.
- **Smart visibility**: if exactly one CLI is installed the launcher renders as a single button (no wasted click); with 2+ it becomes a dropdown; with zero it disappears entirely so the footer doesn't advertise a feature the user can't use.
- **Per-CLI config staging**: launching pi writes `~/.pi/agent/models.json` with an `mlx` provider pointing at the running server; launching OpenCode writes a dedicated `OPENCODE_CONFIG` JSON in `$TMPDIR` so the user's main `~/.config/opencode/opencode.json` is left untouched.
- **Model-aware launches**: all three use the served model id from `/v1/models` rather than the hard-coded `mlx-serve` alias, so `pi` and `opencode` model-switchers show the real name (e.g. `qwen3_5_moe`).

## v26.4.26 — Qwen 3.5/3.6 Tool-Call Reliability, Thinking Streaming, Swift Agent Robustness

### Qwen 3.5/3.6 MoE Tool-Call Fixes
- **Nested-name repair**: `chat.tryParseJsonToolCall` now walks down through up to 4 levels of `{"name":{"name":{…}}}` wrappers when Qwen 3.5/3.6 MoE emits garbage-wrapped tool-call JSON in streaming mode. Prior behaviour was to drop the whole `<tool_call>` block onto the content stream as plain text, which stranded agentic clients. Observed in the wild with `pi` + Qwen3.6-35B-A3B-6bit (`--thinking off`), now repaired cleanly. Two new regression tests in `src/chat.zig`.
- **Missing `"arguments":` repair**: `{"name":"shell", {"command":"ls"}}` (opening quote/colon missing on `arguments`) — now recognised and repaired before JSON parse.
- **Unquoted-key repair**: `{"name":"shell", arguments":{…}}` (missing OPENING quote on `arguments`) — injected before parse.
- **KV cache reset on identical prompt**: Re-issuing the exact same prompt (common in idempotent retries) no longer reuses stale KV residue from the previous generation. Fixes generation-quality drift on Qwen3.5/3.6 MoE when a prompt is replayed.
- **Client-side fallback**: Swift `APIClient` now scans accumulated streamed content for `<tool_call>…</tool_call>` blocks as a last resort when no `tool_calls` delta arrives — belt-and-suspenders with the server repair.

### Thinking-Tag Streaming (Qwen, Gemma 4)
- **Template-pre-injected opener handling**: Many templates (Qwen 3.5/3.6, some Gemma 4 variants) pre-inject `<think>\n` into the prompt, so the model's first token is already inside the thinking block. The streaming parser now stays in the think block when no literal opener appears, and flushes reasoning tokens with a 9-byte look-behind buffer for the longest close tag (`</think>` / `<channel|>`).
- **Dual close-tag detection**: Both `</think>` and `<channel|>` are scanned every tick — whichever appears first wins. Eliminates the case where a model switches tag style mid-stream.
- **Mirror fix in Anthropic Messages endpoint**: `handleAnthropicStreaming` gets the same treatment so Claude Code / Anthropic SDK clients see clean `thinking` blocks.

### Swift Agent Harness Robustness (MLX Core app)
- **Stream watchdog**: 90 s inactivity watchdog around the agent-loop SSE consumer. A stalled server, sampling-degenerate loop, or KV-cache poison scenario now surfaces a clear "the model didn't respond within 90s" error instead of an indefinite spinner. Stop button cancellation is preserved via `withTaskCancellationHandler`.
- **`failedRetry` flag on `ChatMessage`**: Pad-retry and max-tokens truncation recovery no longer `removeLast()` the streamed assistant message — they flag it `failedRetry` so its reasoning stays visible in the UI but it's excluded from future API history. Fixes "thinking block disappears mid-conversation" regression.
- **Completion-text guarantee**: When the agent exits with no tool calls and the final content contains a malformed tool-call tag (`<|tool_call>…`, `<tool_call>…`, `<function=…`), it re-prompts once for a plain-text summary. The per-turn nudge after tool results now asks explicitly for "short plain-text summary for the user — no tool calls, no JSON" when the task is complete.
- **Per-tool 30s timeout for `browse` / `webSearch`**: `withThrowingTaskGroup`-based ceiling on any single browser-tool invocation; `BrowserManager.evaluateJavaScript` calls also get an inner 25 s cap. A hung page can no longer freeze the agent loop.

### Testing Infrastructure
- **`pi-integration-test.md` + `tests/pi_integration_run.sh`**: New end-to-end harness that points [`pi`](https://github.com/badlogic/pi-mono) (a third-party OpenAI-compatible agent CLI) at mlx-serve and runs a two-turn Express todo-app build across a matrix of `(model × streaming × thinking)`. Catches wire-protocol regressions unit tests miss.
- **`tests/pi_nonstream_smoke.sh`**: Single-request non-streaming smoke (curl + manual tool-call validation) for every model.
- **+5 new Zig tests in `src/chat.zig`**: Covers nested-name garbage, flat-shape tool calls, missing-quote repairs, think-block streaming edge cases.
- **+2 new Swift tests in `AgentHarnessTests.swift`**: Validates `failedRetry` exclusion in `buildAgentHistory`.

### Verification
Full end-to-end matrix run on Apple Silicon (64 GB):
- gemma-4-e4b-it-8bit streaming → 5/5 (jest green)
- gemma-4-26b-a4b-it-4bit streaming → 5/5 (jest green)
- Qwen3.6-35B-A3B-6bit streaming, thinking off → **5/5** (was 3/5 pre-fix)
- Qwen3.6-35B-A3B-6bit streaming, thinking medium → **5/5** (was 3/5 pre-fix)
- 4/4 non-streaming smokes clean (valid JSON args, no tag leaks)
- 112/112 Swift unit tests, Zig unit tests all green

## v26.4.25 — Nemotron-H, LFM2, Qwen3.5 GatedDeltaNet Fixes

### Nemotron-H (Mamba2 SSM) — Now Working
- **A_neg float32 precision**: Cast `-exp(A_log)` to float32 in `mamba2Mixer`, matching Python's `A = -mx.exp(A_log).astype(dt.dtype)`. BF16 precision caused decay values `dA = exp(A*dt)` to be imprecise, compounding across 42 layers
- **time_step_limit defaults**: Python defaults to `(0.0, inf)` when `time_step_limit` is absent from config. We were reading `time_step_min`/`time_step_max` from config (0.001, 0.1) and using them for dt clipping — this corrupted SSM dynamics. Now defaults to `(0.0, inf)` and only reads the `time_step_limit` JSON array if explicitly present

### Qwen 3.5 GatedDeltaNet — Now Working
- **Parameter-free RMS norm fix**: GatedDeltaNet Q/K normalization passed a null array as weight to `mlx_fast_rms_norm`. mlx-c now requires a non-empty array — fixed by passing `ones([dk], bfloat16)`
- **SSM state initialization**: `conv1dWithCache` sets `ssm.initialized = true` before the SSM recurrence state is created, causing the state init to be skipped. Fixed by checking `ssm.ssm_state.ctx == null` instead (same pattern as Mamba2)
- **Qwen 3.6 compatibility**: Qwen3.6-35B-A3B uses `model_type: qwen3_5_moe` with both GatedDeltaNet and MoE — works with existing code paths after these fixes

### LFM2 (Liquid) — Confirmed Working
- **Benchmarked**: LFM2.5-350M-8bit runs at 3780 tok/s prefill, 210 tok/s decode (0.4 GB)

### Benchmark Suite
- **`bench.sh` rewrite**: Deterministic benchmarking with fixed prompts, warmup exclusion, error handling, `--model` filter, `--runs` override
- **mlx-lm reference**: Side-by-side comparison with Python mlx-lm (`--no-mlx-lm` / `--only-mlx-lm` flags)
- **`BenchmarkLog.md`**: Performance tracking across releases with methodology documentation

### Model Browser
- **Architecture tag prefixes**: Added `nemotron` and `lfm` to `supportedArchitectureTagPrefixes` — HuggingFace search results for these models no longer show "Unsupported architecture"

### Build & Versioning
- **CalVer auto-increment**: `build.sh` now uses `YY.M.N` versioning where N is auto-incremented from the latest GitHub release for the current month (was day-based, causing skipped numbers)
- **Version passed to Zig**: `build.sh` passes `-Dversion` to `zig build` so the CLI binary reports the correct version

### Documentation
- **README.md**: Moved Nemotron-H and LFM2 from "Not Yet Supported" to supported models table; added Qwen 3.6
- **CLAUDE.md**: Updated architecture table, added gotchas for SSM state init, parameter-free RMS norm, and time_step_limit

---

## v26.4.22 — Model Browser, Menu Bar Status Icon

### Model Browser
- **HuggingFace model search**: New "Model Browser" window searches HuggingFace Hub for MLX-format models with sortable columns (downloads, likes, RAM estimate, last updated)
- **RAM fitness indicator**: Color-coded dot (green/yellow/red) shows whether a model fits in system RAM
- **Capability badges**: Vision (eye) and tool calling (wrench) icons based on pipeline tag and model family heuristics
- **Compatibility filtering**: Incompatible pipeline types (e.g. `text-to-image`) shown grayed out with reason
- **Architecture detection**: Models with unsupported architectures (LFM2, Nemotron-H, etc.) flagged with red "Unsupported architecture" label — HF tags checked via prefix matching (`gemma`, `qwen`, `llama`, `mistral`), local models checked via `model_type` from `config.json`. Download still allowed.
- **Download integration**: Download button with progress tracking, resume support for interrupted downloads
- **Downloaded models view**: "Downloaded" toggle switches to local filesystem view — shows models from `~/.mlx-serve/models/` with size on disk, filter field, no HuggingFace API calls
- **Active downloads in Downloaded tab**: Downloading and failed downloads appear above local models with progress bars, speed indicators, and Resume/Retry buttons
- **Delete models**: Trash button with confirmation alert on both HuggingFace and local views — removes all downloaded files and refreshes model picker
- **"Browse All MLX Models" button**: Added to tray menu Models section for quick access

### Vision Encoder Crash Fix
- **Graceful fallback for text-only quantized models**: Models like Qwen 3.5 have `vision_config` in config.json but ship without vision weights — previously crashed with `unreachable` in `getVisionWeight()`. Now checks for essential patch embedder weights before allocating layer arrays, returning `MissingVisionWeights` which disables vision gracefully

### Menu Bar Status Icon
- **Tinted tray icon**: Menu bar icon color reflects server status — red when stopped, orange when starting, normal system tint when running
- **Nested ObservableObject fix**: `AppState` forwards `ServerManager.objectWillChange` via Combine subscription so `MenuBarExtra` label reacts to server status changes

### Other Changes
- **Model download list**: Quick-download section in tray menu now shows 8-bit models only (filtered from full list)
- **Window focus handling**: `openAndFocus()` updated for Model Browser window routing

### Testing
- **`tests/test_vision_moe_regression.sh`**: 25-test regression script covering basic forward pass, vision pipeline, `--no-vision` restart, MoE-specific paths, and crash detection. Auto-detects model capabilities from config.json. Self-contained: builds, starts server, runs tests, cleans up

---

## v26.4.21 — Vision Pipeline, Prefill/Decode Metrics, AgentEngine, UX Polish

### Vision Encoder (Gemma 4 SigLIP)
- **Full vision pipeline**: Gemma 4 models can now process images end-to-end — SigLIP vision encoder with patch embedding, 2D RoPE, clipped linears, position pooling, and embedding projection
- **Image decoding**: JPEG/PNG via stb_image, WebP via libwebp — decoded, resized to model's expected resolution, converted to float32 CHW format
- **OpenAI `image_url` content blocks**: Supports `data:image/jpeg;base64,...` and preprocessed `data:image/x-mlx-pixels;base64,...` in chat completion requests
- **`--no-vision` flag**: Disables vision encoder at startup to save ~340MB GPU memory when not needed
- **KV cache invalidation on image requests**: Image tokens have identical IDs but different vision embeddings — cache is reset to prevent stale feature reuse
- **New FFI bindings**: `mlx_equal`, `mlx_remainder`, `mlx_ones`, `mlx_minimum`, `mlx_cos`, `mlx_sin`, `mlx_array_data_bool` added to `mlx.zig`
- **Build changes**: Links stb_image and libwebp; `build.zig` updated for both exe and test targets

### Prefill/Decode Metrics
- **Separate timing in server logs**: All 6 handler paths (non-streaming/streaming × completions/chat/Anthropic) now report prefill and decode tok/s independently instead of a single combined figure
- **Old**: `<- 1133+256 tokens (5906ms, ~43 tok/s) [length]`
- **New**: `<- 1133+256 tokens (5906ms) [prefill: 606 tok/s, decode: 63 tok/s] [length]`

### 3x Prefill Speedup — Split Prefill (matches mlx-lm)
- **Root cause**: The full forward pass applied `lm_head` projection (`[seq_len, 1536] @ [1536, 262144]`) over the entire prompt — for 870 tokens that's a ~912MB output tensor computed and immediately discarded (only the last position's logits are needed for sampling)
- **Fix**: `Generator.init()` now splits prefill into two phases, mirroring mlx-lm's `generate_step`:
  1. **Prefix pass** (N-1 tokens): Forward pass builds the lazy graph including `lm_head`, but only KV cache entries are evaluated — MLX's lazy evaluation skips the `lm_head` matmul entirely since nothing depends on it
  2. **Last token pass** (1 token): Forward + `lm_head` on a single token produces the logits needed for sampling, then chains into the decode pipeline via `async_eval`
- **`mlx_clear_cache()`** between phases frees intermediate Metal buffers from the prefix pass
- **Conditional KV array allocation**: Moved 9 temp array declarations inside the non-shared KV block in `forwardStandard()` — eliminates 180 unnecessary `mlx_array_new()`/`free()` calls per forward pass for Gemma 4 E2B (20 of 35 layers share KV)

#### Benchmark: Gemma 4 E2B-it 4-bit, Apple Silicon (mlx 0.31.1, mlx-c 0.6.0, llama.cpp b8680)

**Prefill (tok/s)**

| Prompt length | mlx-serve | mlx-lm | llama.cpp |
|---------------|-----------|--------|-----------|
| Short (~20 tok) | 22 | — | 189 |
| Medium (~100 tok) | 252 | — | 397 |
| Long (~900 tok) | **1,266** | ~equal wall | 554 |

**Decode (tok/s)**

| Test | mlx-serve | mlx-lm | llama.cpp |
|------|-----------|--------|-----------|
| 300-token generation | **63.7** | 61.7 | 48.0 |
| Reasoning Q&A | **64.3** | 60.8 | 47.9 |
| Code generation | **63.4** | 59.9 | 46.7 |
| Tool calling | **62.4** | N/A | 47.1 |

**Wall time (ms) — agentic workloads**

| Test | mlx-serve | mlx-lm | llama.cpp |
|------|-----------|--------|-----------|
| Tool call selection | **798** | N/A | 6,767 |
| Multi-turn tool fix | **8,278** | 8,567* | 11,293 |
| Code gen (600 tok) | **9,657** | 9,960 | 13,003 |

*mlx-lm has no tool calling support — tool tests adapted to plain prompts

- **2.3x faster prefill** than llama.cpp on long prompts
- **35% faster decode** than llama.cpp, 5% faster than mlx-lm
- **8.5x faster tool calling** than llama.cpp (only engine producing valid structured tool calls)
- **25–35% faster wall time** than llama.cpp on generation-heavy tasks

### MLX Core App — Image Support
- **Image attachment UI**: Drag-and-drop or paste images into the chat input; thumbnails with remove buttons shown before sending
- **`ImagePreprocessor`**: Resizes and converts images to float32 CHW pixel data for the vision encoder
- **`ChatImage` model**: JPEG image data attached to `ChatMessage`, persisted via Codable
- **Multimodal content blocks**: `buildMultimodalContent()` constructs OpenAI-format `image_url` content blocks with preprocessed pixel data
- **Screenshot capture from browse tool**: Browse results can include screenshots sent as vision input

### MLX Core App — Agent Improvements
- **`cwd` tool**: New "Change Directory" tool lets the agent switch working directory for subsequent shell commands
- **Shell output includes cwd**: Shell tool results now show `[cwd: /path]` prefix so the model knows where commands ran
- **Context monitor**: Real-time prompt token / context length usage bar shown above the input area
- **Context-aware image handling**: Images stripped from history replay to avoid stale vision features and context waste

### MLX Core App — UI Refinements
- **StatusMenuView cleanup**: Streamlined server controls layout
- **TestServer vision support**: Test API endpoints handle image content blocks for automated vision testing

### Model Support
- **Vision config parsing**: `ModelConfig` now parses `vision_config` from `config.json` (hidden_size, num_layers, num_heads, head_dim, intermediate_size, patch_size, pooling, position_embedding_size, etc.)
- **`loadWeightsWithVision()`**: Loads both language model and vision tower weights from safetensors

### Testing
- **`tests/test_vision.sh`**: Vision pipeline integration tests
- **`tests/fixtures/`**: Test image fixtures for vision tests

### AgentEngine — Shared Agent Logic (DRY refactor)
- **New `AgentEngine.swift`**: Extracted ~350 lines of duplicated agent logic from `ChatView.swift` and `TestServer.swift` into a single shared module — history building, tool execution, repetition tracking, token estimation, overflow management, debug dump
- **`RepetitionTracker` class**: Encapsulates three-phase tool repetition state (warn → soft block → escalation) with arg-aware tracking — `listFiles("src")` and `listFiles("lib")` are now different entries
- **`executeToolCall()`**: Single entry point for tool execution — handles cwd, smart editFile→writeFile fallback, validation, blocking, and warning injection
- **`buildAgentHistory()`**: Unified history builder with budget-aware truncation, all-user-message pinning, first-assistant pinning, optional multimodal content via closure
- **TestServer now uses AgentEngine**: Eliminated all duplicated functions — also gained first-assistant pinning that TestServer was previously missing

### Tool Blocking Overhaul
- **Arg-aware tracking**: Repetition keys are `"name:primaryArg"` (e.g. `"listFiles:src"`) instead of just tool name — different directories/queries are tracked separately
- **Three-phase system**: Warning at 5 in 12 (tool executes, result prefixed with warning), soft block at 8 in 12 (blocked for 3 iterations), escalation (calling during cooldown extends by 5)
- **Tool-specific messages**: Block/warning messages suggest relevant alternatives (`listFiles` → `ls`, `readFile` → `cat`, `searchFiles` → `grep -r`)
- **Write tools exempt**: `writeFile`, `editFile`, `shell`, `cwd` are never warned or blocked

### History Budget Fix
- **Cap maxTokens for budget math**: Generation reservation capped to 40% of context — fixes negative budget on small-context models (E2B: budget went from 1024 → ~7363 tokens)
- **Pin all user messages**: User messages carry critical facts (name, preferences, task instructions) and are now always pinned, with safety cap at 30% of budget falling back to first + last

### Workspace Context Injection
- **Directory listing in system prompt**: Working directory contents auto-injected into system prompt each iteration — model always knows what files exist without calling `listFiles`
- **Refreshes on `cwd` change**: When agent changes directory, next iteration shows the new directory's contents
- **`listFiles` tool description updated**: Tells model the root listing is already in the system prompt

### JPEG Vision Fix
- **`CGImageSource` with EXIF orientation**: Replaced `NSImage.cgImage(forProposedRect:)` with `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform` — camera JPEGs now render correctly instead of sideways
- **Explicit byte order**: Added `CGBitmapInfo.byteOrder32Big` to CGContext — guarantees `[R, G, B, X]` memory layout regardless of platform endianness (ARM defaults to little-endian which scrambles to `[X, B, G, R]`)
- **Y-axis flip**: CGContext origin is bottom-left, vision encoder expects top-left — added `translateBy/scaleBy` transform
- **Dual fallback path**: CGImageSource → NSImage fallback ensures all image formats are handled

### Duplicate Instance Guard (Zig)
- **Port check before model loading**: In `--serve` mode, tries connecting to the target port before loading the model — exits immediately with a clear error if another instance is already running
- **Fail-fast**: No GPU memory wasted on model loading when the port is taken

### Welcome Window
- **First-launch onboarding**: `WelcomeView` shows app icon, feature cards (menu bar operation, local models, agent tools), and animated hint pointing to the tray icon
- **NSWindow-based**: Menu bar apps don't auto-open SwiftUI `Window` scenes — uses direct `NSWindow` + `NSHostingView` from `AppState.init()`
- **One-time display**: Tracked via `hasSeenWelcome` in UserDefaults

### Chat UX Polish
- **Numpad Enter support**: Both Return and numpad Enter (`\u{03}`) now send messages
- **Type while generating**: Input field stays enabled during generation — Enter blocked until complete
- **Generating indicator**: Replaced spinner with animated dual-arc GPU/memory visualization + live `GPU X% · Mem Y%` stats + rotating whimsical status text
- **Auto-scroll re-engage**: GeometryReader moved to bottom anchor element for reliable position tracking; downward scroll events check proximity to bottom and re-engage
- **Auto-scroll indicator**: 4px accent-colored right-edge strip, visible when auto-scroll is active, fades on disengage
- **Markdown HTML fix**: Parser now whitelists model-specific tags (`plan`, `thinking`, `pad`, etc.) — standard HTML tags (`head`, `div`, `meta`) render as text instead of being swallowed into XML block styling

---

## v26.4.20 — Tool Reliability, Thinking+Tools, Truncation Recovery

### Tool Parameter Key Order (3-layer fix)
- **Pre-serialized tool JSON**: `toolDefinitionsJSON` is a hand-crafted JSON string with guaranteed `path` before `content` in all file tools — bypasses `JSONSerialization`'s non-deterministic key ordering
- **Request body splicing**: `streamChat()` splices the pre-serialized tools JSON directly into the HTTP body instead of letting Swift re-order keys
- **Truncated JSON recovery**: `extractPathFromTruncatedJSON()` uses string search to find `"path":"..."` in malformed/truncated args even when JSON parsing fails entirely
- **Improved JSON repair**: Repair block now tracks unmatched `{`/`[` openers respecting quoted regions and appends correct closing characters (was blindly appending single `}`)
- **Path cleaning**: `cleanPath()` strips spurious surrounding quotes from paths — models sometimes generate `"\"app.py\""` which becomes `"app.py"` with literal quotes after JSON unescaping

### Thinking + Tools Fix
- **Streaming**: When `has_tools=true`, thinking blocks were detected and **stripped** via `stripThinkBlock()` but never emitted as `reasoning_content`. Now uses `splitThinkBlock()` to separate reasoning from content and emits both
- **Non-streaming**: Tool call responses had `"content":null` with no `reasoning_content` field. Now includes `reasoning_content` when thinking is enabled
- **Root cause**: The `if/else if` control flow meant the thinking branch could never execute when the tools branch was active

### Gemma 4 Tool Call Parsing
- **Nested brace/array values**: `convertGemma4ArgsToJson()` now handles bare nested objects (`{config:{"port":3000}}`) and arrays (`{stops:["Rome","Venice"]}`) via depth-tracked brace matching — was previously falling through to bare-value parsing and producing invalid JSON

### Agent Prompt & Token Limits
- **Default max_tokens**: 8192 → 32768 — prevents tool call argument truncation for large file writes
- **writeFile size guidance**: System prompt and tool description now direct models to use `shell` with `cat` heredoc for files over 100 lines — writeFile's JSON-escaped content inflates token cost ~30% vs raw heredoc
- **Max tokens warning**: New `SSEEvent.maxTokensReached` emitted when server returns `finish_reason: "length"` — chat shows "Output truncated — max tokens (N) reached"
- **Tool output overflow**: Truncation message no longer tells model to `readFile` the overflow file (which is outside the workspace and gets blocked by confinement) — just shows `[... truncated at N of M chars]`

### Claude Code Launcher
- **Removed from chat toolbar**: Claude Code button removed from ChatView — only in tray menu now
- **Directory picker**: Tray menu button shows `NSOpenPanel` folder picker before launching (defaults to `~/.mlx-serve/workspace`)
- **White icon**: Uses `ClaudeIcon(size: 12)` with `.foregroundStyle(.white)` matching the chat icon style

### Dead Code Removal
- **Removed `chatWithTools()`**: Non-streaming tool call method was never called — app uses streaming-only. Removed along with `ToolCallResult` struct

### Testing
- **`tests/test_thinking_tools.sh`**: 27 integration tests covering all 8 permutations of thinking × tools × streaming, plus mixed-mode scenarios
- **`tests/test_swift_agent.sh`**: Comprehensive Swift agent harness test — exercises all 9 tools (writeFile, readFile, editFile, shell, searchFiles, listFiles, webSearch, browse, saveMemory) through the TestServer API
- **`ToolKeyOrderTests.swift`**: 34 unit tests for JSON key order, request body splicing, `extractPathFromTruncatedJSON` edge cases, JSON repair, and end-to-end `parseToolCallArgs` integration

---

## 2026.4.12 — MLX Core Rename, Agent Overhaul

### Rename: MLX Claw → MLX Core
- **Full rebrand**: App renamed from "MLX Claw" to "MLX Core" across all source, build scripts, CI/CD, docs, tests, and bundle identifiers (`com.dalcu.mlx-core`)

### New Tool: listFiles
- **Dedicated file listing**: `listFiles` tool with glob pattern matching and recursive traversal — replaces shell `ls`/`find` in agent workflows
- **Tool routing guidance**: System prompt now directs the model to use dedicated tools (`readFile`, `writeFile`, `editFile`, `searchFiles`, `listFiles`) instead of shell equivalents

### Agent Loop Improvements
- **150 max iterations** (up from 30): Supports complex multi-step agent tasks
- **Token-aware context management**: `buildAgentHistory()` now estimates token costs per message and fits history to the context budget instead of using a fixed 28-message window
- **Tool result overflow**: Oversized tool results saved to `~/.mlx-serve/tool-output/` with a truncated preview in context plus a pointer to the full file — prevents context blowout from large shell output or file reads
- **Per-tool context caps**: shell 6K, readFile 8K, searchFiles/listFiles 4K, browse 3K, webSearch 2K, editFile/writeFile 2K
- **Working directory injection**: Agent system prompt now includes the working directory path so relative paths resolve correctly
- **Pad retry with backoff**: Failed empty generations use exponential backoff (`RetryPolicy.aggressive`) instead of immediate retry

### System Prompt Redesign
- **Hardcoded base + additive user customization**: Base system prompt is no longer editable — `~/.mlx-serve/system-prompt.md` now contains only user additions appended via `# User Instructions`
- **File editing rules**: Explicit instructions for readFile → editFile workflow (line numbers, exact match, startLine/endLine for large files)
- **Error recovery section**: Structured guidance for tool failure diagnosis
- **Memory cap**: Memory entries capped at last 30 lines / 2000 chars to prevent context bloat

### Tool Enhancements
- **readFile with line numbers**: Output now shows `N| text` format so the model can reference specific lines for editFile
- **readFile large file headers**: Files >200 lines or >6KB show metadata header with total line count and byte size
- **searchFiles upgrade**: Uses ripgrep when available, supports `include` glob filter, `context` lines, and `maxResults` parameter
- **writeFile unescape**: Handles `\\n`, `\\t`, `\\\"` double-escaping from smaller models
- **Shell output uncapped**: Removed 8KB truncation on shell results (overflow system handles large output instead)

### API Client
- **Retry with exponential backoff**: Network errors (connection lost, timeout, cannot connect) retry up to 5 times with jitter — replaces single-retry on connection lost
- **Tool call argument cleanup**: Strips surrounding quotes from tool call parameter values that smaller models add

### Claude Code Launcher
- **Folder picker**: Claude Code button in chat toolbar opens NSOpenPanel to select working directory before launch
- **Working directory support**: `launchClaudeCode()` now accepts and `cd`s into the chosen directory
- **Claude icon**: Custom SwiftUI `ClaudeShape` renders the official Claude AI logo SVG as a native Shape

### UI
- **Scroll tracking fix**: Replaced window-frame-based scroll detection with proper GeometryReader preference keys; upward mouse scroll disengages auto-scroll, scrolling back to bottom re-engages
- **Compact bottom bar**: Browser and Claude Code buttons use icon-only style with tooltips
- **Overflow file cleanup**: Old tool-output files (>24h) cleaned up on session start

### TestServer
- **Non-blocking agent jobs**: `POST /test/agent` now returns immediately with a `job_id`; poll `GET /test/agent/status` for progress and results

---

## 2026.4.11 — Anthropic API, Claude Code, KV Cache Fix

### Anthropic Messages API
- **`POST /v1/messages`**: Full Anthropic API compatibility layer — Claude Code and other Anthropic SDK clients can use local models
- **Request conversion**: Anthropic content blocks (`text`, `tool_use`, `tool_result`, `thinking`) converted to internal format; `system` as top-level field; tools `input_schema` converted to OpenAI `parameters` for chat template compatibility
- **Streaming SSE**: Named events (`message_start`, `content_block_start/delta/stop`, `message_delta`, `message_stop`) with `text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta` delta types
- **Non-streaming**: Anthropic response format with content block arrays, `stop_reason` mapping (`stop`→`end_turn`, `length`→`max_tokens`, `tool_calls`→`tool_use`)
- **`HEAD /` handler**: Claude Code sends a connectivity check before API calls — now returns 200
- **Query string stripping**: `POST /v1/messages?beta=true` now correctly routes (Claude Code appends `?beta=true`)

### Claude Code Integration
- **Launch button**: "Launch Claude Code" button in MLX Core menu bar (visible when server is running) — opens Terminal with `claude` CLI configured to use the local server via `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, model tier overrides
- **Binary detection**: Finds `claude` via login shell PATH (`/bin/zsh -l -c "which claude"`) with fallback to `~/.local/bin/claude`
- **`.command` file approach**: Uses `NSWorkspace.open()` on a temp `.command` file — no AppleScript permissions needed

### GPU Memory Safety
- **Attention memory preflight check**: Estimates peak GPU memory (attention matrix + KV cache + 20% margin) before prefill and rejects with a 400 error instead of crashing the server with an uncatchable Metal C++ exception
- **Dynamic Metal limit**: Queries actual system memory via `sysctl hw.memsize` × 75% (not hardcoded) — works correctly on 16GB and 128GB machines
- **Context size auto-detection**: Default context size computed from GPU memory at startup (replaces hardcoded 16K cap). Logged as `Context size: N tokens (auto, from GPU memory)`

### Context Size UI
- **Context size selector**: New UI in MLX Core server block with Auto/16K/32K/64K/128K presets
- **Auto mode**: When set to Auto (default), server computes safe max from model architecture + available GPU memory
- **GPU safe max indicator**: Shows "GPU safe max: XXK" under buttons; turns orange when selected size exceeds safe limit
- **`--ctx-size` passed to server**: Only when manually selected (Auto = no flag, server computes)
- **`/props` endpoint**: New `max_safe_context` field in memory info

### KV Cache Sliding Window Fix
- **Removed incorrect cache invalidation**: The old code reset the entire KV cache when prompts exceeded the sliding window size (512 for Gemma 4), causing full re-encoding of the entire prompt on every request
- **Root cause**: The comment claimed sliding window layers "trimmed their KV buffers" — but `KVCache.update()` stores ALL tokens in the buffer and only creates windowed views for decode. `truncate()` is safe since it only updates offsets
- **Impact**: Claude Code agent loop requests with shared 24K-token prefix go from full prefill (~2s) to prefix reuse (~0.5s) — **3-4x faster per iteration**

### Testing
- **`tests/test_anthropic_api.sh`**: 40 integration tests — non-streaming, streaming, tool calling, tool result round-trip, error handling, streaming event order, model name echo, stop_sequences, Anthropic headers
- **`tests/test_kv_cache_sliding_window.sh`**: KV cache reuse validation for sliding window models — measures cache-hit vs cache-miss timing, verifies prefix reuse across multi-turn tool-calling conversations

---

## 2026.4.10 — Deep Agent Loop Reliability

### Tool Call Argument Fixes
- **KV cache reuse after tool calls**: Removed unnecessary full cache invalidation after tool-calling requests — `reuseKVCache()` already truncates to the shared prefix via `cache.truncate()`, correctly discarding stale generated-token entries. Significant performance win in deep agent loops (avoids re-encoding system prompt + tool definitions every round).
- **History windowing fix**: `buildAgentHistory()` now pins the first user message (the original task) even when `.suffix(28)` drops it. Prevents the model from losing task context after ~10 iterations.
- **Progressive tool result truncation**: Older tool results truncated to 500 chars, last 2 kept at 2000 chars — slows context growth by ~75% per old tool result without losing recent context.
- **Generation budget warning**: `clampMaxTokens` warns when remaining tokens fall below 25% of requested `max_tokens`, flagging potential tool call argument truncation.
- **Diagnostic logging**: Logs prompt token count, effective max generation tokens, and context size after every request. Logs byte count of generated text before tool call parsing.

### Tool Calling UX
- **Pre-validation of required params**: Before executing a tool, checks required parameters against the tool definition. Missing params get a detailed error with the expected JSON format (from the tool definition's example), reducing retry rounds.
- **Raw args in UI**: Tool call summary now shows the raw arguments the model generated, so users can see exactly what the model tried to send (instead of just "empty args").
- **Browse URL auto-fix**: `BrowserManager.navigate()` prepends `https://` when the model omits the URL scheme — models frequently send `httpbin.org/html` instead of `https://httpbin.org/html`.
- **Browse tool example fix**: Tool definition example changed from `readText` to `navigate` (the typical first action), preventing misleading error messages.
- **Error message clarity**: Changed "Expected format:" to "Example:" in tool error feedback to avoid implying a single valid format.
- **TestServer nudge fix**: Changed nudge from "Process the tool results above and respond" to match ChatView's "Continue. If the task is done, summarize the result. If not, take the next step."

### Code Quality
- **`sampleTokenLazy` refactor** (generate.zig): Replaced three boolean ownership flags (`scaled_owned`, `topk_owned`, `topp_owned`) with a single `current` variable pattern — each step frees the old intermediate before reassignment. Fixes a memory leak when `temperature=1.0` with top-k/top-p applied.
- **`APIClient.ToolCall.rawArguments`**: New field preserves the raw JSON string from the server, so downstream code can display what the model actually generated.

### Testing
- **Deep agent loop test**: New `tests/test_deep_agent_loop.sh` — 12-iteration tool call regression test via curl, checking finish_reason, argument validity, required keys, and token budget squeeze per iteration.
- **New Swift tests**: `testHistory_ProgressiveTruncation`, `testHistory_FirstUserMessagePinned`, `testHistory_FirstUserNotDuplicatedWhenInWindow`, `testHistory_TruncationAt28PlusPinnedFirst`.

---

## 2026.4.9 — Inference Performance Optimization

### Async Pipeline Overhaul
- **Submit-first pipeline**: Reordered generation loop to build and `async_eval` the next step BEFORE eval'ing the current token — the GPU computes the pending token as a dependency of the next forward pass, making `eval()` return instantly. Matches mlx-lm's `_step(y) → async_eval(next_y) → y.item()` pattern.
- **Fully-lazy token pipeline**: Sampled tokens stay as lazy MLX arrays fed directly into the next forward pass — no GPU→CPU→GPU roundtrip for token IDs between decode steps.
- **Deferred token eval**: Token materialization deferred to the start of the next iteration, giving the GPU maximum overlap time during HTTP streaming and caller processing.

### JIT-Compiled Activations
- **Compiled GELU**: `mlx_compile(shapeless=true)` fuses 8 separate ops (power, multiply, add, tanh, etc.) into a single GPU kernel, matching mlx-lm's `@mx.compile` on `nn.gelu_approx`.
- **Compiled GeGLU**: Fuses `gelu(gate) * up` into one kernel for the MLP block (called 42x per token).
- **Compiled softcap**: Fuses `tanh(x/cap) * cap` logit softcapping into one kernel.

### Memory & Scheduling
- **GPU memory wiring**: `mlx_set_wired_limit` set to `max_recommended_working_set_size` to prevent model weight paging.
- **Periodic cache clearing**: `mlx_clear_cache()` every 256 tokens to reduce memory fragmentation.
- **Dedicated generation stream**: Uses `mlx_stream_new_device` for generation compute.

### Minor Optimizations
- **Eliminated per-call `detectQuantBits`**: Quantization bits read once from config instead of re-detected via shape inspection on every matmul (~378 calls/token saved).

### Results
- **Decode: ~33 tok/s** on Gemma-4 E4B 4-bit (Mac Mini M4 16 GB), matching mlx-lm (Python)
- **Prefill: ~300 tok/s** on 840-token prompt
- **Memory: 4.0 GB** (7% less than mlx-lm's 4.3 GB)
- **Startup: ~2s** (3x faster than mlx-lm, no Python runtime)

---

## 2026.4.6 — Gemma 4 MoE, Jinja Upgrade, Tool Calling Overhaul

### Gemma 4 Full Support
- **Gemma 4 MoE (26B-A4B)**: Sigma-MoE routing, separate shared/routed expert branches, 5 feedforward norms, layer scalar, GeGLU activation
- **Gemma 4 E2B/E4B**: Per-Layer Embeddings (PLE) with gated projection, per-layer input scaling
- **ProportionalRoPE**: Correct frequency computation for global attention layers with positive exponents and full head_dim denominator
- **K=V attention**: Global layers share K projection as V (no separate v_proj) with automatic fallback
- **Per-weight quantization detection**: Auto-detect quant bits per weight instead of global default (fixes 8-bit shared expert in 4-bit model)
- **Sliding window attention**: Correct KV cache view handling — full buffer during prefill, windowed during decode (matches mlx-lm's RotatingKVCache)
- **Logit softcapping**: Applied after final norm + lm_head projection

### Jinja Template Engine Upgrade
- **Replaced jinja.hpp with llama.cpp's Jinja engine**: Full-featured C++17 Jinja2 implementation with nlohmann/json
- **Fixed tool call argument rendering**: Old engine produced empty args (`{command:{}}` instead of `{"command":"echo hi"}`)
- **Fixed tool parameter types**: Old engine lost type info (`type:<|"|><|"|>` instead of `type:<|"|>STRING<|"|>`)
- **Removed broken tool message transformation**: `role:"tool"` messages now passed natively to templates (both E4B and 26B templates handle it correctly)
- **Removed redundant tool_responses field**: Was causing duplicate content in rendered prompts (~66 extra chars per tool response)
- **Tool call arguments serialized as JSON string**: Prevents templates from re-serializing parsed objects incorrectly

### Tool Calling Reliability
- **Gemma 4 double-brace parsing**: Model generates `{{"key":"value"}}` — outer braces now unwrapped before JSON parsing
- **Streaming SSE argument fix**: Full arguments sent in single delta instead of empty + chunks (prevents `""query` double-quote accumulation on client)
- **KV cache invalidated after tool-calling requests**: Prevents stale attention state from generated tool-call tokens poisoning the next request
- **User nudge after tool results**: Synthetic user message added when last history entry is `role:"tool"` (some models can't generate without it)
- **Improved tool descriptions**: Examples in each tool definition guide parameter usage
- **Better error messages**: Tool errors include what args were sent and ask model to retry with correct parameters

### Thinking/Reasoning Mode
- **Fixed thinking leak with tools**: `<|channel>thought` content no longer streamed as visible content when tools are present
- **Gemma 4 channel tag stripping**: `<|channel>` and `<channel|>` tags stripped from content output
- **Partial thinking detection**: Buffers tokens when `<|channel>` prefix detected (before `thought` suffix arrives) to prevent premature flushing
- **`splitThinkBlock` fixes**: Correct handling of Gemma 4's `<|channel>thought...<channel|>\n<|channel>\ncontent` format

### MLX Core App
- **Auto-start server on launch**: Toggle in menu bar, persists selected model in UserDefaults
- **Selected model persistence**: Last used model path saved across launches
- **Test API server** (port 8090): REST endpoints for automated testing (`/test/start`, `/test/stop`, `/test/reset`, `/test/chat`, `/test/agent`, `/test/history`, `/test/status`)
- **Concurrent request handling**: TestServer accept loop runs on background GCD thread, each request handled concurrently
- **Health polling fix**: DispatchSource timer for reliable server status detection (replaces Timer/Task approaches that failed with MenuBarExtra apps)
- **Agent loop iterations**: Increased from 10 to 30 for complex multi-step tasks
- **Browse tool fix**: `readText` action now navigates to URL first (was returning previous page's content)
- **WebSearch results**: Structured extraction of titles/URLs/snippets instead of raw DuckDuckGo HTML
- **UI**: "Tool Call" label with wrench icon (was "Summary"), folder button opens `~/.mlx-serve/`
- **`buildAgentHistory` fixes**: Filters "couldn't generate" error messages, strips `<pad>`, truncates assistant content at 500 chars, matches ChatView exactly in TestServer

### Server Fixes
- **Pad-only cache invalidation**: Detects all-zero token IDs and invalidates cache + prompt IDs
- **Sliding window cache check**: Reset cache when either previous or new prompt exceeds window (was only checking `cached > sw AND shared < sw`)
- **`moe_seq_offset` sync**: Properly updated on both truncation and full reset paths

---

## 2026.4.5 — Prompt-Based Skills, Resumable Downloads

- **Prompt-based skills system**: User-defined agent capabilities via `~/.mlx-serve/skills/*.md` with YAML frontmatter (name, description, trigger keywords)
- **Resumable downloads**: Streaming writes to `.partial` files, Range header support for resume, 3 automatic retries with backoff
- **Disk space safety**: Pre-check available space before large downloads
- **SkillManager**: Scans skills directory on each agent loop, re-reads when directory modification date changes

## 2026.4.4 — KV Cache & Tool Calling Fixes

- **KV cache corruption fix**: Invalid suffix cache invalidation, SSM state reset
- **Tool calling reliability**: Improved tool call parsing, agent harness stability
- **App bundle packaging**: Removed Bundle.module dependency, fixed codesigning

## 2026.4.3 — MLX Core Major Update

- **Native tool calling UI**: 7 built-in tools (shell, readFile, writeFile, editFile, searchFiles, browse, webSearch)
- **Agent mode**: Automatic ReAct loop with tool execution and result feeding
- **Browser integration**: WKWebView-based browsing, headless operation for background tool use
- **Streaming chat**: SSE parsing with delta reconstruction for real-time responses
- **Multi-session chat**: Persistent chat history with session management

## 2026.4.2 — MLX Core Initial Release

- **Swift macOS menu bar application**: Server management, model selection, chat interface
- **Server lifecycle**: Subprocess launch/termination with stderr capture
- **Model discovery**: Local model scanning from `~/.mlx-serve/models/`

## 2026.3 — Embeddings, Reasoning, Jinja

- **Embedding support**: BERT and encoder-only models via `/v1/embeddings`
- **Reasoning budget**: `--reasoning-budget` CLI flag to limit thinking tokens
- **Jinja_cpp integration**: Replaced vibe-based Jinja (macros caused infinite loops)
- **Qwen3.5 MoE support**: GatedDeltaNet linear attention, shared expert routing
- **TUI status bar**: Live CPU, memory, GPU metrics

## 2026.2 — Initial Release

- **Zig native server**: OpenAI-compatible HTTP API on Apple Silicon
- **MLX-c FFI**: GPU-accelerated tensor operations via Apple's MLX C API
- **Model support**: Llama 3, Mistral, Qwen 3
- **BPE tokenizer**: SentencePiece and byte-level BPE
- **Streaming generation**: SSE-based real-time token delivery
- **KV cache reuse**: Prompt prefix matching across requests
- **Sampling**: Temperature, top-p, top-k, repeat penalty
