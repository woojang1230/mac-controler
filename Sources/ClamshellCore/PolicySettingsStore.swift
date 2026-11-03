import Foundation
import HelperProtocol

/// 사용자가 고른 설정을 `UserDefaults` 에 남긴다.
///
/// 앱 타깃이 아니라 여기 있는 이유는 하나다 — **테스트할 수 있어야 해서다.**
/// 저장된 값을 못 읽었을 때 어느 쪽으로 떨어지느냐가 안전에 직결된다.
public enum PolicySettingsStore {

    /// `defaults read dev.maccontroler.app autoReleaseLimit` 로 눈으로 확인할 수 있다.
    public static let autoReleaseKey = "autoReleaseLimit"

    /// 저장된 설정을 읽는다.
    ///
    /// **읽기에 실패하면 반드시 기본값(4시간)으로 떨어진다.** 깨진 값이나 없는 값을
    /// '꺼짐' 으로 해석하면 사용자가 고른 적 없는 무제한이 조용히 걸린다.
    /// `AutoReleaseLimit` 를 `TimeInterval?` 로 두지 않은 것도 같은 이유다.
    public static func load(from defaults: UserDefaults = .standard) -> PolicySettings {
        var settings = PolicySettings()
        if let raw = defaults.string(forKey: autoReleaseKey),
           let limit = AutoReleaseLimit(rawValue: raw) {
            settings.autoRelease = limit
        }
        return settings
    }

    public static func save(_ settings: PolicySettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.autoRelease.rawValue, forKey: autoReleaseKey)
    }
}
