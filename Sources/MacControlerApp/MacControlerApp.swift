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
    }
}
