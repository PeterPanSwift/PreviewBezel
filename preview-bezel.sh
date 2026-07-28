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
  # swiftc 產出的是 ad-hoc 簽名，Xcode 無法記住 MCP 授權、每次都會重新詢問；
  # 改用鑰匙圈裡的 Apple Development 憑證重簽（可用 PREVIEW_BEZEL_SIGN_ID 覆寫），
  # 簽章身分穩定後只需授權一次。
  SIGN_ID="${PREVIEW_BEZEL_SIGN_ID:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -F'"' '/Apple Development/{print $2; exit}')}"
  if [[ -n "$SIGN_ID" ]]; then
    /usr/bin/codesign --force --sign "$SIGN_ID" --identifier preview-bezel "$BIN" 2>>"$BUILD_DIR/compile.log" || true
  fi
fi

exec "$BIN" "$BEZEL" "$OUT"
