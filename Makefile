# mac-controler — 터미널에서 전부 돌린다. Xcode 를 열 일이 없다.
#
# 헬퍼 관련 타깃(install-helper 등)은 Phase 2 에서 추가된다.

APP_NAME  := MacControler
EXEC_NAME := MacControlerApp
BUNDLE_ID := dev.maccontroler.app
CONFIG    ?= release
APP       := dist/$(APP_NAME).app

HELPER_LABEL := dev.maccontroler.helper

.PHONY: all build app run stop test clean verify logs ax-verify \
        install-helper reinstall-helper uninstall-helper helper-status logs-helper

all: app

build:
	swift build -c $(CONFIG)

app:
	CONFIG=$(CONFIG) ./Scripts/bundle.sh

# 이미 떠 있는 인스턴스를 먼저 죽인다 — 안 그러면 open 이 옛 프로세스를 살려둔 채 끝난다.
run: stop app
	open $(APP)

stop:
	@pkill -x $(EXEC_NAME) 2>/dev/null || true
	@echo "stopped: $(EXEC_NAME)"

test:
	swift test

# 메뉴바 아이템을 접근성 API 로 눌러 메뉴가 실제로 열리는지 본다.
# 노치 아래나 화면 밖에 놓여 눈으로 확인할 수 없을 때도 동작한다.
#   make ax-verify              항목 나열만
#   make ax-verify ITEM=종료     해당 항목까지 눌러본다
# ITEM 없이 부르면 읽기 전용이어야 한다. 그런데 2026-08-06 에 목록만 읽었는데도
# engage 가 걸린 사건이 한 번 있었고(재현 실패), 원인을 특정하지 못했다.
# 그래서 앞뒤 상태를 비교해 바뀌면 크게 알린다 — 조용히 넘어가는 것이 최악이다.
ax-verify:
	@before=$$(ioreg -r -k SleepDisabled -d 1 | awk -F'= ' '/"SleepDisabled"/{print $$2}'); \
	swift Scripts/ax-verify.swift $$(pgrep -x $(EXEC_NAME)) "$(ITEM)"; \
	after=$$(ioreg -r -k SleepDisabled -d 1 | awk -F'= ' '/"SleepDisabled"/{print $$2}'); \
	if [ -z "$(ITEM)" ] && [ "$$before" != "$$after" ]; then \
		echo ""; \
		echo "  ⚠️  읽기만 했는데 SleepDisabled 가 $$before → $$after 로 바뀌었습니다."; \
		echo "     의도치 않은 상태 변경입니다. 헬퍼 로그를 확인하세요: make logs-helper"; \
	fi

clean:
	swift package clean
	rm -rf dist

# 시스템에 실제로 반영된 값을 본다. 앱이 뭐라고 표시하든 이게 진실이다.
verify:
	@ioreg -r -k SleepDisabled -d 1 \
		| grep -E '"(SleepDisabled|AppleClamshellState|AppleClamshellCausesSleep)"' \
		|| echo "(해당 키 없음)"
	@pmset -g | head -2

# zsh 에서 log 는 셸 빌트인이라 'log stream' 이 too many arguments 로 깨진다.
# 반드시 절대경로를 쓸 것.
logs:
	/usr/bin/log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level debug

logs-helper:
	/usr/bin/log stream --predicate 'subsystem == "$(HELPER_LABEL)"' --level debug

# --- root 헬퍼 (sudo 필요) ---

install-helper:
	sudo ./Scripts/install-helper.sh

# plist 나 헬퍼 바이너리가 바뀌면 재등록해야 반영된다.
# 이걸 안 만들어두면 "고쳤는데 왜 옛 동작 그대로냐"로 시간을 크게 잃는다.
reinstall-helper: install-helper

uninstall-helper:
	sudo ./Scripts/uninstall-helper.sh

helper-status:
	@sudo launchctl print system/$(HELPER_LABEL) 2>/dev/null \
		| grep -E '^\s*(state|pid|program) ' \
		|| echo "헬퍼가 등록되어 있지 않습니다 (make install-helper)"
