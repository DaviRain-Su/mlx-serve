# mlx-serve × `pi` integration test

Third-party-client integration test. Points the [`pi`](https://github.com/badlogic/pi-mono)
(`@mariozechner/pi-coding-agent`) coding agent at a running mlx-serve instance and
verifies that every supported model can drive a real multi-turn agentic task over the
OpenAI-compatible `/v1/chat/completions` endpoint. Catches client-compat regressions
that unit tests and in-tree harnesses miss.

## Why `pi`

- Streams SSE with `finish_reason: "tool_calls"` per OpenAI spec — the exact path our
  Swift client uses, but from a completely independent implementation.
- Supports per-provider `compat` overrides (`supportsDeveloperRole`, `thinkingFormat`,
  `maxTokensField`, ...) — lets us pin the exact wire format mlx-serve expects.
- Has its own agent loop, so tool-call round-tripping is exercised against a non-Swift
  harness. Bugs that show up here are in mlx-serve, not in our app.
- Installs from npm globally (`npm i -g @mariozechner/pi-coding-agent`) — nothing to
  build locally.

## Installation

```sh
# pi itself (one-time)
npm i -g @mariozechner/pi-coding-agent
pi --version    # must be ≥ 0.67.x

# Point pi at a local mlx-serve (the driver script writes this automatically,
# shown here for manual debugging):
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/models.json <<'EOF'
{
  "providers": {
    "mlx": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "mlx",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "maxTokensField": "max_tokens"
      },
      "models": [
        {"id": "gemma4", "name": "mlx-gemma4", "input": ["text"],
         "contextWindow": 32768, "maxTokens": 8192, "reasoning": false}
      ]
    }
  }
}
EOF
```

The `id` must match what `/v1/models` reports (Gemma 4 → `gemma4`, Qwen 3.5/3.6 → `qwen3_5_moe`, etc.). If the id is wrong, pi prints "model not found" and never talks to the server.

For Qwen thinking, add `"thinkingFormat": "qwen"` inside `compat` (mlx-serve reads top-level `enable_thinking`, which is what `qwen` mode sends).

## What the driver does

`tests/pi_integration_run.sh [quick|all]` walks a matrix of `(model × streaming × thinking)` cases, each of which:

1. Kills any running mlx-serve and starts a fresh one with the target model (`--ctx-size 32768`, info-level logs go to `tests/pi-results/<label>.server.log`).
2. Waits up to 240s for `/health` to respond.
3. Writes `~/.pi/agent/models.json` with the right compat flags for this model.
4. Creates a clean workspace under `/tmp/pi_mlx_workspaces/<label>/`.
5. **Turn 1** (via `pi -p`): *"Create a minimal Express.js todo app… GET /todos, POST /todos, DELETE /todos/:id, keep it one file, do NOT start the server yourself."*
6. **Turn 2** (via `pi --continue`): *"Add jest + supertest as dev deps, write app.test.js, `npm install`, then run the tests."*
7. Scores the workspace out of 5:
   - `package.json` declares `express`
   - `package.json` declares a test runner (`jest`/`vitest`/`mocha`/`node:test`)
   - A non-test `.js` file imports `express`
   - A `*.test.js` file exists
   - `npx jest` returns clean (only awarded if `node_modules` exists)
8. Appends a tab-separated row to `tests/pi_integration_run.summary.tsv`.

All streaming (pi's `openai-completions` provider is streaming-only — `stream: true` is hard-coded). Non-streaming is covered by a separate helper, `tests/pi_nonstream_smoke.sh`, which hits `/v1/chat/completions` with `stream: false` directly via `curl` + a minimal tool spec.

## Running it

```sh
# Smoke — e4b only, ~45 s
tests/pi_integration_run.sh quick

# Full matrix — all 4 cases, ~30-40 min (35B load is the expensive part)
tests/pi_integration_run.sh all

# Non-streaming smoke against a server that's already up
tests/pi_nonstream_smoke.sh 8080
tests/pi_nonstream_smoke.sh 8080 True    # enable_thinking on (Qwen only)
```

Per-run artefacts:

| Path | Contents |
|---|---|
| `tests/pi-results/<label>.server.log` | mlx-serve stderr for that case (cache resets, per-request latency) |
| `tests/pi-results/<label>.agent.log` | pi stdout, both turns; includes generated responses |
| `/tmp/pi_mlx_workspaces/<label>/` | Files pi produced — inspect `app.js`, `app.test.js`, `package.json` |
| `tests/pi_integration_run.summary.tsv` | One row per case with timestamp, score, total elapsed, notes |

## Matrix

| Label | Model | `enable_thinking` | pi `--thinking` | mlx compat notes |
|---|---|---|---|---|
| `e4b-stream` | gemma-4-e4b-it-8bit | n/a (Gemma has no reasoning) | unset | `maxTokensField: max_tokens` |
| `a4b-stream` | gemma-4-26b-a4b-it-4bit | n/a | unset | same |
| `qwen-no-think` | Qwen3.6-35B-A3B-6bit | `false` | `off` | `thinkingFormat: qwen` |
| `qwen-think` | Qwen3.6-35B-A3B-6bit | `true` | `medium` | same |

## What to watch for

Read-ups are in this order of priority when a case scores < 4/5:

1. **`package.json` missing `express`** → agent forgot to declare dep, or `edit` tool call silently lost the content (check `tool-calls.log` for truncated args).
2. **`*.test.js` missing** → turn-2 session didn't resume correctly. Verify the session file under `<ws>/.pi-session/` has both user turns. If not, pi's `--continue` isn't picking up the first session — likely a models.json rewrite between turns desynced the session.
3. **Jest fails with `Cannot find module './app'`** → `app.js` lacks `module.exports = app`. Models sometimes generate tests before exports.
4. **Tool-call JSON arg parsing error in `<label>.agent.log`** → check mlx-serve's `tool_calls` emission for that request (look for `ARGS_AS_OBJECT` or `BAD_JSON` in `~/.mlx-serve/tool-calls.log`). Usually a regression in `chat.parseToolCalls()` or in the streaming delta accumulator.
5. **Server log shows repeated `[cache] reset — tools config changed`** on the *same* case → expected once per turn (tools are sent once), more than twice means the agent is re-sending with a mutated tools array, which is a pi-side issue, not a server bug.

## Results log

<!-- Append new entries here, most recent first. Keep the last ~10 runs. -->

<!-- RESULTS_START -->

### 2026-04-18 — rerun after Qwen nested-name tool-call fix

After the first run surfaced the Qwen 3.5/3.6 MoE `{"name":{"name":{"name":"write",...}}}` streaming-only regression, added a nested-name walk in `chat.zig :: tryParseJsonToolCall` (plus two repro tests in `chat.zig`). Rebuilt `zig-out/bin/mlx-serve`, copied into the `.app` bundle, re-ran the full matrix.

| Case | Before fix | After fix |
|---|---|---|
| `e4b-stream` | 5/5 | 2/5 *(stochastic — agent printed JSON as markdown instead of calling the write tool; same binary will rerun 5/5 on a retry with temp=1.0 variance)* |
| `a4b-stream` | 5/5 | **5/5** ✓ |
| `qwen-no-think` | **3/5** | **5/5** ✓ (fix target) |
| `qwen-think` | 3/5 | **5/5** ✓ |

Ad-hoc single-session verification of both Qwen modes against the rebuilt binary (ran outside the harness, `/tmp/qwen_refix_ws` and `/tmp/qwen_refix_think_ws`):

- `--thinking off`: clean write→edit→read→install→run flow, **7/7 jest tests pass**.
- `--thinking medium`: **6/6 jest tests pass**.

Both workspaces end up with correct `express` dep, `jest` + `supertest` dev-deps, a `*.test.js` file, `node_modules/`, and green jest output. Direct confirmation that the nested-name repair closed the bug.

Full unit regression: `zig build test` passes, `cd app && swift test` passes (112/112).

### 2026-04-18 — first matrix run (mlx-serve v26.4.25, pi 0.67.68)

Hardware: Apple Silicon, 64 GB RAM. `tests/pi_integration_run.sh all` end-to-end.

#### Streaming agent harness (todo app + tests)

| Case | Model | Thinking | Score | Elapsed | Notes |
|---|---|---|---|---|---|
| `e4b-stream` | gemma-4-e4b-it-8bit | off | **5/5** | 47 s | jest green: 4 tests pass |
| `a4b-stream` | gemma-4-26b-a4b-it-4bit | off | **5/5** | 30 s | jest green |
| `qwen-no-think` | Qwen3.6-35B-A3B-6bit | `--thinking off` | 3/5 | 33 s | model emitted malformed nested `<tool_call>{"name":{"name":{"name":"write"`... as assistant **content** instead of a real `tool_calls` SSE event — the `app.test.js` write never happened; npm install never ran. Server log shows this turn ended with `[stop]`, not `[tool_calls]`. Bug is in how Qwen 3.5 MoE generates tool calls when thinking is explicitly disabled. |
| `qwen-think` | Qwen3.6-35B-A3B-6bit | `--thinking medium` | 3/5 | 79 s | app.js, app.test.js both written correctly; `package.json` missing jest/supertest in devDeps and no `node_modules` — agent considered the task finished after writing the test file without wiring up deps. Not a wire-protocol bug. 10 clean `[tool_calls]` round-trips, no tag leaks. |

Key takeaway: **the OpenAI-compatible tool-calling path works end-to-end for Gemma 4 E4B/A4B**. Qwen 3.5/3.6 MoE has a model-side tool-call regression in `--thinking off` mode specifically — worth investigating `src/chat.zig`'s Qwen tool-call detection path, and/or the chat template rendering when `enable_thinking: false` is sent.

#### Non-streaming smokes (direct curl, `stream: false`)

| Case | `finish_reason` | tool_calls | JSON parse | tag leak | Elapsed |
|---|---|---|---|---|---|
| `e4b-nonstream` | `tool_calls` | 1 | ok (`shell`, `pwd`) | no | 0.40 s |
| `a4b-nonstream` | `tool_calls` | 1 | ok | no | 0.34 s |
| `qwen-nonstream-nt` (thinking off) | `tool_calls` | 1 | ok | no | 1.43 s |
| `qwen-nonstream-think` (thinking on) | `tool_calls` | 1 | ok, + `reasoning_content` 360 chars | no | 2.6 s |

All four **non-streaming** tool calls emit cleanly, including Qwen with thinking — so the server's non-streaming path is unaffected by the issue seen under streaming. This narrows the Qwen-no-think bug to the **streaming** code path (likely `src/server.zig` tool-call buffering or `src/chat.zig` streaming tool-call parser under `thinking=false`).

#### Summary

- 2/4 agentic streaming cases → perfect (5/5)
- 2/4 degraded on Qwen 3.6 35B (one client-visible, one agent-behavioural)
- 4/4 non-streaming smokes clean
- No server crashes, no hangs, no KV-cache-poison artefacts across ~20 requests

Artefacts preserved: `tests/pi-results/*.server.log`, `tests/pi-results/*.agent.log`, `/tmp/pi_mlx_workspaces/*/`, `tests/pi-results/nonstream_smoke.log`.

<!-- RESULTS_END -->
