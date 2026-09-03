import Foundation
import HelperProtocol
import Testing

@testable import ClamshellCore

/// 설정 저장소의 관심사는 "잘못됐을 때 어느 쪽으로 떨어지는가" 하나다.
@Suite("설정 저장소")
struct PolicySettingsStoreTests {

    /// 테스트마다 격리된 도메인을 쓴다. `.standard` 를 건드리면 실제 앱 설정이 바뀐다.
    private func makeDefaults() -> UserDefaults {
        let suite = "mc-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("고른 값이 그대로 돌아온다", arguments: AutoReleaseLimit.presets)
    func roundTrip(_ limit: AutoReleaseLimit) {
        let defaults = makeDefaults()
        PolicySettingsStore.save(PolicySettings(autoRelease: limit), to: defaults)
        #expect(PolicySettingsStore.load(from: defaults).autoRelease == limit)
    }

    @Test("저장된 적이 없으면 기본값이다")
    func emptyDefaultsGiveDefault() {
        #expect(PolicySettingsStore.load(from: makeDefaults()).autoRelease == .default)
    }

    /// 깨진 값을 '꺼짐' 으로 읽으면 사용자가 고른 적 없는 무제한이 걸린다.
    @Test(
        "★ 깨진 값은 '꺼짐' 이 아니라 기본값으로 떨어진다",
        arguments: ["", "abc", "-1", "0", "1.5", "NEVER"]
    )
    func corruptValueFallsBackToDefault(_ raw: String) {
        let defaults = makeDefaults()
        defaults.set(raw, forKey: PolicySettingsStore.autoReleaseKey)
        #expect(PolicySettingsStore.load(from: defaults).autoRelease == .default)
    }

    /// `UserDefaults.string(forKey:)` 는 NSNumber 를 문자열로 강제 변환한다.
    /// 그래서 `defaults write ... -int 3600` 은 1시간으로 읽힌다 — 유효한 초 값이므로
    /// 그대로 두는 것이 맞다. 문제는 그게 아니라 **무제한으로 새는 경로**다.
    @Test("숫자로 써 넣은 값은 그 초 수로 읽힌다")
    func numericValueIsCoercedToSeconds() {
        let defaults = makeDefaults()
        defaults.set(3600, forKey: PolicySettingsStore.autoReleaseKey)
        #expect(PolicySettingsStore.load(from: defaults).autoRelease == .after(seconds: 3600))
    }

    @Test("문자열로 읽을 수 없는 값은 기본값으로 떨어진다")
    func unreadableValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set([1, 2, 3], forKey: PolicySettingsStore.autoReleaseKey)
        #expect(PolicySettingsStore.load(from: defaults).autoRelease == .default)
    }

    /// 이 스위트에서 하나만 남긴다면 이것이다.
    /// 어떤 쓰레기가 들어 있어도 '꺼짐' 으로는 절대 떨어지지 않아야 한다 —
    /// '꺼짐' 은 사용자가 명시적으로 고를 때만 걸리는 값이다.
    @Test(
        "★ 어떤 쓰레기 값도 '꺼짐' 으로 해석되지 않는다",
        arguments: ["", " ", "abc", "-1", "0", "1.5", "NEVER", "Never", "never!", "nil", "null"]
    )
    func garbageNeverBecomesNever(_ raw: String) {
        let defaults = makeDefaults()
        defaults.set(raw, forKey: PolicySettingsStore.autoReleaseKey)
        #expect(PolicySettingsStore.load(from: defaults).autoRelease != .never,
                "'\(raw)' 가 무제한으로 새면 사용자가 고른 적 없는 상태가 걸린다")
    }

    @Test("배터리 임계는 아직 저장 대상이 아니다 — 기본값 15% 로 고정")
    func batteryThresholdIsFixed() {
        let defaults = makeDefaults()
        PolicySettingsStore.save(PolicySettings(autoRelease: .never), to: defaults)
        #expect(PolicySettingsStore.load(from: defaults).batteryThresholdPercent == 15)
    }
}
