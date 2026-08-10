import Foundation

/// 어느 한 순간의 전원·뚜껑·디스플레이 상태.
///
/// 전부 root 없이 읽을 수 있는 값들이다. 실제 읽기는 `PowerStateReading` 구현체가 하고,
/// 판단은 `ClamshellPolicy` 가 한다 — 그래야 판단 로직을 시스템 없이 테스트할 수 있다.
public struct PowerSnapshot: Sendable, Equatable {

    public enum PowerSource: Sendable, Equatable {
        case ac
        case battery
        case unknown
    }

    /// `AppleClamshellState` — 뚜껑이 닫혀 있는가.
    public var lidClosed: Bool

    /// `AppleClamshellCausesSleep` — 지금 뚜껑을 닫으면 자는 조건인가.
    ///
    /// `sleepDisabled` 와 **독립**이다. 이 값만 보고 판단하면 오답이 나온다.
    public var clamshellCausesSleep: Bool

    /// `IOPMrootDomain` 의 `SleepDisabled` — 커널에 실제로 반영된 값.
    ///
    /// 디스크에 저장된 희망값(`desiredSleepDisabled`)과 다를 수 있다.
    /// powerd 를 거쳐 비동기로 반영되기 때문이다.
    public var sleepDisabled: Bool

    /// `IOPMCopySystemPowerSettings()` 의 `SleepDisabled` — **디스크에 저장된 희망값.**
    ///
    /// 이쪽이 영구 저장되는 값이고, powerd 가 부팅 때마다 커널에 다시 밀어넣는다.
    /// 따라서 **되돌리기의 진짜 대상은 커널값이 아니라 이 값이다.**
    /// 커널값만 보고 "이미 원하는 상태"라고 판단하면, 디스크에 남은 값이
    /// 나중에 되살아나 맥이 영영 안 자게 된다.
    ///
    /// 키가 없으면 nil (아직 한 번도 설정된 적 없음).
    public var desiredSleepDisabled: Bool?

    public var powerSource: PowerSource

    /// 배터리 잔량 %. 배터리가 없거나 읽지 못하면 nil.
    public var batteryPercent: Int?

    /// 내장 디스플레이를 제외한 온라인 디스플레이 수.
    ///
    /// 1 이상이면 그래픽스가 이미 클램쉘 슬립을 꺼둔 상태라 개입할 이유가 없다.
    public var externalDisplayCount: Int

    /// `BootSessionUUID`. 재부팅을 건너뛴 상태 복원을 감지하는 데 쓴다(Phase 2).
    public var bootSessionUUID: String?

    public init(
        lidClosed: Bool,
        clamshellCausesSleep: Bool,
        sleepDisabled: Bool,
        desiredSleepDisabled: Bool?,
        powerSource: PowerSource,
        batteryPercent: Int?,
        externalDisplayCount: Int,
        bootSessionUUID: String?
    ) {
        self.lidClosed = lidClosed
        self.clamshellCausesSleep = clamshellCausesSleep
        self.sleepDisabled = sleepDisabled
        self.desiredSleepDisabled = desiredSleepDisabled
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.externalDisplayCount = externalDisplayCount
        self.bootSessionUUID = bootSessionUUID
    }
}
