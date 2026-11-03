import ClamshellCore
import Foundation
import IOKit

@testable import HelperCore

/// 읽기와 쓰기를 한 몸으로 흉내낸다 — 실제 시스템에서도 쓰면 읽는 값이 바뀌므로.
///
/// **커널 실적용값과 디스크 희망값을 따로 들고 있다.** 실제 시스템에서 이 둘은
/// powerd 를 거쳐 비동기로 갈라지고(DESIGN.md §1), 갈라진 상태가 곧 복원 버그의
/// 온상이다. 한 필드로 뭉뚱그리면 그 버그를 테스트가 구조적으로 못 잡는다.
final class FakeSystem: PowerStateReading, SleepDisabledWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PowerSnapshot
    private var result: IOReturn = kIOReturnSuccess
    private var calls: [Bool] = []

    /// true 면 write 가 디스크만 갱신하고 커널에는 반영되지 않는다.
    /// powerd 가 아직 적용하지 않은 구간을 흉내낸다.
    private var kernelFrozen = false

    /// - Parameter diskKeyAbsent: true 면 디스크에 `SleepDisabled` 키가 아예 없는 상태.
    ///   한 번도 설정된 적 없는 맥이 이렇다. nil 처리 경로를 테스트하려면 이게 필요하다.
    init(
        sleepDisabled: Bool,
        desiredSleepDisabled: Bool? = nil,
        diskKeyAbsent: Bool = false,
        bootSession: String = "SESSION-A"
    ) {
        current = PowerSnapshot(
            lidClosed: false,
            clamshellCausesSleep: true,
            sleepDisabled: sleepDisabled,
            // 따로 주지 않으면 커널과 디스크가 일치하는 평범한 상태.
            desiredSleepDisabled: diskKeyAbsent ? nil : (desiredSleepDisabled ?? sleepDisabled),
            powerSource: .ac,
            batteryPercent: 100,
            externalDisplayCount: 0,
            bootSessionUUID: bootSession
        )
    }

    func snapshot() -> PowerSnapshot { lock.withLock { current } }
    func sleepBlockers() -> [SleepBlocker] { [] }

    /// 실제 SPI 와 같은 순서로 움직인다 — 먼저 디스크에 쓰고, powerd 가 커널에 반영한다.
    func write(_ value: Bool) -> IOReturn {
        lock.withLock {
            calls.append(value)
            guard result == kIOReturnSuccess else { return result }
            current.desiredSleepDisabled = value
            if !kernelFrozen { current.sleepDisabled = value }
            return result
        }
    }

    // MARK: - 테스트 조작

    var writeCalls: [Bool] { lock.withLock { calls } }
    var sleepDisabled: Bool { lock.withLock { current.sleepDisabled } }
    var desiredSleepDisabled: Bool? { lock.withLock { current.desiredSleepDisabled } }

    func failWrites(with code: IOReturn) { lock.withLock { result = code } }

    /// 이후의 write 가 커널에 반영되지 않게 한다(디스크에만 남는다).
    func freezeKernel() { lock.withLock { kernelFrozen = true } }

    /// 다시 커널까지 반영되게 한다. 복원 재시도가 성공하는 상황을 만들 때 쓴다.
    func unfreezeKernel() { lock.withLock { kernelFrozen = false } }

    /// powerd 가 디스크 값을 뒤늦게 커널에 반영하는 상황.
    func powerdApplies() {
        lock.withLock {
            if let d = current.desiredSleepDisabled { current.sleepDisabled = d }
        }
    }

    func reboot(as session: String) { lock.withLock { current.bootSessionUUID = session } }
}

/// 시간을 직접 돌린다. 워치독 테스트가 90초를 실제로 기다릴 수는 없다.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    var now: @Sendable () -> Date { { self.lock.withLock { self.current } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// 테스트마다 격리된 baseline 저장소.
func makeTemporaryStore() -> BaselineStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mc-test-\(UUID().uuidString)").path
    return BaselineStore(directory: directory)
}
