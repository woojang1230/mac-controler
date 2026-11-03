import Foundation
import HelperProtocol
import IOKit
import Testing

@testable import HelperCore

/// 폴링 대기로 테스트가 느려지지 않게 타임아웃을 짧게 준다.
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

@Suite("engage 와 복원")
struct EngageTests {

    @Test("engage 하면 켜지고, release 하면 원래 값으로 돌아온다")
    func roundTrip() {
        let system = FakeSystem(sleepDisabled: false)
        let service = makeService(system: system, store: makeTemporaryStore())

        _ = service.handle(.engage(limit: .default))
        #expect(system.sleepDisabled == true)

        _ = service.handle(.release)
        #expect(system.sleepDisabled == false)
    }

    @Test("★ 남이 켜둔 SleepDisabled 는 release 해도 켠 채로 둔다")
    func respectsForeignBaseline() {
        // 다른 도구나 사용자가 이미 켜둔 상태에서 우리가 engage 한 경우.
        let system = FakeSystem(sleepDisabled: true)
        let service = makeService(system: system, store: makeTemporaryStore())

        _ = service.handle(.engage(limit: .default))
        _ = service.handle(.release)

        #expect(system.sleepDisabled == true,
                "baseline 이 true 였으므로 false 로 덮으면 남의 설정을 파괴한다")
        #expect(system.writeCalls.allSatisfy { $0 == true } || system.writeCalls.isEmpty,
                "false 를 쓴 적이 없어야 한다")
    }

    @Test("engage 는 켜기 전에 baseline 을 먼저 저장한다")
    func savesBaselineBeforeTurningOn() throws {
        let system = FakeSystem(sleepDisabled: false)
        let store = makeTemporaryStore()
        let service = makeService(system: system, store: store)

        _ = service.handle(.engage(limit: .default))

        let saved = try #require(store.load())
        #expect(saved.sleepDisabled == false, "켜기 **전** 값이 저장돼야 한다")
        #expect(saved.bootSessionUUID == "SESSION-A")
    }

    @Test("쓰기가 실패하면 baseline 을 남기지 않는다")
    func failedEngageLeavesNoTrace() {
        let system = FakeSystem(sleepDisabled: false)
        system.failWrites(with: IOReturn(bitPattern: 0xE000_02C1))  // NotPrivileged
        let store = makeTemporaryStore()
        let service = makeService(system: system, store: store)

        let reply = service.handle(.engage(limit: .default))

        guard case .denied = reply else {
            Issue.record("쓰기 실패는 denied 여야 한다. 실제: \(reply)")
            return
        }
        #expect(store.load() == nil, "실패했는데 baseline 이 남으면 다음 기동에서 헛복원을 한다")
    }

    @Test("커널 반영이 확인되지 않으면 notConfirmed 를 돌려준다")
    func unconfirmedWriteReported() {
        let system = FakeSystem(sleepDisabled: false)
        system.freezeKernel()  // 디스크엔 쓰이지만 커널 반영은 안 됨
        let service = makeService(system: system, store: makeTemporaryStore())

        let reply = service.handle(.engage(limit: .default))
        guard case .notConfirmed = reply else {
            Issue.record("IOReturn 성공만 믿으면 안 된다. 실제: \(reply)")
            return
        }
    }

    @Test("이미 engage 중이면 중복으로 켜지 않는다")
    func doubleEngageIsNoop() {
        let system = FakeSystem(sleepDisabled: false)
        let service = makeService(system: system, store: makeTemporaryStore())

        _ = service.handle(.engage(limit: .default))
        let reply = service.handle(.engage(limit: .default))

        guard case .alreadyInDesiredState = reply else {
            Issue.record("두 번째 engage 는 alreadyInDesiredState 여야 한다. 실제: \(reply)")
            return
        }
        #expect(system.writeCalls.count == 1)
    }
}

/// 커널 실적용값과 디스크 희망값이 갈라진 상태에서의 복원.
///
/// 되돌리기의 진짜 대상은 **디스크 값**이다. 그것만 영구 저장되고 powerd 가
/// 부팅마다 커널에 다시 밀어넣기 때문이다. 커널값만 보고 "이미 원하는 상태"라고
/// 판단해 조기 반환하면, 쓰기를 한 번도 하지 않고 baseline 만 지우게 되고
/// 디스크에 남은 값이 되살아나 맥이 영영 안 잔다.
@Suite("커널/디스크 괴리 시 복원")
struct DivergedStateTests {

    @Test("★ 부팅 직후 고아 복구 — 커널은 false 인데 디스크에 true 가 남아 있다")
    func orphanRecoveryWritesDiskNotJustKernel() {
        let store = makeTemporaryStore()

        // 지난 세션에서 engage 한 채 종료됐다. baseline 은 '켜기 전 = false'.
        let before = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        _ = makeService(system: before, store: store)
            .handle(.engage(limit: .default))

        // 재부팅. 헬퍼(RunAtLoad)가 powerd 의 재적용보다 **먼저** 떴다 —
        // 커널은 아직 false 로 보이지만 디스크에는 true 가 남아 있다.
        let after = FakeSystem(
            sleepDisabled: false, desiredSleepDisabled: true, bootSession: "SESSION-B")
        let revived = makeService(system: after, store: store)
        revived.recoverOrphanIfNeeded()

        #expect(after.desiredSleepDisabled == false,
                "디스크에 false 를 실제로 써야 한다. 안 쓰면 powerd 가 true 를 되살린다")
        #expect(after.writeCalls.isEmpty == false,
                "쓰기를 한 번도 하지 않고 baseline 만 지우면 복원 근거가 사라진다")

        // powerd 가 뒤늦게 디스크 값을 반영해도 안전해야 한다.
        after.powerdApplies()
        #expect(after.sleepDisabled == false)
    }

    @Test("★ notConfirmed 로 끝난 engage 를 release 하면 디스크를 되돌린다")
    func releaseAfterUnconfirmedEngageWritesDisk() {
        let system = FakeSystem(sleepDisabled: false)
        let service = makeService(system: system, store: makeTemporaryStore())

        // engage 는 디스크에 true 를 쓰지만 커널 반영이 확인되지 않는다.
        system.freezeKernel()
        let engaged = service.handle(.engage(limit: .default))
        guard case .notConfirmed = engaged else {
            Issue.record("커널 미반영이면 notConfirmed 여야 한다. 실제: \(engaged)")
            return
        }
        #expect(system.desiredSleepDisabled == true)

        _ = service.handle(.release)

        #expect(system.desiredSleepDisabled == false,
                "커널이 false 로 보인다고 조기 반환하면 디스크의 true 가 남는다")
        #expect(system.writeCalls.contains(false),
                "false 를 실제로 쓴 적이 있어야 한다")
    }

    @Test("★ 디스크 키가 없던 자리에 true 를 영구히 남기지 않는다")
    func absentDiskKeyIsNotTurnedIntoPermanentTrue() {
        // 디스크에 SleepDisabled 키가 아예 없는데 커널만 true 인 상태.
        // baseline 을 커널값(true)으로 잡으면, release 가 "이미 true 니 됐다"고
        // 판단해 쓰기를 건너뛰고 baseline 을 지운다 → 없던 키가 true 로 영구 잔존한다.
        // nil 의 의미는 SleepSwitch.settled 와 같아야 한다: '슬립 차단 안 함' = false.
        let system = FakeSystem(sleepDisabled: true, diskKeyAbsent: true)
        let store = makeTemporaryStore()
        let service = makeService(system: system, store: store)

        _ = service.handle(.engage(limit: .default))
        _ = service.handle(.release)

        #expect(system.desiredSleepDisabled != true,
                "없던 디스크 키가 true 로 남으면 다음 부팅에 powerd 가 되살린다")
        #expect(store.load() == nil, "복원이 끝났으면 baseline 도 정리돼야 한다")
    }

    @Test("커널·디스크가 둘 다 목표와 같으면 쓰지 않는다")
    func trulyIdempotentSkipsWrite() {
        // 남이 켜둔 상태 위에서 engage → 이미 양쪽 다 true 라 쓸 이유가 없다.
        let system = FakeSystem(sleepDisabled: true, desiredSleepDisabled: true)
        let service = makeService(system: system, store: makeTemporaryStore())

        _ = service.handle(.engage(limit: .default))
        #expect(system.writeCalls.isEmpty, "불필요한 쓰기는 하지 않는다")
    }
}

@Suite("워치독")
struct WatchdogTests {

    @Test("★ 하트비트가 끊기면 baseline 으로 되돌린다")
    func restoresOnHeartbeatTimeout() {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .default))
        #expect(system.sleepDisabled == true)

        clock.advance(HelperConstants.heartbeatTimeout + 1)
        service.checkHeartbeat()

        #expect(system.sleepDisabled == false, "앱이 죽으면 맥이 영영 안 자는 상태로 남으면 안 된다")
    }

    @Test("하트비트가 살아있으면 되돌리지 않는다")
    func staysEngagedWhileHeartbeating() {
        let system = FakeSystem(sleepDisabled: false)
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        _ = service.handle(.engage(limit: .default))

        // 30초마다 하트비트를 보내며 5분을 보낸다.
        for _ in 0..<10 {
            clock.advance(HelperConstants.heartbeatInterval)
            _ = service.handle(.heartbeat(limit: .default))
            service.checkHeartbeat()
        }

        #expect(system.sleepDisabled == true)
    }

    @Test("★ 헬퍼가 반복 재시작해도 절대 상한이 지나면 복원한다")
    func absoluteCapSurvivesHelperRestarts() {
        // 실측으로 드러난 구멍: 헬퍼가 재시작하면 lastHeartbeat 이 now 로 리셋된다.
        // 하트비트만 믿으면 30초마다 재시작하는 헬퍼에서는 워치독이 영영 안 뜬다.
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        let clock = TestClock()

        _ = makeService(system: system, store: store, clock: clock)
            .handle(.engage(limit: .default))
        #expect(system.sleepDisabled == true)

        // 앱은 죽었다. 헬퍼만 30초마다 재시작하며 5시간이 흐른다.
        var service = makeService(system: system, store: store, clock: clock)
        for _ in 0..<600 {
            clock.advance(30)
            service = makeService(system: system, store: store, clock: clock)  // 재시작
            service.recoverOrphanIfNeeded()                                     // 하트비트 리셋
            service.checkHeartbeat()
            if !system.sleepDisabled { break }
        }

        #expect(system.sleepDisabled == false,
                "재시작이 하트비트를 계속 리셋해도 engagedAt 기준 절대 상한은 넘길 수 없다")
    }

    @Test("절대 상한 안이면 재시작해도 유지된다")
    func withinCapStaysEngaged() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        let clock = TestClock()

        _ = makeService(system: system, store: store, clock: clock)
            .handle(.engage(limit: .default))

        clock.advance(2 * 3600)  // 기본 상한 4시간의 절반
        let revived = makeService(system: system, store: store, clock: clock)
        revived.recoverOrphanIfNeeded()
        revived.checkHeartbeat()

        #expect(system.sleepDisabled == true)
    }

    @Test("engage 중이 아니면 워치독이 아무것도 하지 않는다")
    func idleWatchdogDoesNothing() {
        let system = FakeSystem(sleepDisabled: true)  // 남이 켜둔 상태
        let clock = TestClock()
        let service = makeService(system: system, store: makeTemporaryStore(), clock: clock)

        clock.advance(HelperConstants.heartbeatTimeout * 10)
        service.checkHeartbeat()

        #expect(system.sleepDisabled == true, "우리가 켠 게 아니면 건드리지 않는다")
        #expect(system.writeCalls.isEmpty)
    }
}

@Suite("부팅 세션 고아 복구")
struct OrphanRecoveryTests {

    @Test("★ 재부팅 후 남은 baseline 은 기동 즉시 되돌린다")
    func recoversAcrossReboot() {
        let store = makeTemporaryStore()

        // 1) 지난 세션에서 engage 한 채 헬퍼가 죽었다.
        let before = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        _ = makeService(system: before, store: store)
            .handle(.engage(limit: .default))
        #expect(before.sleepDisabled == true)

        // 2) 재부팅. SleepDisabled 는 영구 저장이라 켜진 채로 살아남는다.
        let after = FakeSystem(sleepDisabled: true, bootSession: "SESSION-B")
        let revived = makeService(system: after, store: store)
        revived.recoverOrphanIfNeeded()

        #expect(after.sleepDisabled == false, "부팅 세션이 다르면 즉시 원복해야 한다")
        #expect(store.load() == nil, "복원했으면 baseline 도 지워야 한다")
    }

    @Test("같은 세션에서 헬퍼만 재시작된 경우는 원복하지 않는다")
    func sameSessionKeepsEngagement() {
        let store = makeTemporaryStore()

        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        _ = makeService(system: system, store: store).handle(.engage(limit: .default))

        // 헬퍼만 죽었다 살아남 — 부팅 세션은 그대로.
        let revived = makeService(system: system, store: store)
        revived.recoverOrphanIfNeeded()

        #expect(system.sleepDisabled == true, "앱이 아직 살아있을 수 있다. 워치독이 판단한다")
        #expect(store.load() != nil)
    }

    @Test("같은 세션 재시작 후에도 워치독은 계속 감시한다")
    func watchdogResumesAfterRestart() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        _ = makeService(system: system, store: store).handle(.engage(limit: .default))

        let clock = TestClock()
        let revived = makeService(system: system, store: store, clock: clock)
        revived.recoverOrphanIfNeeded()

        clock.advance(HelperConstants.heartbeatTimeout + 1)
        revived.checkHeartbeat()

        #expect(system.sleepDisabled == false, "재시작해도 앱이 안 붙으면 결국 원복돼야 한다")
    }

    @Test("★ 고아 복원이 미확인으로 끝나도 워치독이 재시도한다")
    func failedOrphanRestoreIsRetried() {
        let store = makeTemporaryStore()
        let system = FakeSystem(sleepDisabled: false, bootSession: "SESSION-A")
        _ = makeService(system: system, store: store).handle(.engage(limit: .default))

        // 재부팅 + powerd 가 아직 따라오지 못해 복원 확인이 실패하는 상황.
        system.reboot(as: "SESSION-B")
        system.freezeKernel()

        let clock = TestClock()
        let revived = makeService(system: system, store: store, clock: clock)
        revived.recoverOrphanIfNeeded()
        #expect(store.load() != nil, "확인 실패면 baseline 을 유지해 재시도 근거를 남긴다")

        // powerd 가 정상화된 뒤 워치독이 다시 시도해야 한다.
        // 고아 분기는 lastHeartbeat 을 세우지 않으므로, 그 상태를 '복원 대기'로
        // 인식하지 못하면 4시간 절대 상한까지 아무도 손대지 않는다.
        system.unfreezeKernel()
        clock.advance(HelperConstants.heartbeatInterval)
        revived.checkHeartbeat()

        #expect(system.sleepDisabled == false, "재시도로 복원돼야 한다")
        #expect(store.load() == nil, "복원 성공했으면 baseline 정리")
    }

    @Test("baseline 이 없으면 기동 시 아무것도 하지 않는다")
    func noBaselineNoAction() {
        let system = FakeSystem(sleepDisabled: true)
        let service = makeService(system: system, store: makeTemporaryStore())
        service.recoverOrphanIfNeeded()

        #expect(system.writeCalls.isEmpty)
        #expect(system.sleepDisabled == true)
    }
}
