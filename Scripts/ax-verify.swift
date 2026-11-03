// 메뉴바 아이템을 접근성 API 로 직접 눌러 메뉴 내용을 검증한다.
//
// 왜 이게 필요한가: 노치 있는 맥에서 상태 아이템이 노치 아래에 놓이면 눈으로도
// 좌표 클릭으로도 접근할 수 없다. AX API 는 화면 위치와 무관하게 동작하므로
// 아이콘이 보이든 말든 "클릭하면 메뉴가 펼쳐지는가" 를 검증할 수 있다.
//
// 사용법: swift Scripts/ax-verify.swift <pid> [눌러야 할 메뉴 항목 제목]
//   제목을 주면 해당 항목까지 눌러본다. 안 주면 메뉴 항목을 나열만 한다.

import ApplicationServices
import Foundation

guard AXIsProcessTrusted() else {
    print("❌ 손쉬운 사용 권한 없음. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용")
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else {
    print("사용법: swift ax-verify.swift <pid> [항목제목]")
    exit(64)
}
// 빈 문자열은 "항목 지정 안 함"으로 본다 — Makefile 이 ITEM 미지정 시 "" 를 넘긴다.
let targetTitle: String? = args.count >= 3 && !args[2].isEmpty ? args[2] : nil

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func title(_ element: AXUIElement) -> String {
    (attr(element, kAXTitleAttribute as String) as? String) ?? ""
}

func role(_ element: AXUIElement) -> String {
    (attr(element, kAXRoleAttribute as String) as? String) ?? "?"
}

let app = AXUIElementCreateApplication(pid)

// 상태 아이템은 일반 메뉴바가 아니라 "extras" 메뉴바에 산다.
guard let extras = attr(app, "AXExtrasMenuBar") else {
    print("❌ AXExtrasMenuBar 없음 — 상태 아이템이 접근성 트리에 노출되지 않음")
    exit(1)
}
let extrasBar = extras as! AXUIElement
let items = children(extrasBar)
print("상태 아이템 \(items.count)개")
guard let item = items.first else {
    print("❌ 상태 아이템이 비어 있음")
    exit(1)
}
print("  role=\(role(item)) title='\(title(item))'")

func actions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

// 아이템마다 지원 액션이 다르다. AXPress 가 없으면 AXShowMenu 를 쓴다.
let supported = actions(item)
print("  지원 액션: \(supported.isEmpty ? "(없음)" : supported.joined(separator: ", "))")

/// 지금 메뉴가 열려 있으면 그 메뉴를 돌려준다.
func openMenu() -> AXUIElement? {
    children(item).first { role($0) == kAXMenuRole as String }
}

// ⚠️ AXPress 의 반환값을 신뢰하지 않는다.
//
// 이 API 는 직전 메뉴 트래킹이 정리되기 전에 부르면 -25204 를 내는데,
// **실제로는 메뉴가 열린 상태에서도 실패를 반환한다.** 그것을 실패로 보고
// 재시도하면 두 번째 프레스가 이미 열린 메뉴로 들어가 의도치 않은 항목이
// 활성화될 수 있다 — 2026-08-06 에 목록만 읽었는데 engage 가 걸린 사건의
// 가장 유력한 원인이다. 그래서 반환값이 아니라 "메뉴가 열렸는가"로 판정한다.
let candidates = [kAXPressAction as String, "AXShowMenu", "AXOpen", "AXPick"]
var menu: AXUIElement?

for attempt in 1...5 {
    if let already = openMenu() { menu = already; break }

    var attempted = false
    for action in candidates where supported.contains(action) {
        _ = AXUIElementPerformAction(item, action as CFString)
        attempted = true
        break  // 한 번에 하나만. 연달아 누르는 것이 바로 위험한 동작이다.
    }
    guard attempted else { break }

    Thread.sleep(forTimeInterval: 0.4)
    if let opened = openMenu() {
        menu = opened
        print("  메뉴 열림 (\(attempt)회차)")
        break
    }
}

guard let menu else {
    print("❌ 메뉴를 열지 못함 (지원 액션: \(supported.joined(separator: ", ")))")
    exit(1)
}

// 메뉴가 뜨는 데 시간이 걸린다.
let entries = children(menu)
print("메뉴 항목 \(entries.count)개:")
for entry in entries {
    let t = title(entry)
    print("  - [\(role(entry))] '\(t.isEmpty ? "<구분선>" : t)'")
}

if let wanted = targetTitle {
    guard let hit = entries.first(where: { title($0) == wanted }) else {
        print("❌ '\(wanted)' 항목을 찾지 못함")
        exit(1)
    }
    let r = AXUIElementPerformAction(hit, kAXPressAction as CFString)
    print("'\(wanted)' press: \(r == .success ? "성공" : "실패(\(r.rawValue))")")
} else {
    // 메뉴를 열어둔 채 끝내면 화면에 남는다. 닫는다.
    AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    print("(메뉴 닫음)")
}
