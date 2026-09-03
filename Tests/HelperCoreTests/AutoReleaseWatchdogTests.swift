import Foundation
import HelperProtocol
import IOKit
import Testing

@testable import HelperCore

private func makeService(
    system: FakeSystem,
    store: BaselineStore,
    clock: TestClock = TestClock()
) -> HelperService {
    HelperService(
        reader: system, writer: system, store: store,
        confirmationTimeout: 0.2, pollInterval: 0.01, now: clock.now
    )
}

/// 사용자가 고른 상한을 헬퍼가 실제로 지키는가.
///
/// 이 스위트의 핵심은 두 가지다:
///  1. '꺼짐' 을 고르면 절대 상한이 **정말로** 사라진다 (안 그러면 설정이 거짓말이다)
///  2. 그래도 하트비트 워치독은 **절대** 사라지지 않는다 (앱이 죽으면 되돌려야 한다)
@Suite("사용자가 고른 자동 해제 상한")
struct AutoReleaseLimitWatchdogTests {

    @Test("고른 상한이 지나면 복원한다", arguments: [1800.0, 3600.0, 8 * 3600.0])
    func restoresAtChosenLimit(_ seconds: TimeInterval) {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .after(seconds: seconds)))

        // 상한 직전까지는 하트비트를 보내며 버틴다.
        clock.advance(seconds - 1)
        _ = service.handle(.heartbeat(limit: .after(seconds: seconds)))
        service.checkHeartbeat()
        #expect(system.sleepDisabled == true, "상한 전에 풀리면 안 된다")

        clock.advance(2)
        _ = service.handle(.heartbeat(limit: .after(seconds: seconds)))
        service.checkHeartbeat()
        #expect(system.sleepDisabled == false, "\(seconds)초 상한을 넘겼는데 안 풀렸다")
    }

    @Test("★ '꺼짐' 이면 아무리 오래 지나도 시간으로는 풀지 않는다")
    func neverLimitIgnoresElapsedTime() {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .never))

        // 앱은 멀쩡히 살아 하트비트를 계속 보낸다. 사흘이 흐른다.
        for _ in 0..<(3 * 24 * 120) {
            clock.advance(HelperConstants.heartbeatInterval)
            _ = service.handle(.heartbeat(limit: .never))
            service.checkHeartbeat()
            if !system.sleepDisabled { break }
        }

        #expect(system.sleepDisabled == true,
                "'꺼짐' 을 골랐는데 시간이 지났다고 풀면 설정이 거짓말이 된다")
    }

    @Test("★ '꺼짐' 이어도 앱이 죽으면 하트비트 워치독이 복원한다")
    func neverLimitStillHasHeartbeatWatchdog() {
        // 이것이 무너지면 앱 크래시 = 맥이 영영 안 자는 상태다.
        // 사용자가 끌 수 있는 것은 '시간 상한' 뿐이고, 이 안전망은 대상이 아니다.
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .never))
        clock.advance(HelperConstants.heartbeatTimeout + 1)
        service.checkHeartbeat()

        #expect(system.sleepDisabled == false, "'꺼짐' 은 시간 상한만 끄는 것이지 워치독을 끄는 게 아니다")
    }

    @Test("★ '꺼짐' 이어도 재부팅을 건너뛴 고아 baseline 은 즉시 복원한다")
    func neverLimitStillRecoversOrphan() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        let clock = TestClock()

        _ = makeService(system: system, store: store, clock: clock)
            .handle(.engage(limit: .never))

        system.reboot(as: "SESSION-B")
        let revived = makeService(system: system, store: store, clock: clock)
        revived.recoverOrphanIfNeeded()

        #expect(system.sleepDisabled == false)
    }

    @Test("★ 상한은 디스크에 남아 헬퍼 재시작을 넘긴다")
    func limitSurvivesHelperRestart() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        let clock = TestClock()

        _ = makeService(system: system, store: store, clock: clock)
            .handle(.engage(limit: .after(seconds: 1800)))

        // 앱은 죽었고 헬퍼만 재시작을 반복한다. 30분 상한이 지나면 풀려야 한다.
        var service = makeService(system: system, store: store, clock: clock)
        for _ in 0..<200 {
            clock.advance(30)
            service = makeService(system: system, store: store, clock: clock)
            service.recoverOrphanIfNeeded()
            service.checkHeartbeat()
            if !system.sleepDisabled { break }
        }

        #expect(system.sleepDisabled == false, "메모리에만 들고 있으면 재시작에 상한이 증발한다")
        #expect(clock.now().timeIntervalSince(Date(timeIntervalSince1970: 1_700_000_000)) < 3600,
                "30분 상한인데 한 시간을 넘겨 풀렸다")
    }
}

/// 설정 창에서 상한을 바꿨을 때, **이미 켜져 있는** engagement 에도 반영되는가.
///
/// 반영되지 않으면 사용자가 '꺼짐' 으로 바꿔도 헬퍼는 옛 4시간을 들고 있다가
/// 조용히 풀어버린다. 앱이 하트비트마다 현재 설정을 같이 실어 보내는 이유다.
@Suite("진행 중인 engagement 의 상한 변경")
struct LimitUpdateTests {

    @Test("★ 하트비트가 실어 온 새 상한이 진행 중인 engagement 에 반영된다")
    func heartbeatUpdatesLimit() {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .after(seconds: 4 * 3600)))

        // 사용자가 설정 창에서 '꺼짐' 으로 바꿨다. 다음 하트비트가 그것을 알린다.
        _ = service.handle(.heartbeat(limit: .never))

        clock.advance(5 * 3600)
        _ = service.handle(.heartbeat(limit: .never))
        service.checkHeartbeat()

        #expect(system.sleepDisabled == true, "설정을 바꿨는데 옛 상한으로 풀리면 안 된다")
    }

    @Test("★ 상한을 줄이면 즉시 그 기준으로 판정한다")
    func shorterLimitAppliesImmediately() {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .never))
        clock.advance(2 * 3600)  // 두 시간 켜둔 상태

        // 사용자가 '1시간' 으로 바꿨다. 이미 두 시간이 지났으므로 바로 풀려야 한다.
        _ = service.handle(.heartbeat(limit: .after(seconds: 3600)))
        service.checkHeartbeat()

        #expect(system.sleepDisabled == false)
    }

    @Test("바뀐 상한은 디스크에도 남는다")
    func updatedLimitIsPersisted() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        let clock = TestClock()
        let service = makeService(system: system, store: store, clock: clock)

        _ = service.handle(.engage(limit: .after(seconds: 4 * 3600)))
        _ = service.handle(.heartbeat(limit: .never))

        #expect(store.load()?.autoRelease == .never, "메모리만 바꾸면 재시작에서 갈라진다")
    }

    @Test("engage 중이 아니면 하트비트가 baseline 을 만들어내지 않는다")
    func heartbeatDoesNotCreateBaseline() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false)
        let service = makeService(system: system, store: store, clock: TestClock())

        _ = service.handle(.heartbeat(limit: .never))

        #expect(store.load() == nil)
        #expect(system.writeCalls.isEmpty)
    }

    @Test("헬퍼가 보고하는 상태에 현재 상한이 들어 있다")
    func statusReportsLimit() {
        let system = FakeSystem(sleepDisabled: false)
        let service = makeService(system: system, store: makeTemporaryStore())

        guard case .status(let idle) = service.handle(.status) else {
            Issue.record("status 응답이 아니다")
            return
        }
        #expect(idle.autoRelease == nil, "engage 중이 아니면 상한도 없다")

        _ = service.handle(.engage(limit: .after(seconds: 1800)))
        guard case .status(let engaged) = service.handle(.status) else {
            Issue.record("status 응답이 아니다")
            return
        }
        #expect(engaged.autoRelease == .after(seconds: 1800))
    }
}
