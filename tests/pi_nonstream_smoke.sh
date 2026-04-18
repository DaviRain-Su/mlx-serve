#!/bin/bash
# Non-streaming smoke test: hit /v1/chat/completions directly with a tool-call
# prompt, stream=false, measure round-trip. `pi` itself is streaming-only so
# this complements the streaming agent harness.
#
# Usage: tests/pi_nonstream_smoke.sh [port]

PORT="${1:-8080}"
BASE="http://127.0.0.1:$PORT"

if ! curl -sf "$BASE/health" >/dev/null; then
    echo "FAIL: server not reachable at $BASE"; exit 1
fi

MODEL=$(curl -sf "$BASE/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
echo "model=$MODEL"

# Non-streaming request with a tool — checks that:
#  * server returns finish_reason=tool_calls
#  * arguments parse as JSON
#  * no <tool_call> tag leak into content
REQ=$(python3 -c "
import json
print(json.dumps({
  'model': 'mlx-serve',
  'stream': False,
  'max_tokens': 512,
  'temperature': 0.3,
  'enable_thinking': ${2:-False},
  'messages': [
    {'role':'system','content':'You are a helpful coding assistant. Use tools when useful.'},
    {'role':'user','content':'What directory am I in? Use shell.'}
  ],
  'tools': [{
    'type':'function',
    'function': {
      'name':'shell',
      'description':'Run a shell command and return stdout/stderr.',
      'parameters': {
        'type':'object',
        'properties': {'command': {'type':'string'}},
        'required': ['command']
      }
    }
  }]
}))")

T0=$(python3 -c 'import time; print(time.time())')
RESP=$(curl -sf "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$REQ")
T1=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print(round($T1 - $T0, 2))")

if [ -z "$RESP" ]; then
    echo "FAIL: empty response"
    exit 1
fi

echo "$RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ch = d['choices'][0]
msg = ch['message']
fr = ch.get('finish_reason')
tcs = msg.get('tool_calls') or []
content = (msg.get('content') or '').strip()
reasoning = (msg.get('reasoning_content') or '').strip()
print(f'finish_reason={fr!r}')
print(f'tool_calls={len(tcs)}')
for tc in tcs:
    fn = tc.get('function', {})
    args = fn.get('arguments', '')
    try:
        parsed = json.loads(args) if isinstance(args, str) else args
        print(f'  ok_json name={fn.get(\"name\")} args={parsed}')
    except Exception as e:
        print(f'  BAD_JSON name={fn.get(\"name\")} args={args!r} err={e}')
print(f'content_len={len(content)} reasoning_len={len(reasoning)}')
leak = any(t in content for t in ('<tool_call>','<|channel','</think'))
print(f'tag_leak_in_content={leak}')
usage = d.get('usage', {})
print(f'usage: prompt={usage.get(\"prompt_tokens\")} completion={usage.get(\"completion_tokens\")}')
"
echo "elapsed=${ELAPSED}s"
