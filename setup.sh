#!/bin/bash
set -euo pipefail

MODEL="large"
DOWNLOAD_MODEL=1

usage() {
  cat <<'EOF'
Usage: setup.sh [--model large|turbo|medium|small] [--no-download]

Creates an isolated Python runtime for the TypeWhisper CrisperWhisper plugin at:
  ~/Library/Application Support/TypeWhisper/CrisperWhisperRuntime
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || { echo "--model requires a value" >&2; exit 2; }
      MODEL="$2"
      shift 2
      ;;
    --no-download)
      DOWNLOAD_MODEL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MODEL" in
  large|turbo|medium|small) ;;
  *) echo "Invalid model: $MODEL" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This runtime installer is intended for macOS." >&2
  exit 1
fi

RUNTIME_DIR="${TYPEWHISPER_RUNTIME_DIR:-$HOME/Library/Application Support/TypeWhisper/CrisperWhisperRuntime}"
VENV_DIR="$RUNTIME_DIR/venv"
CACHE_DIR="$RUNTIME_DIR/cache"
PYTHON="$VENV_DIR/bin/python3"

mkdir -p "$RUNTIME_DIR" "$CACHE_DIR/huggingface" "$CACHE_DIR/torch"

export HF_HOME="$CACHE_DIR/huggingface"
export TORCH_HOME="$CACHE_DIR/torch"
export PYTORCH_ENABLE_MPS_FALLBACK=1
export TOKENIZERS_PARALLELISM=false
export UV_LINK_MODE=copy

if command -v uv >/dev/null 2>&1; then
  echo "Creating isolated Python 3.12 environment with uv…"
  uv venv --clear --python 3.12 "$VENV_DIR"
  uv pip install --python "$PYTHON" --upgrade "crisperwhisper[transformers]==2.0.1"
else
  PYTHON_BOOTSTRAP=""
  for candidate in python3.12 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BOOTSTRAP="$(command -v "$candidate")"
      break
    fi
  done
  if [[ -z "$PYTHON_BOOTSTRAP" ]]; then
    echo "Python 3.10–3.12 or uv is required. Recommended: brew install uv" >&2
    exit 1
  fi
  echo "uv not found; creating an isolated venv with $PYTHON_BOOTSTRAP…"
  rm -rf "$VENV_DIR"
  "$PYTHON_BOOTSTRAP" -m venv "$VENV_DIR"
  "$PYTHON" -m pip install --upgrade pip
  "$PYTHON" -m pip install --upgrade "crisperwhisper[transformers]==2.0.1"
fi

"$PYTHON" - <<'PY'
import importlib.metadata
import platform
import torch

version = importlib.metadata.version("crisperwhisper")
if version != "2.0.1":
    raise SystemExit(f"Expected crisperwhisper 2.0.1, installed {version}")

mps = bool(
    platform.system() == "Darwin"
    and platform.machine() == "arm64"
    and hasattr(torch.backends, "mps")
    and torch.backends.mps.is_available()
)
print(f"Python: {platform.python_version()}")
print(f"CrisperWhisper: {version}")
print(f"PyTorch: {torch.__version__}")
print(f"Apple MPS available: {mps}")
PY

if [[ "$DOWNLOAD_MODEL" -eq 1 ]]; then
  echo "Downloading CrisperWhisper 2.0 $MODEL weights into the private runtime cache…"
  MODEL="$MODEL" "$PYTHON" - <<'PY'
import os
from huggingface_hub import snapshot_download

model = os.environ["MODEL"]
repo_id = f"nyralabs/CrisperWhisper2.0_{model}"
path = snapshot_download(repo_id=repo_id)
print(f"Downloaded {repo_id} to {path}")
PY
fi

touch "$RUNTIME_DIR/runtime-ready"
printf '\nRuntime installed successfully.\nLocation: %s\nLog: %s\n' \
  "$RUNTIME_DIR" "$RUNTIME_DIR/worker.log"
