import HelperProtocol
import Testing

@testable import ClamshellCore

/// 값을 바꿀 때마다 경고가 깜빡였다 사라지는 문제를 못박는다.
///
/// 경고가 뜨는 조건이 "두 값이 다르다" 뿐이면, 왕복 중인 33밀리초 동안 반드시
/// 다르므로 매번 깜빡인다. 뜨려면 뜨고 말려면 말아야 한다.
@Suite("상한 불일치 경고")
struct LimitMismatchWarningTests {

    @Test("★ 헬퍼로 보내는 중이면 아직 알리지 않는다")
    func silentWhileSyncing() {
        // 사용자가 방금 '꺼짐' 을 골랐고 헬퍼는 아직 4시간을 들고 있다.
        // 이건 괴리가 아니라 진행 중인 왕복이다.
        #expect(
            ClamshellPolicy.shouldWarnLimitMismatch(
                appLimit: .never, helperLimit: .default, isSyncing: true) == false)
    }

    @Test("★ 왕복이 끝났는데도 갈라져 있으면 알린다")
    func warnsAfterSyncSettles() {
        // 헬퍼가 디스크 쓰기에 실패해 옛 값을 유지한 경우가 여기다.
        #expect(
            ClamshellPolicy.shouldWarnLimitMismatch(
                appLimit: .never, helperLimit: .default, isSyncing: false) == true)
    }

    @Test("값이 같으면 알리지 않는다", arguments: [true, false])
    func silentWhenEqual(_ syncing: Bool) {
        #expect(
            ClamshellPolicy.shouldWarnLimitMismatch(
                appLimit: .default, helperLimit: .default, isSyncing: syncing) == false)
    }

    /// engage 중이 아니거나 XPC 가 실패한 상태다. 둘 다 "상한이 어긋났다" 와 다르다.
    @Test("헬퍼 상한을 모르면 알리지 않는다", arguments: [true, false])
    func silentWhenHelperLimitUnknown(_ syncing: Bool) {
        #expect(
            ClamshellPolicy.shouldWarnLimitMismatch(
                appLimit: .never, helperLimit: nil, isSyncing: syncing) == false)
    }

    @Test("모든 프리셋 조합에서 같으면 조용하고 다르면 알린다")
    func exhaustivePairs() {
        for app in AutoReleaseLimit.presets {
            for helper in AutoReleaseLimit.presets {
                let warn = ClamshellPolicy.shouldWarnLimitMismatch(
                    appLimit: app, helperLimit: helper, isSyncing: false)
                #expect(warn == (app != helper), "\(app.displayName) vs \(helper.displayName)")
            }
        }
    }
}
