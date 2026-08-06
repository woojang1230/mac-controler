import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// IOKit 으로 실제 시스템 상태를 읽는다. **전부 root 없이 가능한 읽기뿐이다.**
///
/// 쓰기(`SleepDisabled` 변경)는 이 타입의 책임이 아니다 — 그건 root 헬퍼의
/// `SleepBlocker` 가 하며 Phase 2 에서 들어온다.
public struct IOKitPowerStateReader: PowerStateReading {

    public init() {}

    public func snapshot() -> PowerSnapshot {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { if root != 0 { IOObjectRelease(root) } }

        func property(_ key: String) -> Any? {
            guard root != 0 else { return nil }
            return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }

        let (source, percent) = Self.powerSourceAndPercent()

        return PowerSnapshot(
            lidClosed: property("AppleClamshellState") as? Bool ?? false,
            clamshellCausesSleep: property("AppleClamshellCausesSleep") as? Bool ?? true,
            sleepDisabled: property("SleepDisabled") as? Bool ?? false,
            powerSource: source,
            batteryPercent: percent,
            externalDisplayCount: Self.externalDisplayCount(),
            bootSessionUUID: property("BootSessionUUID") as? String
        )
    }

    // MARK: - 전원

    private static func powerSourceAndPercent() -> (PowerSnapshot.PowerSource, Int?) {
        let source: PowerSnapshot.PowerSource
        switch IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? {
        case kIOPSACPowerValue: source = .ac
        case kIOPSBatteryPowerValue: source = .battery
        default: source = .unknown
        }

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (source, nil)
        }

        for entry in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, entry)?.takeUnretainedValue()
                    as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }
            return (source, Int((Double(current) / Double(max) * 100).rounded()))
        }
        return (source, nil)
    }

    // MARK: - 디스플레이

    /// 내장 디스플레이를 제외한 온라인 디스플레이 수.
    private static func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return 0 }

        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    // MARK: - 슬립 차단 프로세스

    public func sleepBlockers() -> [SleepBlocker] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        return byProcess.compactMap { pid, assertions -> SleepBlocker? in
            // 시스템/디스플레이 슬립을 실제로 막는 타입만 센다.
            // 사용자 활동 표시 같은 무해한 assertion 까지 보여주면 노이즈가 된다.
            let types = assertions
                .compactMap { $0[kIOPMAssertionTypeKey] as? String }
                .filter { Self.blockingTypes.contains($0) }
            guard !types.isEmpty else { return nil }

            // assertion 딕셔너리에도 프로세스 이름이 들어있지만 그 키는 공개 SDK 에
            // 없는 SPI 다. 이름 하나 얻자고 SPI 를 늘리지 않는다 — PID 로 조회한다.
            let name = Self.processName(for: pid_t(pid.intValue)) ?? "pid \(pid.intValue)"

            return SleepBlocker(
                pid: pid.intValue,
                processName: name,
                assertionTypes: Array(Set(types)).sorted()
            )
        }
        .sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let written = buffer.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
    }

    /// 이 타입들만 실제로 슬립을 막는다.
    ///
    /// 주의: 이 중 **어느 것도 뚜껑 닫힘(lid close) 슬립은 막지 못한다.**
    /// SDK 26.5 `IOPMLib.h` 가 명시한다 —
    /// "The system may still sleep for lid close, Apple menu, low battery".
    /// 그래서 이 목록은 진단 표시용이지 클램쉘 구현 수단이 아니다. DESIGN.md §1 참조.
    private static let blockingTypes: Set<String> = [
        kIOPMAssertionTypeNoIdleSleep,
        kIOPMAssertionTypeNoDisplaySleep,
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionTypePreventSystemSleep,
    ]
}
