import SwiftUI

/// 메뉴바 아이템 하나를 담는 Scene.
///
/// `.menu` 스타일은 실제 NSMenu 로 렌더되므로 Toggle 이 체크마크 항목에
/// 그대로 매핑되고 위치·키보드 탐색을 시스템이 처리한다.
/// `.window` 를 쓰지 않는 이유는 팝오버를 프로그램적으로 닫을 수 없는
/// 미해결 결함(FB11984872) 때문이다. DESIGN.md §2 참조.
///
/// 모델을 App 이 아니라 여기서 받아 다시 View 로 넘긴다 — App 구조체가 상태를
/// 직접 들면 콘텐츠에 전파되지 않는 버그(포럼 720625)를 피하기 위한 구조다.
struct MenuBarScene: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
