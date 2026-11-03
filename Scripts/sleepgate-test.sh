#!/bin/bash
# 커널 슬립 게이트 시험 — SleepDisabled 가 켜져 있을 때 슬립 요청이 실제로 막히는가.
#
# 뚜껑을 닫는 것은 소프트웨어로 흉내낼 수 없다
# (`IOPMTestClamshellClose` 는 XNU 의 DEBUG/DEVELOPMENT 커널 전용).
# 대신 **같은 게이트를 지나는 다른 경로**를 시험한다:
#
#   뚜껑 닫힘   → privateSleepSystem(kIOPMSleepReasonClamshell) ┐
#   pmset sleepnow → privateSleepSystem(kIOPMSleepReasonSoftware) ┤→ checkSystemSleepAllowed()
#                                                                  └→ userDisabledAllSleep 검사
#
# 즉 이 테스트는 뚜껑 닫힘의 **대리 지표**다. 완전한 대체는 아니며,
# 실제 뚜껑 닫힘 검증은 Scripts/clamshell-test.sh 로 따로 해야 한다.
#
# 실패해도 안전하다 — 맥이 잠들 뿐이고 키를 누르면 깨어난다.
set -euo pipefail

sleep_disabled() { ioreg -r -k SleepDisabled -d 1 | awk -F'= ' '/"SleepDisabled"/{print $2; exit}'; }

echo "=== 사전 조건 ==="
printf '  전원          : %s\n' "$(pmset -g batt | awk -F"'" '/Now drawing/{print $2}')"
printf '  SleepDisabled : %s\n' "$(sleep_disabled)"

if [ "$(sleep_disabled)" != "Yes" ]; then
	echo
	echo "❌ SleepDisabled 가 꺼져 있습니다. 이 상태로 실행하면 맥이 진짜로 잠듭니다."
	echo "   메뉴바에서 '뚜껑 닫아도 안 자기' 를 먼저 켜세요."
	exit 1
fi

BEAT="/tmp/sleepgate-$(date +%Y%m%d-%H%M%S).tsv"
WINDOW_START=$(date '+%Y-%m-%d %H:%M:%S')

# 맥이 잠들면 이 루프도 멈춘다. 공백이 곧 증거다.
( while :; do date +%s >> "$BEAT"; sleep 1; done ) &
BEAT_PID=$!
trap 'kill $BEAT_PID 2>/dev/null || true' EXIT
sleep 3

echo
echo "=== 슬립 요청 (pmset sleepnow) ==="
pmset sleepnow || echo "  (명령 자체가 거부됨)"

echo "  25초 관찰..."
sleep 25
kill $BEAT_PID 2>/dev/null || true

MAXGAP=$(awk 'NR>1{d=$1-p; if(d>m)m=d} {p=$1} END{print m+0}' "$BEAT")

echo
echo "=== 결과 ==="
printf '  샘플 수   : %s (1초 간격)\n' "$(wc -l < "$BEAT" | tr -d ' ')"
printf '  최대 공백 : %s초\n' "$MAXGAP"
printf '  SleepDisabled(사후): %s\n' "$(sleep_disabled)"
echo

if [ "$MAXGAP" -le 3 ]; then
	echo "  ✅ 슬립 요청을 보냈는데도 멈추지 않았습니다 — 커널 게이트가 막았습니다."
else
	echo "  ❌ ${MAXGAP}초 멈췄습니다 — 잠들었습니다. SleepDisabled 가 슬립을 막지 못합니다."
fi

echo
echo "=== 커널 슬립 기록 (같은 시간대) ==="
pmset -g log 2>/dev/null | awk -v s="$WINDOW_START" '$0 >= s' \
	| grep -E '\b(Sleep|Wake|DarkWake|Failure)\b' | head -10 \
	|| echo "  (슬립 이벤트 없음 — 요청이 게이트에서 막혔다는 뜻)"

echo
echo "  * 이것은 뚜껑 닫힘의 대리 지표다. 실제 뚜껑 검증은 clamshell-test.sh."
echo "  * 기록: $BEAT"
