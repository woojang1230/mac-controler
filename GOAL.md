# GOAL — mac-controler Phase 0 → 2 완주

> **상태 (2026-08-06): Phase 0·1 완료, Phase 2 실기 검증 완료.**
> 남은 것은 물리 조작이 필요한 3건뿐 — 재부팅 고아 복구, 배터리 경고 다이얼로그,
> 외부 디스플레이 무개입. 셋 다 로직은 `HelperCoreTests`/`ClamshellCoreTests` 로 검증됨.
> 검증 결과와 실기에서 나온 버그 셋은 `DESIGN.md` §7-1, §7-2 참조.

## 미션

맥북 메뉴바에서 클램쉘 모드(뚜껑 닫아도 안 자기)를 확인하고 켜고 끌 수 있는 앱을,
**안전하게 되돌릴 수 있는 상태로** Phase 2까지 완성한다.

설계는 `DESIGN.md`에 확정되어 있다. 설계를 다시 논의하지 말고 실행하라.
설계와 현실이 충돌하면 현실을 따르고, `DESIGN.md`를 고친 뒤 계속 진행하라.

## 실행 원칙

- **질문하지 말고 진행한다.** 예외는 아래 "질문해야 하는 경우"뿐이다.
- 판단이 필요하면 `DESIGN.md`의 근거를 따르고, 없으면 결정하고 그 근거를 기록한다.
- 각 Phase의 완료 조건을 **실제로 실행해서 확인**한 뒤에만 다음으로 넘어간다.
  통과했다고 주장하기 전에 명령을 돌리고 출력을 본다.
- 막히면 우회하지 말고 `DESIGN.md` §8(미확인 사항)의 폴백을 쓴다.

## 질문해야 하는 경우 (이때만 멈춘다)

1. 시스템을 되돌리기 어렵게 바꾸는 작업이 필요할 때
2. 안전장치를 빼거나 약화시켜야 진도가 나갈 때
3. `DESIGN.md`의 확정 결정(개인 전용 / 슬립 제어만 / 배터리 경고 후 허용)을 바꿔야 할 때
4. 유료 결제나 계정 가입이 필요해질 때
5. 검증 없이 넘어가야만 진도가 나갈 때

## 확정 전제 (재논의 금지)

| 항목 | 값 |
|---|---|
| 배포 범위 | 이 맥에서만. Phase 5 미착수 |
| 스코프 | 슬립 제어만 (클램쉘 / 유휴 / 디스플레이 / 차단 프로세스 목록) |
| 배터리 정책 | 경고 후 허용, 15% 자동 해제, 4시간 절대 타임아웃 |
| 스택 | Swift 6.3 `.v6` / SwiftUI `MenuBarExtra(.menu)` / SwiftPM + Makefile / `.xcodeproj` 없음 |
| 권한 | root LaunchDaemon 수동 설치 + XPC. 샌드박스 OFF |
| 번들 ID | `dev.maccontroler.app` / `dev.maccontroler.helper` |

**클램쉘은 root 없이 불가능하다.** `caffeinate` / 공개 `IOPMAssertion` 으로 우회하려는
시도가 떠오르면 `DESIGN.md` §1의 표를 다시 읽어라. 전부 닫힌 경로다.

## 절대 규칙

1. **baseline을 존중한다.** engage 전 현재 `SleepDisabled` 를 읽어 저장하고,
   release 시 **그 값으로만** 복원한다. 무조건 0으로 덮지 않는다.
2. **SPI는 한 파일에.** `ClamshellCore/IOKitSPI.swift` 외에는 SPI를 선언하지 않고,
   `SleepBlocker.swift` 외에는 호출하지 않는다.
3. **`IOReturn == success` 를 믿지 않는다.** powerd 경유라 비동기다.
   항상 `ioreg` 로 실적용을 폴링 확인한다.
4. **`/usr/bin/log` 절대경로.** zsh에서 `log` 는 빌트인이라 깨진다.
5. **`chmod -R 777` 류 금지.** `install(1)` 로 원자적 배치.
6. 순수 로직(`ClamshellCore`)은 TDD로 간다. 테스트 먼저.

## Phase 0 — 껍데기 (반나절)

산출물: `Package.swift`, `Makefile`, `Scripts/bundle.sh`, `Resources/App-Info.plist`,
`MacControlerApp.swift` + `MenuBarScene.swift` + `StatusMenuView.swift`

완료 조건 — 전부 실행해서 확인할 것:
- [ ] `make run` → 메뉴바 우측에 아이콘이 보인다
- [ ] 클릭하면 네이티브 메뉴가 펼쳐진다
- [ ] "종료"로 종료된다
- [ ] **Dock에 아이콘이 없다**
- [ ] ⌘Tab 전환기에도 없다

## Phase 1 — 읽기 전용 상태판 (1~2일) · 시스템 미변경

산출물: `ClamshellCore` 전체(`PowerSnapshot`, `PowerStateReading`, `IOKitPowerStateReader`,
`ClamshellPolicy`), `AppModel`(@Observable), `NoopSleepController`, `Tests/ClamshellCoreTests`

표시 항목 (전부 root 불필요):
뚜껑 상태 / `SleepDisabled` 실적용값 / `AppleClamshellCausesSleep` /
전원소스+배터리% / 외부 디스플레이 수 / **누가 슬립을 막고 있나**(`IOPMCopyAssertionsByProcess`)

한 줄 판정: `isAwakeOnLidClose = !clamshellCausesSleep || sleepDisabled`

완료 조건:
- [ ] 위 6개 값이 메뉴에 표시된다
- [ ] 어댑터를 뽑았다 꽂으면 **폴링 없이** 즉시 갱신된다
- [ ] `swift test` 통과 — `isAwakeOnLidClose` 4가지 조합 + baseline이 Yes인 케이스
- [ ] **★게이트: 값이 실제로 갱신되어 보이는가?**
      안 보이면(포럼 720625 버그 재현) 즉시 NSStatusItem+NSMenu로 전환.
      콘텐츠 뷰는 NSHostingView로 재사용, 40~80줄. 우회하거나 넘어가지 말 것.

## Phase 2 — root 헬퍼 + 토글 + 안전장치 (3~4일)

> **원래 P3이던 워치독·고아복구를 여기로 끌어올렸다.**
> 이것들 없이 토글만 내보내면 앱 크래시 시 맥이 영영 안 잔다 (치명 리스크 #1).
> 안전장치를 빼고 P2를 "완료"라고 부르지 말 것.

산출물: `HelperProtocol`, `MacControlerHelper`(main / HelperService / SleepBlocker /
`Watchdog` / `BaselineStore`), `helper-launchd.plist`, install·uninstall 스크립트,
`XPCSleepController`, `ManualDaemonInstaller`, `ClamshellPolicy.decide`

완료 조건:
- [ ] `sudo make install-helper` 1회 후 재부팅 없이 헬퍼 기동
      (`sudo launchctl print system/dev.maccontroler.helper`)
- [ ] 토글 ON → `make verify` 가 `SleepDisabled = Yes`. OFF → **baseline 값으로** 복귀
- [ ] 토글 시 **비밀번호 프롬프트가 뜨지 않는다**
- [ ] `/usr/bin/log stream` 에 헬퍼 로그가 찍힌다
- [ ] **토글 ON 상태에서 `kill -9 <앱PID>` → 90초 이내 자동 원복**
- [ ] **토글 ON 상태로 재부팅 → BootSessionUUID 불일치 감지해 부팅 직후 자동 원복**
- [ ] 배터리 전원에서 ON 시도 → 경고 다이얼로그. 15% 미만 → 자동 해제
- [ ] 외부 디스플레이 연결 상태에서 ON → "이미 안 잠" 표시, **값을 건드리지 않음**
- [ ] `make uninstall-helper` → 원복 후 제거. `pmset -g` 가 baseline 값

### 첫 30분 체크포인트

`XPCListener(service:)` 가 launchd `MachServices` 에 바인딩되지 않으면
**즉시** `NSXPCListener(machServiceName:)` 로 전환한다(~1시간).
Stats / Lidless / AlDente 가 실제로 쓰는 검증된 경로다. 여기서 오래 붙잡히지 말 것.

### 알려진 제약 (수용하고 진행)

서명 신원이 0개라 XPC 피어의 암호학적 검증이 원리적으로 불가능하다.
완화책으로 엔드포인트를 `setSleepDisabled` / `heartbeat` / `status` 3개로 제한하고,
정책 판단은 전부 비특권 앱 쪽에 두며, 헬퍼는 "값 하나 설정"만 한다.
**이 맥 외부로 배포하지 않음이 전제다.**

## 완료 보고

Phase 2 완료 시 다음을 보고한다:
1. 각 완료 조건의 **실제 명령 출력** (주장이 아니라 증거)
2. `DESIGN.md` §8 미확인 사항 중 이번에 해소된 것 / 여전히 미확인인 것
3. 설계와 달랐던 점과 그래서 무엇을 고쳤는지
4. Phase 3~4에 남긴 것
