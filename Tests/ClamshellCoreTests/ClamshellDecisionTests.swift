import Foundation
import Testing

@testable import ClamshellCore

@Suite("개입 판단")
struct ClamshellDecisionTests {

    let settings = PolicySettings()  // 임계 15%, 최대 4시간

    @Test("전원 어댑터면 바로 켠다")
    func acEngagesDirectly() {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: true, sleepDisabled: false, powerSource: .ac)
        #expect(ClamshellPolicy.decide(snapshot, settings: settings) == .engage)
    }

    @Test("배터리 전원이면 확인을 받는다 — 금지가 아니라 경고 후 허용")
    func batteryNeedsConfirmation() {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: true, sleepDisabled: false,
            powerSource: .battery, batteryPercent: 80)
        guard case .needsConfirmation = ClamshellPolicy.decide(snapshot, settings: settings) else {
            Issue.record("배터리에서는 확인 다이얼로그를 거쳐야 한다")
            return
        }
    }

    @Test("배터리 잔량이 임계 미만이면 거부한다")
    func lowBatteryRefused() {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: true, sleepDisabled: false,
            powerSource: .battery, batteryPercent: 14)
        guard case .refused = ClamshellPolicy.decide(snapshot, settings: settings) else {
            Issue.record("15% 미만에서는 거부해야 한다")
            return
        }
    }

    @Test("외부 디스플레이가 있으면 불필요")
    func externalDisplayUnnecessary() {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: false, sleepDisabled: false, externalDisplayCount: 1)
        guard case .unnecessary = ClamshellPolicy.decide(snapshot, settings: settings) else {
            Issue.record("이미 안 자는 조건이면 건드리지 않는다")
            return
        }
    }

    @Test("다른 주체가 이미 SleepDisabled 를 켜뒀으면 불필요")
    func foreignSleepDisabledUnnecessary() {
        let snapshot = PowerSnapshot.fake(clamshellCausesSleep: true, sleepDisabled: true)
        guard case .unnecessary = ClamshellPolicy.decide(snapshot, settings: settings) else {
            Issue.record("남이 켠 설정 위에 덧씌우지 않는다")
            return
        }
    }

    @Test("★ AppleClamshellCausesSleep 이 false 라는 이유만으로는 거부하지 않는다")
    func causesSleepFalseAloneDoesNotRefuse() {
        // 이 값은 믿을 수 없다. 2026-08-06 실측: 뚜껑을 닫았을 때 실제로는
        // Deep Idle 로 들어갔는데(pmset -g log 의 "Wake from Deep Idle ...
        // DriverReason:lid") 그 뒤 이 값이 계속 No 로 남았다.
        //
        // 이것만 보고 거부하면 사용자가 정말로 필요할 때 토글이 먹지 않는다.
        // 잘못 켜는 비용(되돌릴 수 있고 워치독이 지킨다)보다
        // 잘못 거부하는 비용(요청했는데 맥이 잔다)이 훨씬 크다.
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: false,
            sleepDisabled: false,
            externalDisplayCount: 0
        )
        #expect(ClamshellPolicy.decide(snapshot, settings: settings) == .engage)
    }

    @Test("외부 디스플레이는 확실한 근거이므로 계속 거부한다")
    func externalDisplayStillRefuses() {
        // 이쪽은 커널 소스가 보증한다 — 외부 디스플레이가 붙으면 그래픽스가
        // clamshellDisabled 를 세워 클램쉘 슬립 자체를 끈다.
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: false, sleepDisabled: false, externalDisplayCount: 1)
        guard case .unnecessary = ClamshellPolicy.decide(snapshot, settings: settings) else {
            Issue.record("외부 디스플레이는 근거가 확실하다")
            return
        }
    }
}

@Suite("자동 해제")
struct AutoReleaseTests {

    let settings = PolicySettings()
    let engagedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test("배터리 임계 아래로 떨어지면 자동 해제한다")
    func releasesOnLowBattery() {
        let snapshot = PowerSnapshot.fake(powerSource: .battery, batteryPercent: 14)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt, now: engagedAt.addingTimeInterval(60),
            settings: settings)
        #expect(reason == .lowBattery)
    }

    @Test("설정한 시간 상한을 넘기면 자동 해제한다")
    func releasesOnTimeout() throws {
        guard case .after(let seconds) = settings.autoRelease else {
            Issue.record("기본 설정에는 시간 상한이 있어야 한다")
            return
        }
        let snapshot = PowerSnapshot.fake(powerSource: .ac, batteryPercent: 100)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt,
            now: engagedAt.addingTimeInterval(seconds + 1),
            settings: settings)
        #expect(reason == .timeout)
    }

    /// 사용자가 설정 창에서 '꺼짐' 을 고른 경우.
    @Test("★ 시간 상한이 '꺼짐' 이면 시간으로는 해제하지 않는다")
    func neverLimitNeverTimesOut() {
        let settings = PolicySettings(autoRelease: .never)
        let snapshot = PowerSnapshot.fake(powerSource: .ac, batteryPercent: 100)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt,
            now: engagedAt.addingTimeInterval(365 * 24 * 3600),
            settings: settings)
        #expect(reason == nil)
    }

    /// '꺼짐' 은 **시간 상한만** 끄는 것이다. 배터리 규칙은 그대로 산다.
    /// 이 구분이 흐려지면 사용자가 방전으로 데이터를 잃는다.
    @Test("★ 시간 상한이 '꺼짐' 이어도 배터리 임계는 그대로 작동한다")
    func neverLimitStillReleasesOnLowBattery() {
        let settings = PolicySettings(autoRelease: .never)
        let snapshot = PowerSnapshot.fake(powerSource: .battery, batteryPercent: 14)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt,
            now: engagedAt.addingTimeInterval(60),
            settings: settings)
        #expect(reason == .lowBattery)
    }

    @Test("짧게 고른 상한도 그대로 지켜진다")
    func shortLimitIsRespected() {
        let settings = PolicySettings(autoRelease: .after(seconds: 1800))
        let snapshot = PowerSnapshot.fake(powerSource: .ac, batteryPercent: 100)

        #expect(ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt,
            now: engagedAt.addingTimeInterval(1799), settings: settings) == nil)
        #expect(ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt,
            now: engagedAt.addingTimeInterval(1801), settings: settings) == .timeout)
    }

    @Test("전원 연결 + 시간 내면 해제하지 않는다")
    func staysEngaged() {
        let snapshot = PowerSnapshot.fake(powerSource: .ac, batteryPercent: 100)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt, now: engagedAt.addingTimeInterval(3600),
            settings: settings)
        #expect(reason == nil)
    }

    @Test("배터리여도 임계 위면 유지한다 — 사용자가 확인하고 켠 것이다")
    func batteryAboveThresholdStaysEngaged() {
        let snapshot = PowerSnapshot.fake(powerSource: .battery, batteryPercent: 40)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt, now: engagedAt.addingTimeInterval(60),
            settings: settings)
        #expect(reason == nil)
    }

    @Test("잔량을 못 읽으면 배터리 이유로 해제하지 않는다")
    func unknownBatteryDoesNotTrigger() {
        let snapshot = PowerSnapshot.fake(powerSource: .battery, batteryPercent: nil)
        let reason = ClamshellPolicy.autoReleaseReason(
            snapshot, engagedAt: engagedAt, now: engagedAt.addingTimeInterval(60),
            settings: settings)
        #expect(reason == nil, "읽지 못한 값을 위험 신호로 오인하면 오작동한다")
    }
}
