#!/bin/bash
# SwiftPM 산출물을 dist/MacControler.app 번들로 조립한다.
#
# SwiftPM 은 .app product 를 만들지 못한다(Product 타입은 library/executable/plugin 뿐).
# 그 공백을 메우는 것이 이 스크립트의 전부다 — 디렉터리 두 개, 복사 두 번, 서명 한 번.
# 이것 때문에 .xcodeproj 를 들일 이유는 없다. DESIGN.md §2 참조.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="MacControler"
EXEC_NAME="MacControlerApp"

swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$EXEC_NAME"
[ -x "$BIN" ] || { echo "error: 실행파일이 없다: $BIN" >&2; exit 1; }

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 서명. 이 맥에는 유효한 서명 신원이 0개이고, 개인 전용이므로 이걸로 충분하다.
# Phase 5(배포)로 갈 때만 Developer ID + hardened runtime + 공증으로 교체된다.
codesign --force --sign - "$APP"

echo "built: $APP"
