#!/bin/bash
# 헬퍼를 제거한다. **복원을 확인한 뒤에만** 파일을 지운다.
#
# 순서가 전부다:
#   1) 헬퍼를 먼저 내린다  — 살아 있으면 워치독이 baseline 파일을 다시 쓸 수 있다
#   2) baseline 값으로 되돌리고 **실적용을 폴링으로 확인한다**
#   3) 확인된 뒤에야 baseline·바이너리·plist 를 지운다
#
# 먼저 지우고 나중에 되돌리면, 되돌리기가 실패했을 때 복원 근거도 주체도
# 모두 사라진다. `pmset` 은 비root 에서 실패 메시지를 찍고도 종료코드 0 을
# 내므로(DESIGN.md §1) `set -e` 로도 잡히지 않는다. 반드시 값으로 확인해야 한다.
set -euo pipefail

LABEL="dev.maccontroler.helper"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/dev.maccontroler"
BASELINE="$SUPPORT_DIR/baseline.json"
TIMEOUT=10

[ "$(id -u)" -eq 0 ] || { echo "error: sudo 로 실행하세요" >&2; exit 1; }

kernel_value() { ioreg -r -k SleepDisabled -d 1 | awk -F'= ' '/"SleepDisabled"/{print $2; exit}'; }

echo "제거 전 상태:"
printf '  커널 SleepDisabled : %s\n' "$(kernel_value)"
pmset -g | grep -i sleepdisabled | sed 's/^/  디스크 /' || echo "  디스크 (항목 없음)"

# --- 1) 헬퍼를 먼저 내린다 ---
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	echo "헬퍼 내리는 중..."
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	sleep 1
fi

# --- 2) 되돌리고 확인한다 ---
if [ -f "$BASELINE" ]; then
	# plutil 은 JSON 도 읽는다. python3 의존을 없앤다.
	WANT_BOOL=$(plutil -extract sleepDisabled raw -o - "$BASELINE" 2>/dev/null || echo "")
	case "$WANT_BOOL" in
		true|1)  WANT=1; WANT_TEXT="Yes" ;;
		false|0) WANT=0; WANT_TEXT="No" ;;
		*)
			echo "❌ baseline 을 읽지 못했습니다: $BASELINE" >&2
			echo "   내용을 직접 확인하고 수동으로 복원하세요:" >&2
			echo "     cat '$BASELINE'" >&2
			echo "     sudo pmset disablesleep <0 또는 1>" >&2
			echo "   파일은 그대로 두었습니다." >&2
			exit 1
			;;
	esac

	echo "baseline 발견 → SleepDisabled 를 $WANT 로 되돌립니다"
	pmset disablesleep "$WANT"

	# powerd 경유라 비동기다. 값이 실제로 따라올 때까지 기다린다.
	deadline=$(( $(date +%s) + TIMEOUT ))
	while [ "$(kernel_value)" != "$WANT_TEXT" ]; do
		if [ "$(date +%s)" -ge "$deadline" ]; then
			echo "❌ ${TIMEOUT}초 안에 복원이 확인되지 않았습니다 (현재: $(kernel_value), 기대: $WANT_TEXT)" >&2
			echo "   **아무것도 지우지 않았습니다.** 복원 근거를 남겨둡니다." >&2
			echo "   수동 복구:" >&2
			echo "     sudo pmset disablesleep $WANT" >&2
			echo "     ioreg -r -k SleepDisabled -d 1 | grep SleepDisabled" >&2
			echo "   확인되면 이 스크립트를 다시 실행하세요." >&2
			exit 1
		fi
		sleep 0.5
	done
	echo "  복원 확인됨 ($(kernel_value))"

	# --- 3) 확인된 뒤에만 지운다 ---
	rm -f "$BASELINE"
else
	echo "baseline 없음 — 이 헬퍼가 켠 상태가 아니므로 SleepDisabled 를 건드리지 않습니다"
fi

rm -f "$HELPER_DST" "$PLIST_DST"
rmdir "$SUPPORT_DIR" 2>/dev/null || true

echo
echo "제거 후 상태:"
printf '  커널 SleepDisabled : %s\n' "$(kernel_value)"
pmset -g | grep -i sleepdisabled | sed 's/^/  디스크 /' || true
echo "완료."
