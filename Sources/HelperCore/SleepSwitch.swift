import ClamshellCore
import Foundation
import IOKit
import OSLog

/// `SleepDisabled` 쓰기를 추상화한다. 테스트에서 가짜를 꽂기 위한 것이다.
public protocol SleepDisabledWriting: Sendable {
    func write(_ value: Bool) -> IOReturn
}

/// 실제 SPI 를 부르는 구현. **프로젝트에서 쓰기를 실행하는 유일한 지점.**
public struct SystemSleepDisabledWriter: SleepDisabledWriting {
    public init() {}
    public func write(_ value: Bool) -> IOReturn {
        SystemPowerSettings.writeSleepDisabled(value)
    }
}

/// `SleepDisabled` 를 켜고 끄고, **커널에 실제로 반영됐는지 확인한다.**
///
/// `IOReturn == success` 를 믿지 않는다. 이 SPI 는 디스크에 희망값을 쓰고
/// powerd 를 깨울 뿐이고, 커널 반영은 powerd 가 비동기로 한다.
/// 그래서 호출 후 `IOPMrootDomain` 을 폴링해 실적용을 눈으로 확인한다.
/// DESIGN.md §1 참조.
public struct SleepSwitch: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var code: IOReturn
        public var confirmed: Bool
        public var elapsed: TimeInterval
        public var effective: Bool
    }

    private static let log = Logger(subsystem: "dev.maccontroler.helper", category: "switch")

    let reader: any PowerStateReading
    let writer: any SleepDisabledWriting

    /// 폴링 상한. 2초는 DESIGN.md 의 추정치이며 실측으로 조정한다.
    var confirmationTimeout: TimeInterval
    var pollInterval: TimeInterval

    public init(
        reader: any PowerStateReading,
        writer: any SleepDisabledWriting = SystemSleepDisabledWriter(),
        confirmationTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05
    ) {
        self.reader = reader
        self.writer = writer
        self.confirmationTimeout = confirmationTimeout
        self.pollInterval = pollInterval
    }

    public func apply(_ desired: Bool) -> Outcome {
        let start = Date()

        if reader.snapshot().sleepDisabled == desired {
            Self.log.notice("이미 원하는 상태(\(desired, privacy: .public)) — SPI 호출 생략")
            return Outcome(code: kIOReturnSuccess, confirmed: true, elapsed: 0, effective: desired)
        }

        let code = writer.write(desired)
        Self.log.notice(
            "write(\(desired, privacy: .public)) → 0x\(String(format: "%08X", code), privacy: .public)")

        guard code == kIOReturnSuccess else {
            return Outcome(
                code: code, confirmed: false,
                elapsed: Date().timeIntervalSince(start),
                effective: reader.snapshot().sleepDisabled)
        }

        // 여기서부터가 핵심 — 반환값이 아니라 커널을 본다.
        var effective = reader.snapshot().sleepDisabled
        while effective != desired, Date().timeIntervalSince(start) < confirmationTimeout {
            Thread.sleep(forTimeInterval: pollInterval)
            effective = reader.snapshot().sleepDisabled
        }

        let elapsed = Date().timeIntervalSince(start)
        let confirmed = (effective == desired)
        Self.log.notice(
            "실적용 확인=\(confirmed, privacy: .public) 소요=\(String(format: "%.3f", elapsed), privacy: .public)초")

        return Outcome(code: code, confirmed: confirmed, elapsed: elapsed, effective: effective)
    }
}
