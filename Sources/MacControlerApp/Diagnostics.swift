import AppKit
import ClamshellCore
import OSLog
import SwiftUI

/// 앱 전역 로거. `make logs` 가 이 subsystem 을 구독한다.
///
/// zsh 에서 `log` 는 셸 빌트인이라 `/usr/bin/log` 절대경로를 써야 한다.
enum Log {
    static let launch = Logger(subsystem: "dev.maccontroler.app", category: "launch")
    static let model = Logger(subsystem: "dev.maccontroler.app", category: "model")
}

/// 기동 직후 자기 상태를 로그로 남긴다.
///
/// macOS 26 에서는 상태 아이템이 제어 센터를 통해 합성되어 `CGWindowListCopyWindowInfo`
/// 로는 외부에서 존재를 확인할 수 없다. 그래서 앱이 스스로 보고한다 —
/// `NSStatusBarWindow` 가 자기 윈도우 목록에 있으면 아이템이 실제로 만들어진 것이다.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.releaseOnQuit()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // MenuBarExtra 가 상태 아이템을 붙일 시간을 준다.
            // 아이콘 가시성 판정도 아이템이 자리를 잡은 뒤라야 의미가 있다.
            try? await Task.sleep(for: .milliseconds(600))
            AppModel.shared.start()
            Self.report()
            Log.launch.notice(
                "snapshot=\(String(describing: AppModel.shared.snapshot), privacy: .public)")
            Log.launch.notice(
                "statusItemVisible=\(AppModel.shared.statusItemVisible, privacy: .public) blockers=\(AppModel.shared.blockers.count)")
            Self.probeSPI()
            await Self.probeHelper()
        }
    }

    private static func report() {
        let policy = NSApp.activationPolicy()
        Log.launch.notice("activationPolicy=\(String(describing: policy), privacy: .public)")

        let windows = NSApp.windows.map { String(describing: type(of: $0)) }
        Log.launch.notice("windowCount=\(windows.count) classes=[\(windows.joined(separator: ", "), privacy: .public)]")

        let hasStatusItem = windows.contains { $0.contains("StatusBar") }
        Log.launch.notice("statusItemPresent=\(hasStatusItem, privacy: .public)")

        // 아이템이 "존재하는데 안 보이는" 경우를 가른다:
        // 폭 0 / 화면 밖 좌표 / 버튼 이미지 nil 중 무엇인지.
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            let f = window.frame
            Log.launch.notice(
                "statusWindow frame=(x:\(f.origin.x), y:\(f.origin.y), w:\(f.size.width), h:\(f.size.height)) visible=\(window.isVisible, privacy: .public) alpha=\(window.alphaValue)"
            )
            if let root = window.contentView {
                Log.launch.notice("--- view tree ---")
                dumpTree(root, depth: 0)
            }
        }

        // 심볼 이름이 틀리면 아이콘이 빈칸으로 렌더되고 원인을 찾기 어렵다.
        // 상태에 따라 쓰는 심볼 전부를 기동 시 한 번 확인한다.
        for symbol in ["sun.max.fill", "moon.zzz", "exclamationmark.triangle"] {
            let ok = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
            Log.launch.notice("symbol=\(symbol, privacy: .public) resolves=\(ok, privacy: .public)")
        }
        Log.launch.notice("현재 심볼=\(AppModel.shared.menuBarSymbol, privacy: .public)")

        // 노치가 있는 맥에서는 메뉴바가 노치 좌/우 두 구간으로 쪼개진다.
        // 상태 아이템이 그 사이(노치 아래)에 놓이면 아이템은 정상인데 화면에 안 보인다.
        if let screen = NSScreen.main {
            Log.launch.notice("screen frame=\(String(describing: screen.frame), privacy: .public)")
            Log.launch.notice("safeAreaInsets=\(String(describing: screen.safeAreaInsets), privacy: .public)")
            Log.launch.notice("auxTopLeft=\(String(describing: screen.auxiliaryTopLeftArea), privacy: .public)")
            Log.launch.notice("auxTopRight=\(String(describing: screen.auxiliaryTopRightArea), privacy: .public)")
        }
    }

    /// SPI 링크를 확인한다. **읽기만 한다.**
    ///
    /// 예전에는 여기서 "같은 값 쓰기"를 시도해 `kIOReturnNotPrivileged` 를 확인했다.
    /// 그러나 앱에서 SPI 쓰기를 부르는 것 자체가 규칙 위반이고, 하필 그 '같은 값'을
    /// 커널 실적용값에서 읽고 있었다 — 커널과 디스크가 갈라진 상태에서는 같은 값이
    /// 아니다. 앱이 권한 상승된 채 실행되면 기동만으로 영구 설정을 덮어쓴다.
    /// 링크 증명은 읽기만으로 충분하다.
    private static func probeSPI() {
        let desired = SystemPowerSettings.readDesiredSleepDisabled()
        Log.launch.notice(
            "SPI 읽기: 디스크 희망값=\(String(describing: desired), privacy: .public) 키=\(SystemPowerSettings.readAll().keys.sorted().joined(separator: ","), privacy: .public)")
    }

    /// 헬퍼가 살아있고 XPC 로 응답하는지 확인한다.
    ///
    /// Phase 2 의 첫 관문이다 — `XPCListener(service:)` 가 launchd 의 `MachServices`
    /// 항목에 실제로 바인딩되는지가 여기서 갈린다. 실패하면 폴백은
    /// `NSXPCListener(machServiceName:)` 다. DESIGN.md §8 참조.
    /// 일회용 컨트롤러를 만들지 않는다 — 세션을 들고 있는 객체를 만들었다 버리면
    /// cancel 타이밍이 꼬인다. 모델이 들고 있는 하나를 쓴다.
    private static func probeHelper() async {
        await AppModel.shared.syncHelperStatus()
        if let status = AppModel.shared.helperStatus {
            Log.launch.notice("헬퍼 응답: \(String(describing: status), privacy: .public)")
        } else {
            Log.launch.error(
                "헬퍼 미연결: \(AppModel.shared.lastMessage ?? "사유 없음", privacy: .public)")
        }
    }

    /// 상태 아이템 안에서 실제로 무엇이 그려지고 있는지 본다.
    /// 프레임이 0 이거나 이미지가 nil 인 노드를 찾는 것이 목적이다.
    private static func dumpTree(_ view: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let f = view.frame
        var detail = ""
        if let button = view as? NSButton {
            detail = " image=\(button.image?.name() ?? "<이름없음>") imgSize=\(button.image?.size.debugDescription ?? "-") title='\(button.title)'"
            // .menu 스타일은 실제 NSMenu 를 붙인다. 클릭하지 않고도 항목을 읽어 확인한다.
            if let menu = button.menu {
                let titles = menu.items.map { $0.isSeparatorItem ? "<구분선>" : $0.title }
                detail += " menuItems=[\(titles.joined(separator: " | "))]"
            } else {
                detail += " menu=nil"
            }
        } else if let imageView = view as? NSImageView {
            detail = " image=\(imageView.image?.name() ?? "nil") imgSize=\(imageView.image?.size.debugDescription ?? "-")"
        }
        Log.launch.notice(
            "\(pad, privacy: .public)\(String(describing: type(of: view)), privacy: .public) frame=(\(f.origin.x),\(f.origin.y),\(f.size.width),\(f.size.height)) hidden=\(view.isHidden, privacy: .public) alpha=\(view.alphaValue)\(detail, privacy: .public)"
        )
        for sub in view.subviews { dumpTree(sub, depth: depth + 1) }
    }
}
