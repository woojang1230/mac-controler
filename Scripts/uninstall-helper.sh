#!/bin/bash
# 헬퍼를 제거한다. **반드시 SleepDisabled 를 원복한 뒤에** 파일을 지운다.
#
# 순서가 중요하다. 먼저 지워버리면 되돌릴 주체가 사라지고, 맥이 영영 안 자는
# 상태로 남는다. baseline 파일이 유일한 복원 근거이므로 그것부터 읽는다.
set -euo pipefail

LABEL="dev.maccontroler.helper"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/dev.maccontroler"
BASELINE="$SUPPORT_DIR/baseline.json"

[ "$(id -u)" -eq 0 ] || { echo "error: sudo 로 실행하세요" >&2; exit 1; }

echo "제거 전 상태:"
pmset -g | grep -i sleepdisabled || echo "  (SleepDisabled 항목 없음)"

# 1) 원복이 먼저다.
if [ -f "$BASELINE" ]; then
	WANT=$(/usr/bin/python3 -c "import json,sys; print(1 if json.load(open(sys.argv[1]))['sleepDisabled'] else 0)" "$BASELINE")
	echo "baseline 발견 → SleepDisabled 를 $WANT 로 되돌립니다"
	pmset disablesleep "$WANT"
	rm -f "$BASELINE"
else
	echo "baseline 없음 — 이 헬퍼가 켠 상태가 아니므로 SleepDisabled 를 건드리지 않습니다"
fi

# 2) 그 다음에 내리고 지운다.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	sleep 1
fi

rm -f "$HELPER_DST" "$PLIST_DST"
rmdir "$SUPPORT_DIR" 2>/dev/null || true

echo
echo "제거 후 상태:"
pmset -g | grep -i sleepdisabled || echo "  (SleepDisabled 항목 없음)"
ioreg -r -k SleepDisabled -d 1 | grep '"SleepDisabled"' || true
echo "완료."
