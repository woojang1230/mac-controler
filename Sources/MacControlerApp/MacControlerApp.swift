import SwiftUI

/// 메뉴바 상주 앱의 진입점.
///
/// Scene 본체를 `MenuBarScene` 으로 빼둔 것은 취향이 아니라 회피책이다.
/// App 구조체가 상태를 직접 들고 있으면 그 변화가 MenuBarExtra 콘텐츠로
/// 전파되지 않는 알려진 버그가 있다(Apple 개발자 포럼 720625).
/// DESIGN.md §2 참조.
@main
struct MacControlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarScene(model: .shared)

        // 옵션 창. `.menu` 스타일 MenuBarExtra 안에서는 `SettingsLink` 가
        // 이 Scene 을 여는 유일한 정식 경로다 — 메뉴 항목에서 창을 띄우는
        // 다른 방법들은 전부 비공개 셀렉터에 기댄다.
        Settings {
            SettingsView(model: .shared)
        }
    }
}
