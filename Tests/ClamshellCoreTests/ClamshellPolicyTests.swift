import CoreGraphics
import Testing

@testable import ClamshellCore

@Suite("클램쉘 판정")
struct ClamshellPolicyTests {

    /// `isAwakeOnLidClose` 는 두 값의 OR 이다. 하나만 보면 오답이 나오므로
    /// 네 조합을 전부 못박아 둔다.
    struct TruthCase: Sendable, CustomTestStringConvertible {
        let causesSleep: Bool
        let sleepDisabled: Bool
        let expected: Bool
        let why: String
        var testDescription: String { why }
    }

    @Test(
        "뚜껑 닫음 시 깨어있는지 판정",
        arguments: [
            TruthCase(
                causesSleep: true, sleepDisabled: false, expected: false,
                why: "닫으면 자는 조건 + 슬립 차단 없음 → 잔다"),
            TruthCase(
                causesSleep: true, sleepDisabled: true, expected: true,
                why: "닫으면 자는 조건이지만 슬립이 차단됨 → 안 잔다"),
            TruthCase(
                causesSleep: false, sleepDisabled: false, expected: true,
                why: "외부 디스플레이 등으로 이미 안 자는 조건 → 안 잔다"),
            TruthCase(
                causesSleep: false, sleepDisabled: true, expected: true,
                why: "둘 다 안 자는 조건 → 안 잔다"),
        ]
    )
    func awakeOnLidClose(_ c: TruthCase) {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: c.causesSleep,
            sleepDisabled: c.sleepDisabled
        )
        #expect(ClamshellPolicy.isAwakeOnLidClose(snapshot) == c.expected, "\(c.why)")
    }

    @Test("AppleClamshellCausesSleep 만 보면 오답이 된다")
    func causesSleepAloneIsNotEnough() {
        // 이 맥이 조사 시점에 그랬던 상태: 닫으면 자는 조건인데 SleepDisabled 가 켜져 있었다.
        let snapshot = PowerSnapshot.fake(clamshellCausesSleep: true, sleepDisabled: true)
        #expect(snapshot.clamshellCausesSleep == true)
        #expect(ClamshellPolicy.isAwakeOnLidClose(snapshot) == true,
                "causesSleep 만 보고 '잔다'고 판정하면 틀린다")
    }

    @Test("우리가 켜지 않은 SleepDisabled 도 그대로 존중한다")
    func foreignSleepDisabledIsRespected() {
        // 다른 도구나 사용자가 켜둔 상태. 앱은 이것을 baseline 으로 읽어야 하고,
        // '내가 켠 게 아니니 꺼도 된다'고 판단해서는 안 된다.
        let snapshot = PowerSnapshot.fake(clamshellCausesSleep: true, sleepDisabled: true)
        #expect(ClamshellPolicy.isAwakeOnLidClose(snapshot) == true)
        #expect(ClamshellPolicy.isEngagementNeeded(snapshot) == false,
                "이미 안 자는 상태면 개입할 이유가 없다")
    }

    @Test("외부 디스플레이가 붙어 있으면 개입하지 않는다")
    func noEngagementWithExternalDisplay() {
        let snapshot = PowerSnapshot.fake(
            clamshellCausesSleep: false,
            sleepDisabled: false,
            externalDisplayCount: 1
        )
        #expect(ClamshellPolicy.isEngagementNeeded(snapshot) == false,
                "그래픽스가 이미 클램쉘 슬립을 끈 상태다")
    }

    @Test("닫으면 자고 차단도 없으면 개입이 필요하다")
    func engagementNeeded() {
        let snapshot = PowerSnapshot.fake(clamshellCausesSleep: true, sleepDisabled: false)
        #expect(ClamshellPolicy.isEngagementNeeded(snapshot) == true)
    }
}

@Suite("메뉴바 아이템 가시성")
struct StatusItemVisibilityTests {

    // 이 맥에서 실측한 값 (DESIGN.md §7-1)
    let left = CGRect(x: 0, y: 1085, width: 771, height: 32)
    let right = CGRect(x: 956, y: 1085, width: 772, height: 32)

    @Test("노치 아래에 놓인 아이템은 안 보이는 것으로 판정한다")
    func hiddenBehindNotch() {
        // Phase 0 에서 실제로 관측된 좌표다.
        let frame = CGRect(x: 804, y: 1084, width: 38, height: 33)
        #expect(ClamshellPolicy.isStatusItemVisible(frame, areas: [left, right]) == false)
    }

    @Test("화면 밖으로 밀려난 아이템은 안 보이는 것으로 판정한다")
    func pushedOffscreen() {
        // Hidden Bar 가 숨길 때 쓰는 좌표.
        let frame = CGRect(x: -4244, y: 1084, width: 38, height: 33)
        #expect(ClamshellPolicy.isStatusItemVisible(frame, areas: [left, right]) == false)
    }

    @Test("오른쪽 구간 안에 온전히 들어가면 보이는 것으로 판정한다")
    func visibleInRightArea() {
        let frame = CGRect(x: 1000, y: 1085, width: 38, height: 32)
        #expect(ClamshellPolicy.isStatusItemVisible(frame, areas: [left, right]) == true)
    }

    @Test("왼쪽 구간 안에 온전히 들어가도 보이는 것으로 판정한다")
    func visibleInLeftArea() {
        let frame = CGRect(x: 400, y: 1085, width: 38, height: 32)
        #expect(ClamshellPolicy.isStatusItemVisible(frame, areas: [left, right]) == true)
    }

    @Test("구간 경계를 걸치면 안 보이는 것으로 판정한다")
    func straddlingBoundary() {
        // 오른쪽 구간 시작(956) 을 걸침 — 일부가 노치에 잘린다.
        let frame = CGRect(x: 940, y: 1085, width: 38, height: 32)
        #expect(ClamshellPolicy.isStatusItemVisible(frame, areas: [left, right]) == false)
    }
}
