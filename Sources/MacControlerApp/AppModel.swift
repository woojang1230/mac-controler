import AppKit
import ClamshellCore
import HelperProtocol
import Observation

/// 앱의 단일 진실 소스.
///
/// 값은 **푸시로만** 들어온다 — `.menu` 스타일 MenuBarExtra 에는 메뉴 열림 훅이
/// 없어서(SDK 26.5 전수 확인: `isPresented`/`onOpen` 부재) 열릴 때 조회하는
/// pull 설계가 성립하지 않는다. DESIGN.md §2 참조.
///
/// Phase 1 에서는 읽기만 한다. 시스템을 전혀 바꾸지 않는다.
@Observable
final class AppModel {

    /// 앱 전체에서 하나만 쓴다. `AppDelegate` 가 기동 시 `start()` 를 부르고
    /// Scene/View 는 이 인스턴스를 명시적으로 주입받는다.
    static let shared = AppModel()

    private(set) var snapshot: PowerSnapshot
    private(set) var blockers: [SleepBlocker] = []

    /// 메뉴바 아이콘이 사용자 눈에 보이는가.
    ///
    /// 노치에 가리거나 Hidden Bar 류가 화면 밖으로 밀어내면 false 다.
    /// 이 경우 앱이 살아있어도 사용자는 "아무것도 안 뜬다"고 느낀다.
    private(set) var statusItemVisible = true

    /// 헬퍼가 보고한 마지막 상태. 헬퍼가 없으면 nil.
    private(set) var helperStatus: HelperStatus?

    /// 사용자에게 보여줄 마지막 실패/거부 사유.
    private(set) var lastMessage: String?

    var settings = PolicySettings()

    private let reader: any PowerStateReading
    @ObservationIgnored private var observer: PowerStateObserver?
    @ObservationIgnored private let helper = XPCSleepController()
    @ObservationIgnored private var engagedAt: Date?
    @ObservationIgnored private var heartbeatTimer: Timer?

    init(reader: any PowerStateReading = IOKitPowerStateReader()) {
        self.reader = reader
        self.snapshot = reader.snapshot()
    }

    func start() {
        observer = PowerStateObserver { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        observer?.start()
        refresh()
        Task { await syncHelperStatus() }
    }

    // MARK: - 토글

    /// 우리가 슬립 차단을 걸고 있는가. 헬퍼가 판단 근거다.
    var engagedByUs: Bool { helperStatus?.engagedByUs ?? false }

    func setEngaged(_ on: Bool) {
        Task { await performToggle(on) }
    }

    private func performToggle(_ on: Bool) async {
        guard on else {
            await send(.release)
            stopHeartbeat()
            engagedAt = nil
            return
        }

        switch ClamshellPolicy.decide(snapshot, settings: settings) {
        case .unnecessary(let reason), .refused(let reason):
            // 시스템을 건드리지 않는다. 이유만 알린다.
            lastMessage = reason
            Log.model.notice("engage 안 함: \(reason, privacy: .public)")
            return

        case .needsConfirmation(let reason):
            guard confirm(reason) else {
                lastMessage = "사용자가 취소했습니다"
                return
            }

        case .engage:
            break
        }

        guard let session = snapshot.bootSessionUUID else {
            lastMessage = "부팅 세션을 읽지 못해 안전하게 켤 수 없습니다"
            return
        }
        await send(.engage(bootSessionUUID: session))
        if engagedByUs {
            engagedAt = Date()
            startHeartbeat()
        }
    }

    private func confirm(_ reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "배터리 전원에서 슬립을 차단할까요?"
        alert.informativeText = reason
            + "\n\n참고: 이 설정은 뚜껑 닫힘뿐 아니라 유휴 슬립과 Apple 메뉴 > 잠자기까지 전부 막습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "켜기")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 헬퍼 통신

    @discardableResult
    private func send(_ request: HelperRequest) async -> Bool {
        let helper = self.helper
        do {
            let reply = try await Task.detached { try helper.send(request) }.value
            apply(reply)
            return true
        } catch {
            helperStatus = nil
            lastMessage = error.localizedDescription
            Log.model.error("헬퍼 요청 실패: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func apply(_ reply: HelperReply) {
        switch reply {
        case .applied(let status), .alreadyInDesiredState(let status), .status(let status):
            helperStatus = status
            lastMessage = nil
        case .notConfirmed(let status):
            helperStatus = status
            lastMessage = "설정은 보냈으나 커널 반영을 확인하지 못했습니다"
        case .denied(let reason):
            lastMessage = reason
        }
        refresh()
    }

    func syncHelperStatus() async {
        await send(.status)
    }

    // MARK: - 하트비트와 자동 해제

    /// 앱이 살아있음을 헬퍼에 알린다. 끊기면 헬퍼가 baseline 으로 되돌린다.
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: HelperConstants.heartbeatInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.beat() }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func beat() async {
        refresh()

        // 하트비트를 보내기 전에 스스로 풀어야 할 이유가 없는지 본다.
        if let engagedAt,
           let reason = ClamshellPolicy.autoReleaseReason(
               snapshot, engagedAt: engagedAt, now: Date(), settings: settings) {
            Log.model.notice("자동 해제: \(String(describing: reason), privacy: .public)")
            await send(.release)
            stopHeartbeat()
            self.engagedAt = nil
            notifyAutoRelease(reason)
            return
        }
        await send(.heartbeat)
    }

    private func notifyAutoRelease(_ reason: ClamshellPolicy.AutoReleaseReason) {
        let alert = NSAlert()
        alert.messageText = "슬립 차단을 자동으로 해제했습니다"
        alert.informativeText = switch reason {
        case .lowBattery: "배터리가 \(settings.batteryThresholdPercent)% 아래로 떨어졌습니다."
        case .timeout: "설정한 최대 시간(\(Int(settings.maximumDuration / 3600))시간)이 지났습니다."
        }
        alert.alertStyle = .informational
        NSApp.activate()
        alert.runModal()
    }

    func refresh() {
        refreshCount += 1
        let previous = snapshot
        snapshot = reader.snapshot()
        blockers = reader.sleepBlockers()
        statusItemVisible = Self.probeStatusItemVisibility()
        Log.model.notice(
            "refresh #\(self.refreshCount) 변화=\(previous != self.snapshot, privacy: .public) sleepDisabled=\(self.snapshot.sleepDisabled, privacy: .public) 전원=\(String(describing: self.snapshot.powerSource), privacy: .public) 배터리=\(self.snapshot.batteryPercent ?? -1)"
        )
    }

    @ObservationIgnored private var refreshCount = 0

    // MARK: - 파생 값

    /// 지금 뚜껑을 닫아도 깨어 있는가.
    var isAwakeOnLidClose: Bool {
        ClamshellPolicy.isAwakeOnLidClose(snapshot)
    }

    /// 클램쉘을 유지하려면 개입이 필요한가.
    var needsEngagement: Bool {
        ClamshellPolicy.isEngagementNeeded(snapshot)
    }

    /// 토글을 켤 수 없는 이유. nil 이면 켤 수 있다.
    ///
    /// 눌러도 아무 일이 없는 토글은 고장으로 보인다. 켤 수 없으면 비활성으로
    /// 보여주고 이유를 함께 적는다.
    var toggleBlockedReason: String? {
        // 이미 우리가 켠 상태면 끄는 것은 언제나 가능해야 한다.
        guard !engagedByUs else { return nil }

        guard helperStatus != nil else {
            return "헬퍼가 설치되지 않았습니다 (sudo make install-helper)"
        }

        switch ClamshellPolicy.decide(snapshot, settings: settings) {
        case .unnecessary(let reason), .refused(let reason):
            return reason
        case .engage, .needsConfirmation:
            return nil
        }
    }

    /// 메뉴바에 그릴 SF Symbol.
    ///
    /// 기준은 **우리가 켰는가**(`engagedByUs`)다. 남이 켠 `SleepDisabled` 나
    /// 외부 디스플레이 때문에 안 자는 경우까지 '켜짐'으로 보이면,
    /// 이 앱이 지금 일하고 있는지를 아이콘으로 알 수 없다.
    ///
    /// 아이콘이 안 보이는 상태(`statusItemVisible == false`)를 여기서 경고
    /// 아이콘으로 알리지 않는다 — 안 보이는 자리에 경고를 그려봐야 그것도
    /// 안 보인다. 그 안내는 메뉴 본문이 맡는다.
    var menuBarSymbol: String {
        engagedByUs ? "sun.max.fill" : "moon.zzz"
    }

    // MARK: - 아이콘 가시성

    private static func probeStatusItemVisibility() -> Bool {
        guard let screen = NSScreen.main,
              let window = NSApp.windows.first(where: {
                  String(describing: type(of: $0)).contains("StatusBar")
              })
        else {
            return true  // 판단할 근거가 없으면 경고하지 않는다
        }

        let areas = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
        guard !areas.isEmpty else {
            return true  // 노치 없는 맥 — 메뉴바가 쪼개지지 않는다
        }

        return ClamshellPolicy.isStatusItemVisible(window.frame, areas: areas)
    }
}
