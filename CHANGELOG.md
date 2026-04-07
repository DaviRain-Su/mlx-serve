# Changelog

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

### MLX Claw App
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

## 2026.4.3 — MLX Claw Major Update

- **Native tool calling UI**: 7 built-in tools (shell, readFile, writeFile, editFile, searchFiles, browse, webSearch)
- **Agent mode**: Automatic ReAct loop with tool execution and result feeding
- **Browser integration**: WKWebView-based browsing, headless operation for background tool use
- **Streaming chat**: SSE parsing with delta reconstruction for real-time responses
- **Multi-session chat**: Persistent chat history with session management

## 2026.4.2 — MLX Claw Initial Release

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
