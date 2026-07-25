#!/bin/zsh
# Xcode Custom Behavior：抓 Xcode Preview 截圖 → 套 bezel → 複製到剪貼簿
# 在 Xcode ▸ Settings ▸ Behaviors 新增 behavior，勾選 Run，選這個檔案，並綁定 ⌘P。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SRC="$SCRIPT_DIR/PreviewBezel.swift"
BEZEL="$SCRIPT_DIR/bezel.png"
BUILD_DIR="$SCRIPT_DIR/.build"
BIN="$BUILD_DIR/preview-bezel"
OUT="$BUILD_DIR/last-output.png"

mkdir -p "$BUILD_DIR"

# 原始碼有更新（或還沒編譯過）就重新編譯
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  if ! /usr/bin/xcrun swiftc -O -o "$BIN" "$SRC" 2>"$BUILD_DIR/compile.log"; then
    /usr/bin/osascript -e 'display notification "編譯失敗，詳見 .build/compile.log" with title "Preview Bezel"'
    exit 1
  fi
fi

exec "$BIN" "$BEZEL" "$OUT"
