#!/bin/bash
# 실기 클램쉘 테스트 — 뚜껑을 실제로 닫았을 때 맥이 깨어 있는지 확인한다.
#
# 두 번째 기기가 필요 없다. 뚜껑이 닫힌 동안 2초마다 심장박동을 파일에 적고,
# 열었을 때 끊긴 구간이 있는지 본다. 잠들었다면 그 시간만큼 공백이 남는다.
#
# 사용법:
#   ./Scripts/clamshell-test.sh [닫아둘_초]              본 테스트 (토글 ON, 안 자야 정상)
#   ./Scripts/clamshell-test.sh [닫아둘_초] --control    대조군  (토글 OFF, 자야 정상)
#
# ⚠️ 대조군을 먼저 돌려라. 토글을 꺼도 맥이 안 잔다면(외부 디스플레이 연결,
#    다른 도구가 슬립을 막는 중 등) 본 테스트의 "안 잤다"는 결과는 아무것도
#    증명하지 못한다. 대조군이 성립해야 본 테스트가 의미를 갖는다.
set -euo pipefail

DURATION="${1:-120}"
MODE="${2:-}"
CONTROL=0
[ "$MODE" = "--control" ] && CONTROL=1

STAMP=$(date +%Y%m%d-%H%M%S)
BEAT="/tmp/clamshell-test-$STAMP.tsv"
WINDOW_START=$(date '+%Y-%m-%d %H:%M:%S')

sleep_disabled() { ioreg -r -k SleepDisabled -d 1 | awk -F'= ' '/"SleepDisabled"/{print $2; exit}'; }
lid_closed()     { ioreg -r -k AppleClamshellState -d 1 | awk -F'= ' '/"AppleClamshellState"/{print $2; exit}'; }
power_source()   { pmset -g batt | awk -F"'" '/Now drawing/{print $2; exit}'; }
external_count() { system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Display Type: External" || true; }

if [ "$CONTROL" -eq 1 ]; then
	echo "=== 대조군 테스트 — 토글을 끈 상태에서 '제대로 자는가' ==="
else
	echo "=== 본 테스트 — 토글을 켠 상태에서 '안 자는가' ==="
fi
echo
echo "사전 조건"
printf '  전원          : %s\n' "$(power_source)"
printf '  SleepDisabled : %s\n' "$(sleep_disabled)"
printf '  뚜껑          : %s\n' "$(lid_closed)"
printf '  외부 디스플레이: %s대\n' "$(external_count)"
echo

FAIL=0
if [ "$CONTROL" -eq 1 ]; then
	if [ "$(sleep_disabled)" = "Yes" ]; then
		echo "❌ 대조군은 SleepDisabled 가 꺼져 있어야 합니다."
		echo "   메뉴바 아이콘 > '뚜껑 닫아도 안 자기' 를 먼저 끄세요."
		FAIL=1
	fi
	echo "ℹ️  이 테스트에서는 맥이 **실제로 잠듭니다.** 뚜껑을 열면 깨어납니다."
else
	if [ "$(sleep_disabled)" != "Yes" ]; then
		echo "❌ SleepDisabled 가 켜져 있지 않습니다."
		echo "   메뉴바 아이콘 > '뚜껑 닫아도 안 자기' 를 먼저 켜세요."
		echo "   (이 상태로 돌리면 맥이 진짜로 잠듭니다. 그게 목적이면 --control 을 쓰세요.)"
		FAIL=1
	fi
fi

if [ "$(power_source)" != "AC Power" ]; then
	echo "⚠️  배터리 전원입니다. 전원을 꽂고 하는 것을 권합니다."
fi
if [ "$(external_count)" -gt 0 ]; then
	echo "⚠️  외부 디스플레이가 연결돼 있습니다. 이 상태에서는 원래 안 자므로"
	echo "   두 테스트 모두 의미가 없습니다. 뽑고 다시 하세요."
	FAIL=1
fi
[ "$FAIL" -eq 1 ] && exit 1

# 심장박동 기록. 맥이 자면 이 루프도 멈추므로 파일에 공백이 남는다.
printf 'epoch\ttime\tlid\twifi\n' > "$BEAT"
(
	while :; do
		printf '%s\t%s\t%s\t%s\n' \
			"$(date +%s)" "$(date +%H:%M:%S)" "$(lid_closed)" \
			"$(ifconfig en0 2>/dev/null | awk '/status:/{print $2; exit}')" >> "$BEAT"
		sleep 2
	done
) &
BEAT_PID=$!
trap '{ kill $BEAT_PID; wait $BEAT_PID; } 2>/dev/null || true' EXIT

echo
echo "=== 지금 뚜껑을 닫으세요 ==="
echo "    ${DURATION}초 뒤에 다시 열어주세요. 기록: $BEAT"
echo
remaining="$DURATION"
while [ "$remaining" -gt 0 ]; do
	printf '\r    남은 시간 %3d초 ' "$remaining"
	step=10
	[ "$remaining" -lt 10 ] && step="$remaining"
	sleep "$step"
	remaining=$((remaining - step))
done
printf '\r=== 뚜껑을 열어주세요 ===          \n'

# 뚜껑을 열고 화면이 돌아올 여유.
sleep 15
{ kill $BEAT_PID; wait $BEAT_PID; } 2>/dev/null || true

echo
echo "=== 결과 ==="
TOTAL=$(($(wc -l < "$BEAT") - 1))
GAP=$(awk -F'\t' 'NR>2{d=$1-p; if(d>m){m=d; at=$2}} {p=$1} END{printf "%d %s", m+0, at}' "$BEAT")
MAXGAP=${GAP%% *}
GAPAT=${GAP##* }
CLOSED=$(awk -F'\t' '$3=="Yes"' "$BEAT" | wc -l | tr -d ' ')

printf '  샘플 수          : %s (2초 간격)\n' "$TOTAL"
printf '  닫힘 상태 샘플   : %s개\n' "$CLOSED"
printf '  최대 공백        : %s초 (%s 무렵)\n' "$MAXGAP" "$GAPAT"
printf '  Wi-Fi active 샘플: %s개\n' "$(awk -F'\t' '$4=="active"' "$BEAT" | wc -l | tr -d ' ')"
echo

# 뚜껑이 닫힌 적이 없으면 아무것도 검증하지 못한 것이다.
# 이 경우 어떤 판정을 내놓든 거짓이다.
#
# 주의: 맥이 잠들면 샘플러도 멈추므로 대조군에서는 닫힘 샘플이 1~2개밖에
# 안 잡힐 수 있다. 그것으로 충분하다 — 닫힘을 한 번이라도 관측했으면 된다.
if [ "$CLOSED" -eq 0 ]; then
	echo "  ⚠️  테스트 무효 — 뚜껑이 닫힌 샘플이 하나도 없습니다."
	echo "     뚜껑을 안 닫으셨거나, 닫힘 감지(AppleClamshellState)가 실패했습니다."
	echo "     아무것도 검증되지 않았습니다. 다시 실행하세요."
	exit 2
fi

if [ "$CONTROL" -eq 1 ]; then
	if [ "$MAXGAP" -gt 6 ]; then
		echo "  ✅ 대조군 성립 — 토글을 끄니 ${MAXGAP}초 동안 잠들었습니다."
		echo "     이제 본 테스트의 '안 잤다'가 우리 앱 덕분이라고 말할 수 있습니다."
	else
		echo "  ❌ 대조군 실패 — 토글을 껐는데도 잠들지 않았습니다 (공백 ${MAXGAP}초)."
		echo "     다른 요인이 슬립을 막고 있습니다. 이 상태에서는 본 테스트가"
		echo "     통과해도 우리 앱이 한 일이라고 말할 수 없습니다."
		echo "     'make ax-verify' 의 '슬립 막는 프로세스' 목록을 확인하세요."
	fi
else
	if [ "$MAXGAP" -le 6 ]; then
		echo "  ✅ 뚜껑이 닫힌 ${CLOSED}개 샘플 구간 내내 깨어 있었습니다."
		echo "     (대조군을 아직 안 돌렸다면 --control 로 먼저 확인하세요.)"
	else
		echo "  ❌ ${MAXGAP}초 동안 멈췄습니다 — 잠들었습니다."
	fi
fi

echo
echo "=== 커널이 기록한 슬립/웨이크 (같은 시간대) ==="
# "Sleep/Wakes since boot:N" 같은 누적 카운터 줄은 이벤트가 아니다. 걸러낸다.
EVENTS=$(pmset -g log 2>/dev/null \
	| awk -v start="$WINDOW_START" '$0 >= start' \
	| grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} .*[[:space:]](Sleep|Wake|DarkWake)[[:space:]]' \
	| head -12)
if [ -n "$EVENTS" ]; then
	echo "$EVENTS" | sed 's/^/  /'
else
	echo "  (슬립/웨이크 이벤트 없음)"
fi

echo
echo "  * 원본 기록: $BEAT"
