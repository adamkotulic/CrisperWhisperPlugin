#!/bin/bash
set -euo pipefail

PURGE_RUNTIME=0
RESTART_TYPEWHISPER=1

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge-runtime] [--no-restart]

Moves the installed plugin to the Trash. The private Python runtime and model
cache are kept by default so a later reinstall is fast.

Options:
  --purge-runtime  Also move the private runtime and downloaded models to Trash
  --no-restart     Do not restart TypeWhisper
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-runtime)
      PURGE_RUNTIME=1
      shift
      ;;
    --no-restart)
      RESTART_TYPEWHISPER=0
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

PLUGIN_DIR="${TYPEWHISPER_PLUGIN_DIR:-$HOME/Library/Application Support/TypeWhisper/Plugins}"
RUNTIME_DIR="${TYPEWHISPER_RUNTIME_DIR:-$HOME/Library/Application Support/TypeWhisper/CrisperWhisperRuntime}"
TRASH_DIR="${TYPEWHISPER_TRASH_DIR:-$HOME/.Trash}"
STAMP="$(date +%Y%m%d-%H%M%S).$$"
mkdir -p "$TRASH_DIR"

move_to_trash() {
  local source="$1"
  local label="$2"
  if [[ ! -e "$source" ]]; then
    echo "$label is not installed: $source"
    return
  fi
  local destination="$TRASH_DIR/$(basename "$source").$STAMP"
  mv "$source" "$destination"
  echo "$label moved to Trash: $destination"
}

move_to_trash "$PLUGIN_DIR/CrisperWhisperPlugin.bundle" "Plugin"

if [[ "$PURGE_RUNTIME" -eq 1 ]]; then
  move_to_trash "$RUNTIME_DIR" "Runtime and model cache"
else
  echo "Runtime kept: $RUNTIME_DIR"
fi

if [[ "$RESTART_TYPEWHISPER" -eq 1 ]]; then
  if pgrep -x TypeWhisper >/dev/null 2>&1; then
    osascript -e 'tell application id "com.typewhisper.mac" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x TypeWhisper >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  open -b com.typewhisper.mac >/dev/null 2>&1 || true
fi
