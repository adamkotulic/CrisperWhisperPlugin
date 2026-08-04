#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${TYPEWHISPER_RUNTIME_DIR:-$HOME/Library/Application Support/TypeWhisper/CrisperWhisperRuntime}"
PYTHON="$RUNTIME/venv/bin/python3"
WORKER="$ROOT/crisper_worker.py"

if [[ ! -x "$PYTHON" ]]; then
  echo "Runtime missing: $PYTHON" >&2
  echo "Run: $ROOT/install.sh --model large" >&2
  exit 1
fi

if [[ ! -f "$WORKER" ]]; then
  echo "Worker missing: $WORKER" >&2
  exit 1
fi

OUTPUT="$(printf '%s\n%s\n' \
  '{"request_id":"health","command":"ping"}' \
  '{"request_id":"stop","command":"shutdown"}' | \
  "$PYTHON" -u "$WORKER")"
RESPONSE="$(printf '%s\n' "$OUTPUT" | sed -n '1p')"

RESPONSE="$RESPONSE" "$PYTHON" - <<'PY'
import json, os
response = json.loads(os.environ["RESPONSE"])
if response.get("status") != "success" or response.get("command") != "pong":
    raise SystemExit(f"Health check failed: {response}")
print("Runtime health check passed")
print(f"Python: {response.get('python')}")
print(f"CrisperWhisper: {response.get('crisperwhisper')}")
print(f"Transformers repair shim: {response.get('transformers_hallucination_shim')}")
print(f"PyTorch: {response.get('torch')}")
print(f"MPS available: {response.get('mps_available')}")
PY
