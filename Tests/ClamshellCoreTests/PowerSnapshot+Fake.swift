import ClamshellCore

extension PowerSnapshot {
    /// 관심 있는 필드만 지정하고 나머지는 무해한 기본값으로 채운다.
    static func fake(
        lidClosed: Bool = false,
        clamshellCausesSleep: Bool = true,
        sleepDisabled: Bool = false,
        desiredSleepDisabled: Bool? = nil,
        powerSource: PowerSource = .ac,
        batteryPercent: Int? = 100,
        externalDisplayCount: Int = 0,
        bootSessionUUID: String? = "TEST-SESSION"
    ) -> PowerSnapshot {
        PowerSnapshot(
            lidClosed: lidClosed,
            clamshellCausesSleep: clamshellCausesSleep,
            sleepDisabled: sleepDisabled,
            desiredSleepDisabled: desiredSleepDisabled ?? sleepDisabled,
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            externalDisplayCount: externalDisplayCount,
            bootSessionUUID: bootSessionUUID
        )
    }
}
