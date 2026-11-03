#!/bin/bash
# root 헬퍼를 설치하고 launchd 에 올린다. sudo 로 실행해야 한다.
#
# /Library/LaunchDaemons 에 두는 이유는 SDK 헤더가 보증하는 경로이기 때문이다 —
# SMAppService.h: "Legacy LaunchDaemons installed in /Library/LaunchDaemons will
# continue to be bootstrapped without explicit approval in System Settings since
# writing to /Library is protected with filesystem permissions."
# 코드서명이 필요 없고, 이 맥에는 유효한 서명 신원이 0개다. DESIGN.md §3 참조.
set -euo pipefail

LABEL="dev.maccontroler.helper"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

[ "$(id -u)" -eq 0 ] || { echo "error: sudo 로 실행하세요" >&2; exit 1; }

# 빌드는 원래 사용자 권한으로. root 로 빌드하면 .build 소유자가 망가진다.
BUILD_USER="${SUDO_USER:-$(stat -f %Su "$ROOT")}"
sudo -u "$BUILD_USER" swift build -c release --package-path "$ROOT" --product MacControlerHelper

BIN_DIR="$(sudo -u "$BUILD_USER" swift build -c release --package-path "$ROOT" --show-bin-path)"
HELPER_SRC="$BIN_DIR/MacControlerHelper"
[ -x "$HELPER_SRC" ] || { echo "error: 헬퍼 빌드 산출물이 없다: $HELPER_SRC" >&2; exit 1; }

# 이미 떠 있으면 내린다. 안 그러면 실행 중인 바이너리를 덮어쓰게 된다.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	echo "기존 헬퍼 내리는 중..."
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	sleep 1
fi

# install(1) 로 원자적 배치. chmod -R 류는 절대 쓰지 않는다 (iStat Menus LPE 사례).
mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$HELPER_SRC" "$HELPER_DST"
install -o root -g wheel -m 644 "$ROOT/Resources/helper-launchd.plist" "$PLIST_DST"

echo "설치됨:"
ls -l "$HELPER_DST" "$PLIST_DST"

launchctl bootstrap system "$PLIST_DST"
sleep 1

echo
echo "=== launchd 상태 ==="
launchctl print "system/$LABEL" | grep -E '^\s*(state|pid|program|path) ' || true
echo
echo "완료. 로그: make logs-helper"
