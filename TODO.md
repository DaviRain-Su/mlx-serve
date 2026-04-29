# TODO

Tracked work outside the main feature set. Lower priority than open issues; promote to GitHub issues when picking up.

## Model architecture support

Architectures whose `model_type` we recognize but don't yet have a working forward pass for. The Swift Model Browser flags these as unsupported but still allows download.

| `model_type` | Family | Examples | Blocked by |
|---|---|---|---|
| `lfm2-vl` | Liquid LFM2.5-VL | LFM2.5-VL-450M | Needs vision encoder integration on top of the existing LFM2 path |
| `phi`, `phi3` | Microsoft Phi | Phi-3, Phi-4 | Different attention/MLP layout and weight names — untested |
| `command-r` | Cohere Command R+ | Command R+ | Different architecture — untested |
| `bert` | BERT (encoder-only) | — | Config parsing exists but no serving endpoint; encoder pathway in `transformer.zig` partially landed |

## Zig 0.16 migration follow-ups

Items deferred from the 2026-04-27/28 migration ([CHANGELOG](CHANGELOG.md)). Migration is complete and all tests pass; these are quality-of-life cleanups.

- **`Conn.writeAll` auto-flushes after every write.** Each call is one syscall, matching the old unbuffered `std.net.Stream.writeAll` exactly. The 16 KB writer buffer in `Conn` therefore goes unused. Optimization: drop the auto-flush, expose only `writeAll` (buffered) + `flush` (boundary), and add explicit `try stream.flush()` at SSE event boundaries (`"\n\n"`) and end-of-response. Should cut SSE syscall count ~3-5×.
- **Network error specificity.** `error.WriteFailed` / `error.ReadFailed` collapse what used to be `error.BrokenPipe` and `error.ConnectionResetByPeer` into one error class. The underlying network error is still on `Conn.write_state.err` / `read_state.err` if needed, but the connection-thread catch handler currently logs the same "client disconnected" for all of them. Could surface `Conn.write_state.err` in the debug log when present.
- **Clock difference.** Migration uses `Io.Clock.awake` (= `CLOCK_UPTIME_RAW` on macOS) for monotonic timing; the old `std.time.Timer` used `CLOCK_MONOTONIC_RAW` (= `Io.Clock.boot` in 0.16). Difference only matters across `pmset sleep` — irrelevant for tps, but if we ever measure long-running benchmarks across suspend, switch to `.boot`.
- **`startStopwatch` wrapper.** One-line wrapper around `Stopwatch.init(io)` in `server.zig:71`. Could be inlined and removed once we touch those call sites again.
- **`Conn.writeAllNoFlush`.** Defined but currently unused. Either delete or convert SSE batches to use it (paired with one explicit `flush()` per event).
- **Vendored deps (mlx-c, libwebp).** Originally on the table for the migration but deferred — still link against Homebrew. Future work: add as git submodules under `lib/` and pre-build to checked-in `.a` files (matches the existing `libjinja.a` pattern). Removes the Homebrew dependency from CI and from end-user dev setups.

## Misc

- Seed reproducibility test in `tests/integration_test.sh` is flaky on small models — MLX random sampling isn't bitwise-deterministic across runs even with a fixed seed. Either tighten the assertion (allow 1-token drift) or skip on small models.
