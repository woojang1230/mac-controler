import CoreGraphics
import Foundation
import HelperProtocol

/// 사용자가 바꿀 수 있는 안전 임계값.
///
/// 기본값은 확정된 제품 결정에서 나왔다 — 배터리에서 "경고 후 허용",
/// 15% 자동 해제, 4시간 절대 타임아웃. DESIGN.md §0 참조.
///
/// 시간 상한은 설정 창에서 바꿀 수 있고 '꺼짐' 도 고를 수 있다.
/// 배터리 임계는 아직 고정이다 — 방전은 되돌릴 수 없는 손실이라
/// 시간 상한과 같은 급으로 다루지 않는다.
public struct PolicySettings: Sendable, Equatable {
    public var batteryThresholdPercent: Int
    public var autoRelease: AutoReleaseLimit

    public init(
        batteryThresholdPercent: Int = 15,
        autoRelease: AutoReleaseLimit = .default
    ) {
        self.batteryThresholdPercent = batteryThresholdPercent
        self.autoRelease = autoRelease
    }
}

extension AutoReleaseLimit {
    /// 설정 창과 메뉴에 그대로 나가는 이름.
    public var displayName: String {
        guard case .after = self else { return "꺼짐" }

        // `rawValue` 가 이미 유한 범위로 접은 값이다. 여기서 `Int(Double)` 을
        // 다시 하면 접기 전 값에 닿아 트랩할 수 있다. 접는 곳은 한 군데뿐이어야 한다.
        let total = Int(rawValue) ?? 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)시간") }
        if minutes > 0 { parts.append("\(minutes)분") }
        // 초는 프리셋에 없지만, 값이 어디서 오든 빈 문자열이 되면 안 된다.
        if rest > 0 || parts.isEmpty { parts.append("\(rest)초") }
        return parts.joined(separator: " ")
    }

    /// 설정 창 Picker 가 보여줄 선택지.
    ///
    /// 프리셋 밖의 값이 저장돼 있을 수 있다 — `defaults write` 로 넣거나
    /// 프리셋 목록이 나중에 바뀌면 그렇다. 그 값을 목록에 넣지 않으면
    /// Picker 가 어느 태그와도 안 맞아 **빈칸**이 되고, 사용자는 현재 설정이
    /// 무엇인지 화면에서 알 수 없게 된다.
    public static func choices(including current: AutoReleaseLimit) -> [AutoReleaseLimit] {
        guard !presets.contains(current) else { return presets }
        guard case .after(let seconds) = current else { return presets }

        // 짧은 것부터 정렬된 자리에 끼워 넣는다. `never` 는 항상 마지막이다.
        let index = presets.firstIndex { preset in
            guard case .after(let other) = preset else { return true }
            return other > seconds
        } ?? presets.count
        var all = presets
        all.insert(current, at: index)
        return all
    }
}

/// 시스템을 건드리지 않는 순수 판단 로직. 테스트의 대부분이 여기에 걸린다.
///
/// **정책 판단은 전부 여기(비특권 앱 쪽)에 있다.** root 헬퍼는 판단하지 않고
/// 값 하나를 켜고 되돌리는 일만 한다 — 헬퍼의 노출 면적이 곧 공격 표면이라서다.
public enum ClamshellPolicy {

    /// 토글을 켜달라는 요청에 대한 답.
    public enum Decision: Sendable, Equatable {
        /// 바로 켠다.
        case engage
        /// 켤 이유가 없다. 시스템을 건드리지 않는다.
        case unnecessary(reason: String)
        /// 위험해서 거부한다.
        case refused(reason: String)
        /// 확인을 받고 켠다.
        case needsConfirmation(reason: String)
    }

    /// engage 중인 상태를 자동으로 풀어야 하는 이유.
    public enum AutoReleaseReason: Sendable, Equatable {
        case lowBattery
        case timeout
    }

    /// 켜달라는 요청을 어떻게 처리할지 정한다.
    public static func decide(
        _ snapshot: PowerSnapshot,
        settings: PolicySettings
    ) -> Decision {
        // 외부 디스플레이는 거부의 확실한 근거다 — 커널이 보증한다.
        // 그래픽스가 `clamshellDisabled` 를 세워 클램쉘 슬립 자체를 끈다.
        if snapshot.externalDisplayCount > 0 {
            return .unnecessary(reason: "외부 디스플레이가 연결되어 있어 이미 잠들지 않습니다")
        }

        // 이미 슬립이 차단돼 있으면(우리가 켰든 남이 켰든) 덧씌울 이유가 없다.
        if snapshot.sleepDisabled {
            return .unnecessary(reason: "슬립 차단이 이미 켜져 있습니다")
        }

        // ⚠️ `AppleClamshellCausesSleep == false` 만으로는 거부하지 않는다.
        //
        // 이 값은 신뢰할 수 없다. 2026-08-06 실측: 뚜껑을 닫았을 때 실제로는
        // Deep Idle 로 들어갔는데(`pmset -g log` 의 "Wake from Deep Idle …
        // DriverReason:lid") 그 뒤로도 이 값이 계속 `No` 로 남아 있었다.
        // 뚜껑을 여닫은 뒤 powerd 가 거는 `com.apple.powermanagement.lidopen`
        // assertion 과 얽혀 있는 것으로 보이나 정확한 조건은 규명하지 못했다.
        //
        // 이것만 보고 거부하면 사용자가 정말 필요할 때 토글이 먹지 않는다.
        // 잘못 켜는 비용(되돌릴 수 있고 워치독이 지킨다)보다
        // 잘못 거부하는 비용(요청했는데 맥이 잔다)이 훨씬 크다.
        // 표시(`isAwakeOnLidClose`)에는 계속 쓰되, 판단 근거로는 쓰지 않는다.
        guard snapshot.powerSource == .battery else {
            return .engage
        }
        if let percent = snapshot.batteryPercent, percent < settings.batteryThresholdPercent {
            return .refused(
                reason: "배터리가 \(percent)% 입니다. \(settings.batteryThresholdPercent)% 미만에서는 켤 수 없습니다")
        }
        // 배터리에서도 켤 수 있게 하되, 방전 위험을 알린 뒤에만 켠다.
        return .needsConfirmation(
            reason: "배터리 전원입니다. 뚜껑을 닫은 채 두면 방전될 수 있습니다"
                + " (\(settings.batteryThresholdPercent)% 도달 시 자동 해제)")
    }

    /// engage 중인 상태를 지금 풀어야 하는가.
    ///
    /// 잔량을 읽지 못했을 때(nil) 배터리 이유로 해제하지 않는다 —
    /// 읽기 실패를 위험 신호로 오인하면 멀쩡한 상태를 계속 끊어먹는다.
    public static func autoReleaseReason(
        _ snapshot: PowerSnapshot,
        engagedAt: Date,
        now: Date,
        settings: PolicySettings
    ) -> AutoReleaseReason? {
        if snapshot.powerSource == .battery,
           let percent = snapshot.batteryPercent,
           percent < settings.batteryThresholdPercent {
            return .lowBattery
        }
        // '꺼짐' 이면 시간으로는 풀지 않는다. 배터리 규칙은 위에서 이미 걸렀다 —
        // 순서가 중요하다. 시간 검사를 먼저 두고 early return 하면 '꺼짐' 이
        // 배터리 규칙까지 건너뛰게 만들기 쉽다.
        if case .after(let seconds) = settings.autoRelease,
           now.timeIntervalSince(engagedAt) > seconds {
            return .timeout
        }
        return nil
    }

    /// 지금 뚜껑을 닫아도 맥이 깨어 있는가.
    ///
    /// 두 값의 OR 이다. `AppleClamshellCausesSleep` 만 보면 오답이 나온다 —
    /// 그 값이 `true` 여도 `SleepDisabled` 가 켜져 있으면 자지 않는다.
    /// 커널이 `checkSystemSleepAllowed()` 에서 `userDisabledAllSleep` 을
    /// 뚜껑 닫힘 판정보다 먼저 검사하기 때문이다. DESIGN.md §1 참조.
    public static func isAwakeOnLidClose(_ snapshot: PowerSnapshot) -> Bool {
        !snapshot.clamshellCausesSleep || snapshot.sleepDisabled
    }

    /// 클램쉘을 유지하려면 우리가 개입해야 하는가.
    ///
    /// 불필요한 개입을 피하는 것이 핵심이다. `SleepDisabled` 는 시스템 전역
    /// 킬스위치라서, 이미 안 자는 상황에 켜면 얻는 것 없이 위험만 늘린다.
    public static func isEngagementNeeded(_ snapshot: PowerSnapshot) -> Bool {
        // 외부 디스플레이가 붙어 있으면 그래픽스가 이미 클램쉘 슬립을 꺼둔 상태다.
        guard snapshot.externalDisplayCount == 0 else { return false }
        return !isAwakeOnLidClose(snapshot)
    }

    /// "헬퍼는 아직 옛 상한으로 동작 중" 경고를 띄워야 하는가.
    ///
    /// 이 경고의 목적은 **수렴하지 않는 괴리**를 알리는 것이다. 설정 창에서 값을
    /// 바꾸면 앱 설정은 즉시 바뀌고 헬퍼 응답은 왕복 뒤에 온다(실측 33밀리초).
    /// 그 사이를 괴리로 치면 값을 바꿀 때마다 경고가 깜빡였다 사라진다 —
    /// 알림이 아니라 노이즈다. 그래서 **왕복이 끝난 뒤에도** 갈라져 있을 때만 띄운다.
    ///
    /// 헬퍼 상한을 모르는 경우(nil)도 띄우지 않는다. engage 중이 아니거나 XPC 가
    /// 실패한 상태이고, 둘 다 "상한이 어긋났다" 와는 다른 이야기다.
    /// XPC 실패는 `lastMessage` 가 따로 알린다.
    public static func shouldWarnLimitMismatch(
        appLimit: AutoReleaseLimit,
        helperLimit: AutoReleaseLimit?,
        isSyncing: Bool
    ) -> Bool {
        guard !isSyncing, let helperLimit else { return false }
        return helperLimit != appLimit
    }

    /// 메뉴바 아이템이 사용자 눈에 보이는 자리에 있는가.
    ///
    /// 노치가 있는 맥에서 메뉴바는 노치 좌/우 두 구간으로 쪼개진다
    /// (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`).
    /// 아이템이 어느 구간에도 **온전히** 들어가지 않으면 노치에 가리거나
    /// 화면 밖에 있는 것이다. 경계를 걸친 경우도 잘려 보이므로 안 보이는 것으로 친다.
    ///
    /// 아이템 위치는 macOS 가 정하며 앱이 지정할 수 있는 API 는 없다.
    /// 그래서 "고칠" 수는 없고, 감지해서 사용자에게 알리는 것이 최선이다.
    public static func isStatusItemVisible(_ frame: CGRect, areas: [CGRect]) -> Bool {
        areas.contains { $0.contains(frame) }
    }
}
