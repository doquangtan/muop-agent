#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"
if ! command -v "$FLUTTER_BIN" &>/dev/null; then
  FLUTTER_BIN="flutter"
fi

if [ -x "$SCRIPT_DIR/build/linux/x64/release/bundle/muop_agent" ]; then
  if command -v systemd-run &>/dev/null; then
    exec systemd-run --user "$SCRIPT_DIR/build/linux/x64/release/bundle/muop_agent" "$@"
  else
    exec "$SCRIPT_DIR/build/linux/x64/release/bundle/muop_agent" "$@"
  fi
else
  exec "$FLUTTER_BIN" run -d linux "$@"
fi
