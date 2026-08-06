import ClamshellCore
import Foundation
import IOKit

@testable import HelperCore

/// 읽기와 쓰기를 한 몸으로 흉내낸다 — 실제 시스템에서도 쓰면 읽는 값이 바뀌므로.
final class FakeSystem: PowerStateReading, SleepDisabledWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PowerSnapshot
    private var result: IOReturn = kIOReturnSuccess
    private var calls: [Bool] = []

    /// true 면 write 가 성공을 반환하되 실제 값은 바뀌지 않는다.
    /// powerd 가 반영에 실패하는 상황(= notConfirmed)을 흉내낸다.
    private var swallowWrites = false

    init(sleepDisabled: Bool, bootSession: String = "SESSION-A") {
        current = PowerSnapshot(
            lidClosed: false,
            clamshellCausesSleep: true,
            sleepDisabled: sleepDisabled,
            powerSource: .ac,
            batteryPercent: 100,
            externalDisplayCount: 0,
            bootSessionUUID: bootSession
        )
    }

    func snapshot() -> PowerSnapshot { lock.withLock { current } }
    func sleepBlockers() -> [SleepBlocker] { [] }

    func write(_ value: Bool) -> IOReturn {
        lock.withLock {
            calls.append(value)
            guard result == kIOReturnSuccess else { return result }
            if !swallowWrites { current.sleepDisabled = value }
            return result
        }
    }

    // MARK: - 테스트 조작

    var writeCalls: [Bool] { lock.withLock { calls } }
    var sleepDisabled: Bool { lock.withLock { current.sleepDisabled } }

    func failWrites(with code: IOReturn) { lock.withLock { result = code } }
    func swallowWrite() { lock.withLock { swallowWrites = true } }
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
