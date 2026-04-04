# mlx-serve – project context for AI

Native Zig server that runs MLX-format LMs on Apple Silicon and exposes an OpenAI-compatible HTTP API. No Python.

## Stack

- **Zig** 0.15+
- **mlx-c** (Apple) via Homebrew; FFI in `src/mlx.zig`
- **Jinja_cpp** (lib/jinja_cpp): chat templates; replaces previous vibe-based Jinja (macros caused infinite loop)
- **safetensors** for weights; BPE tokenizers (SentencePiece / byte-level)

## Layout

| Path | Role |
|------|------|
| `src/main.zig` | Entry, CLI (`--model`, `--serve`, `--host`, `--port`, `--prompt`, `--max-tokens`, `--temp`, `--ctx-size`, `--timeout`, `--reasoning-budget`, `--log-level`, `--version`, `--help`) |
| `src/mlx.zig` | mlx-c FFI |
| `src/model.zig` | Config + safetensors loading; supports Gemma-3, Gemma-4, Qwen3, Qwen3.5 MoE, Qwen3-next, Llama, Mistral |
| `src/tokenizer.zig` | BPE tokenizer |
| `src/transformer.zig` | Forward pass (embedding, attention, MLP, MoE, GatedDeltaNet); architecture dispatch |
| `src/generate.zig` | Autoregressive generation, sampling (temperature, top-k, top-p, repeat penalty, presence penalty, logprobs) |
| `src/chat.zig` | Chat template formatting (ChatML, Gemma turns, Llama-3, Jinja2 via Jinja_cpp); thinking/reasoning tags; tool call parsing |
| `src/server.zig` | HTTP server: `/health`, `/v1/models`, `/v1/chat/completions`, `/v1/completions` (stream + non-stream, tool calling, KV cache) |
| `src/status.zig` | TUI status bar (CPU, memory, GPU metrics) |
| `src/log.zig` | Leveled logging (error, warn, info, debug) |
| `build.zig` | Zig build; links mlx-c and Jinja_cpp |

### MLX Claw (Swift macOS app)

| Path | Role |
|------|------|
| `app/Package.swift` | Swift package; `MLXClaw` executable + `MLXClawTests` test target |
| `app/Sources/MLXServe/MLXServeApp.swift` | App entry, menu bar + Chat/Browser windows |
| `app/Sources/MLXServe/AppState.swift` | Global state, chat session management, persistence |
| `app/Sources/MLXServe/Models/ChatModels.swift` | `ChatMessage`, `SerializedToolCall`, `ChatSession` |
| `app/Sources/MLXServe/Models/AgentModels.swift` | `AgentToolKind`, `AgentPlan`, `StepResult` |
| `app/Sources/MLXServe/Services/APIClient.swift` | HTTP + SSE streaming client for mlx-serve |
| `app/Sources/MLXServe/Services/AgentPrompt.swift` | System prompt + tool definitions (7 tools) |
| `app/Sources/MLXServe/Services/ToolExecutor.swift` | Tool handlers: shell, readFile, writeFile, editFile, searchFiles, browse, webSearch |
| `app/Sources/MLXServe/Services/BrowserManager.swift` | WKWebView (headless, created eagerly for background browsing) |
| `app/Sources/MLXServe/Services/ServerManager.swift` | mlx-serve process lifecycle, stderr capture (`serverLog`) |
| `app/Sources/MLXServe/Services/AgentMemory.swift` | Agent context memory (recent dirs, commands) |
| `app/Sources/MLXServe/Views/ChatView.swift` | Chat UI + `runAgentLoop()` + `buildAgentHistory()` |
| `app/Sources/MLXServe/Views/StatusMenuView.swift` | Menu bar UI, server log viewer |
| `app/Sources/MLXServe/Views/BrowserView.swift` | Browser window (uses shared WKWebView) |

## Testing

- `zig build test` — unit tests (chat, server, generate, model, log, tokenizer)
- `cd app && swift test` — Swift unit tests (agent harness, SSE parsing, serialization, history)
- `./tests/integration_test.sh [model_dir] [port]` — 36 end-to-end API tests (needs a model)
- `./tests/test_tool_response.sh [port]` — tool calling round-trip tests (needs running server)
- `./tests/test_kv_cache_poison.sh [port]` — KV cache poisoning regression test (needs running server)
- Always run `zig build test` and `swift test` before submitting changes
- Add tests for new pure logic functions in the same source file (Zig convention)
- Shell integration tests go in `tests/` and need a running server with a loaded model

## Building

- Zig server: `zig build -Doptimize=ReleaseFast`
- Swift app: `cd app && swift build -c release`
- Both binaries must be copied to the app bundle:
  - `zig-out/bin/mlx-serve` → `app/MLX Claw.app/Contents/MacOS/mlx-serve`
  - `app/.build/arm64-apple-macosx/release/MLXClaw` → `app/MLX Claw.app/Contents/MacOS/MLXClaw`
- For tests: `zig build test` (Zig) and `cd app && swift test` (Swift)

## Conventions

- Prefer minimal, DRY Zig; avoid unnecessary abstraction.
- Chat templates live in model dirs; Jinja_cpp renders them (with fallback formatting).
- Server supports concurrent health checks via threaded connections, single-slot generation.
- KV cache reuse across requests via prompt prefix matching.
- Tests go at the bottom of each source file (Zig convention).

## Tool Calling Architecture

### Server side (Zig)
- **Tool call detection**: When `tools` param is present in request, server buffers ALL generated tokens (doesn't stream immediately). After generation completes, `chat.parseToolCalls()` checks the buffered text for tool call patterns (`<tool_call>`, Hermes XML, Gemma 4 `<|tool_call>`, raw JSON). If found, emits as `finish_reason: "tool_calls"`. If not found, flushes buffered tokens as regular content.
- **Message serialization for Jinja** (`chat.serializeMessagesJson`): Converts `Message` structs to JSON for Jinja templates. For `role: "tool"` messages, also adds `tool_responses` field (needed by Gemma 4 templates). Looks up tool name by matching `tool_call_id` to preceding assistant's `tool_calls`.
- **Gemma 4 template adaptation** (`chat.renderChatTemplate`): Detects templates using `tool_responses` (Gemma 4). Transforms `role: "tool"` → `role: "assistant"` with null content so the template produces `<|turn>model` (known role) instead of `<|turn>tool` (unknown). Content is carried via `tool_responses` field.
- **Fallback formatter** (`chat.fallbackFormatChat`): Used when Jinja fails. Handles ChatML (`<tool_call>/<tool_response>`), Llama (`ipython` role), Gemma (`Tool result:` in user turn).
- **KV cache**: `reuseKVCache()` compares token-by-token prefix with previous request. `updateCachedPrompt()` stores the prompt IDs after generation.

### Client side (Swift)
- **Agent loop** (`ChatView.runAgentLoop`): Up to 10 iterations. Calls model with tools → parses tool calls → executes locally → feeds results back → repeats until model responds without tool calls.
- **History builder** (`ChatView.buildAgentHistory`): Converts `ChatMessage` array to OpenAI API format. Assistant messages include `tool_calls` array. Tool responses include `role: "tool"` with `tool_call_id`.
- **SSE parsing** (`APIClient.performStream`): Accumulates streamed tool call deltas (name, arguments chunks). Preserves server-generated tool call IDs. Emits `.toolCalls` event on `finish_reason: "tool_calls"`. Fallback emission if stream drops without finish_reason.
- **Tool call storage**: `SerializedToolCall` (id, name, arguments as JSON string) stored on `ChatMessage.toolCalls`. Persisted via Codable for history replay. Backwards-compatible with old history files (field is optional).

## Debugging

### Server logs
- Start server with `--log-level debug` for verbose output (Jinja errors, cache hits, token counts)
- The MLX Claw app starts the server as a subprocess; stderr is captured in `ServerManager.serverLog` (64KB rolling buffer). View it via the log button (text-align icon) next to Start/Stop in the menu bar.
- To see logs from a manually-started server: `./zig-out/bin/mlx-serve --model <path> --serve --port 8080 --log-level debug 2>&1`
- Key log patterns:
  - `jinja error: ..., using fallback` — Jinja template failed, check template compatibility
  - `[cache] reusing N/M tokens` — KV cache hit; if N is close to M, most of prompt is cached
  - `[cache] invalidated` — cache was reset (tools config changed, etc.)
  - `<- N+M tokens (Xms) [reason]` — N prompt tokens, M completion tokens, finish reason
  - `tool_msgs=N` — count of `role: "tool"` messages in the request

### Swift app logs
- `print()` in the Swift app goes to stdout, not visible when launched via `open`. To see it: run the binary directly from terminal, or write to a file.
- The app dumps every agent loop request to `~/.mlx-serve/last-agent-request.json` (debug aid). Replay with: `curl -sf http://127.0.0.1:8080/v1/chat/completions -H "Content-Type: application/json" -d @~/.mlx-serve/last-agent-request.json`
- Chat history is persisted at `~/.mlx-serve/chat-history.json`

### Reproducing issues
- To test tool calling without the app: use `curl` with `stream: false` first (simpler to inspect), then `stream: true` (matches app behavior).
- To test the Jinja template offline: `pip3 install jinja2`, then render with Python using the model's `chat_template.jinja` file and the dumped request JSON.
- To test KV cache effects: restart the server fresh between tests (`pkill -f mlx-serve`). A single bad request can poison the cache for all subsequent requests.

## Gotchas

### KV cache poisoning (KNOWN BUG)
When the model generates pad-only output (e.g., from a confusing prompt), `updateCachedPrompt()` still stores the prompt IDs. The KV cache now contains corrupted attention state from the failed generation. ALL subsequent requests that share a prefix with the failed prompt will reuse this corrupted cache and also produce pad-only output, even if they would succeed on a fresh server. **Workaround**: restart the server. **Fix needed**: skip `updateCachedPrompt()` when `completion_tokens` <= pad threshold, or invalidate cache after pad-only generation.

### Gemma 4 tool calling format
Gemma 4 Jinja templates use `tool_responses` (not `role: "tool"`) and `<|tool_call>` / `<|tool_response>` tags (not `<tool_call>`). The template does NOT handle `role: "tool"` — it passes the role through as `<|turn>tool` which the model has never seen, causing immediate EOS. The server transforms `role: "tool"` → `role: "assistant"` for templates that contain "tool_responses".

### Streaming vs non-streaming with tools
When `tools` are present and `stream: true`, the server buffers ALL tokens before checking for tool calls. This means no tokens are streamed until generation is complete. The client must wait for the full response. The buffered path and the non-streaming path share the same KV cache, so a failure in one affects the other.

### Two binaries in the app bundle
The MLX Claw `.app` bundle contains TWO binaries: `MLXClaw` (Swift UI) and `mlx-serve` (Zig server). Both must be updated when making changes. The Swift app starts the Zig server as a child process. Forgetting to copy one binary after a rebuild is a common source of "it still doesn't work."

### DuckDuckGo HTML content noise
The `webSearch` tool uses DuckDuckGo HTML search and extracts text via WKWebView JavaScript. The extracted content often has excessive whitespace (`\n \n \n`) from the HTML structure. Combined with the 2000-char truncation in `buildAgentHistory`, this can produce prompts that confuse small models (especially Gemma 4 E2B/E4B). The `readText()` JS in `BrowserManager` strips some elements but DuckDuckGo's HTML structure defeats most cleanup.

### WKWebView requires main thread
`BrowserManager` is `@MainActor`. All WKWebView operations (navigate, readText, evaluateJS) must happen on the main thread. The WKWebView is created eagerly at app launch so tools work without the Browser window being open.

### Swift JSONSerialization quirks
- `[String: Any]` dictionaries serialize with non-deterministic key order
- Empty string `""` stays as `""` in JSON (not `null`); the server treats both as empty
- `Double` values like `0.7` serialize as `0.69999999999999996` (floating point); this is fine
- `arguments` in tool_calls must be a JSON String (e.g., `"{\"command\":\"ls\"}"`) not a nested dict; the server checks `if (v == .string)` to extract it
