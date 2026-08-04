#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT/CrisperWhisperPlugin.xcodeproj"
SCHEME="CrisperWhisperPlugin"
MODEL="large"
DOWNLOAD_MODEL=1
INSTALL_RUNTIME=1
RESTART_TYPEWHISPER=1

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Builds and installs the CrisperWhisper plugin and its private runtime.

Options:
  --model large|turbo|medium|small  Model to pre-download (default: large)
  --no-download                    Install runtime without pre-downloading weights
  --repair                         Rebuild/reinstall the plugin; reuse existing runtime
  --skip-runtime                   Same as --repair
  --no-restart                     Do not restart TypeWhisper after installation
  -h, --help                       Show this help

Advanced test override:
  TYPEWHISPER_PLUGIN_DIR=/path/to/plugins ./install.sh --repair --no-restart
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
    --repair|--skip-runtime)
      INSTALL_RUNTIME=0
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

case "$MODEL" in
  large|turbo|medium|small) ;;
  *) echo "Invalid model: $MODEL" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "CrisperWhisperPlugin supports macOS only." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "CrisperWhisperPlugin currently requires an Apple Silicon Mac." >&2
  exit 1
fi

for command in xcodebuild codesign ditto; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required tool is missing: $command" >&2
    exit 1
  fi
done

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "A full Xcode installation is required. Open Xcode once, then retry." >&2
  exit 1
fi

if [[ ! -d "$PROJECT" ]]; then
  echo "Xcode project missing: $PROJECT" >&2
  exit 1
fi

if [[ "$INSTALL_RUNTIME" -eq 1 ]]; then
  SETUP_ARGS=(--model "$MODEL")
  if [[ "$DOWNLOAD_MODEL" -eq 0 ]]; then
    SETUP_ARGS+=(--no-download)
  fi
  "$ROOT/setup.sh" "${SETUP_ARGS[@]}"
else
  "$ROOT/verify_runtime.sh"
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/crisperwhisper-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

DERIVED_DATA="$BUILD_ROOT/DerivedData"
BUILD_LOG="$BUILD_ROOT/xcodebuild.log"

echo "Building the Release plugin bundle..."
if ! xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$BUILD_LOG" 2>&1; then
  echo "Xcode build failed. Last log lines:" >&2
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi

BUILT_BUNDLE="$DERIVED_DATA/Build/Products/Release/CrisperWhisperPlugin.bundle"
if [[ ! -d "$BUILT_BUNDLE" ]]; then
  echo "Build succeeded but the plugin bundle was not found: $BUILT_BUNDLE" >&2
  exit 1
fi

STAGED_BUNDLE="$BUILD_ROOT/CrisperWhisperPlugin.bundle"
ditto "$BUILT_BUNDLE" "$STAGED_BUNDLE"
codesign --force --sign - --timestamp=none "$STAGED_BUNDLE"
codesign --verify --strict "$STAGED_BUNDLE"

PLUGIN_DIR="${TYPEWHISPER_PLUGIN_DIR:-$HOME/Library/Application Support/TypeWhisper/Plugins}"
DESTINATION="$PLUGIN_DIR/CrisperWhisperPlugin.bundle"
mkdir -p "$PLUGIN_DIR"

if [[ -e "$DESTINATION" ]]; then
  BACKUP_DIR="$PLUGIN_DIR/Backups"
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/CrisperWhisperPlugin.bundle.$(date +%Y%m%d-%H%M%S).$$"
  mv "$DESTINATION" "$BACKUP"
  echo "Previous plugin moved to: $BACKUP"
fi

ditto "$STAGED_BUNDLE" "$DESTINATION"
codesign --verify --strict "$DESTINATION"

echo "Plugin installed: $DESTINATION"

if [[ "$RESTART_TYPEWHISPER" -eq 1 ]]; then
  if pgrep -x TypeWhisper >/dev/null 2>&1; then
    osascript -e 'tell application id "com.typewhisper.mac" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x TypeWhisper >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  if ! open -b com.typewhisper.mac >/dev/null 2>&1; then
    echo "TypeWhisper was not opened automatically. Start it normally to load the plugin."
  fi
fi

printf '\nInstallation complete.\nEngine: CrisperWhisper 2.0\nLanguage: Auto is supported\n'
if [[ "$INSTALL_RUNTIME" -eq 0 ]]; then
  echo "Runtime: reused existing installation"
elif [[ "$DOWNLOAD_MODEL" -eq 0 ]]; then
  echo "Model download: deferred until first use"
else
  echo "Pre-downloaded model: $MODEL"
fi
