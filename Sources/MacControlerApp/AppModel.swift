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

    /// 상한 동기화 요청의 진행 상태. 판정 규칙은 `LimitSyncTracker` 가 갖는다.
    private var limitSync = LimitSyncTracker()

    /// 바뀐 상한이 헬퍼에 도달하기를 기다리는 중인가.
    /// 이 동안은 앱과 헬퍼의 값이 다른 것이 정상이므로 경고를 띄우지 않는다.
    var isSyncingLimit: Bool { limitSync.isSyncing }

    /// 사용자에게 보여줄 마지막 실패/거부 사유.
    private(set) var lastMessage: String?

    /// 사용자가 고른 설정. 설정 창에서만 바뀐다.
    ///
    /// `@Observable` 은 `didSet` 을 붙인 저장 프로퍼티를 추적하지 못하므로
    /// 저장·전파는 `setAutoRelease(_:)` 가 명시적으로 한다.
    private(set) var settings: PolicySettings

    private let reader: any PowerStateReading
    @ObservationIgnored private var observer: PowerStateObserver?
    @ObservationIgnored private let helper = XPCSleepController()
    @ObservationIgnored private var engagedAt: Date?
    @ObservationIgnored private var heartbeatTimer: Timer?

    init(reader: any PowerStateReading = IOKitPowerStateReader()) {
        self.reader = reader
        self.snapshot = reader.snapshot()
        self.settings = PolicySettingsStore.load()
    }

    /// 자동 해제 시간 상한을 바꾼다.
    ///
    /// 디스크에 저장하고, **이미 켜져 있으면 헬퍼에게 즉시 알린다.** 다음 하트비트를
    /// 기다리면 최대 30초 동안 헬퍼가 옛 상한을 들고 있게 되고, 그 사이에 옛 상한이
    /// 만료되면 방금 '꺼짐' 으로 바꾼 사용자 눈앞에서 조용히 풀려버린다.
    func setAutoRelease(_ limit: AutoReleaseLimit) {
        guard settings.autoRelease != limit else { return }
        settings.autoRelease = limit
        PolicySettingsStore.save(settings)
        Log.model.notice("자동 해제 상한 변경: \(limit.rawValue, privacy: .public)")
        guard engagedByUs else { return }
        syncLimitToHelper()
    }

    /// 지금 설정된 상한을 헬퍼로 보내고, 왕복이 끝날 때까지 표시를 눌러둔다.
    ///
    /// 왕복 중에는 앱 설정과 헬퍼 상태가 반드시 다르다. 그것을 괴리로 표시하면
    /// 값을 바꿀 때마다 경고가 깜빡였다 사라진다(실측 왕복 33밀리초, 다만
    /// 헬퍼가 커널 확인을 폴링하면 최대 2초까지 늘어난다).
    ///
    /// **표시를 내리는 판정은 값이 아니라 세대로 한다** (`LimitSyncTracker`).
    /// 값으로 비교하면 왕복 중 XPC 가 실패해(`helperStatus = nil` →
    /// `engagedByUs == false`) 새 요청이 뜨지 못한 사이 사용자가 값을 바꾼 경우,
    /// 진행 중이던 요청이 "내 값이 아니네" 하고 표시를 안 내려 **고착된다.**
    private func syncLimitToHelper() {
        let limit = settings.autoRelease
        let generation = limitSync.begin()
        Task {
            // 어떤 경로로 빠져나가든 진행 표시는 반드시 정리한다.
            defer { self.limitSync.finish(generation) }
            await self.send(.heartbeat(limit: limit))
        }
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

        // UI 비활성화만으로는 부족하다 — 키보드·접근성 경로로도 여기 들어올 수 있다.
        // 막는 이유가 있으면 실행 경로에서도 막는다.
        if let mismatch = helperVersionMismatch {
            lastMessage = mismatch
            Log.model.notice("engage 안 함: \(mismatch, privacy: .public)")
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

        await send(.engage(limit: settings.autoRelease))
        adoptEngagementIfNeeded()
    }

    /// 헬퍼가 engage 중이면 그 engagement 를 인수한다.
    ///
    /// engage 직후뿐 아니라 **앱 재시작 후에도** 필요하다. 헬퍼가 켜둔 채로
    /// 앱만 다시 뜨면, 메뉴는 토글 ON 으로 보이는데 하트비트를 아무도 안 보내
    /// 90초 뒤 워치독이 조용히 풀어버린다. `engagedAt` 이 없으면 배터리·타임아웃
    /// 자동 해제도 함께 죽는다.
    private func adoptEngagementIfNeeded() {
        guard let status = helperStatus else {
            // 헬퍼 상태를 모른다 = XPC 가 일시적으로 실패했다는 뜻이지,
            // 헬퍼가 해제됐다는 뜻이 아니다. 여기서 하트비트를 멈추면
            // 워치독이 복원해버리고, 다음 수동 갱신까지 자가 복구도 안 된다.
            Log.model.notice("헬퍼 상태 불명 — 하트비트는 유지하고 다음 기회에 재확인")
            return
        }
        guard status.engagedByUs else {
            stopHeartbeat()
            engagedAt = nil
            return
        }

        // 헬퍼가 우리 설정과 다른 상한으로 돌고 있으면 즉시 맞춘다.
        // 앱을 다시 띄워 진행 중인 engagement 를 인수한 경우가 이렇다.
        // 다음 하트비트를 기다리면 최대 30초 동안 사용자가 고르지 않은 상한이 지켜진다.
        //
        // 버전이 안 맞으면 시도하지 않는다. 옛(v1) 헬퍼는 `status.autoRelease` 가
        // 항상 nil 이라 여기가 반드시 발동하는데, 그 하트비트를 옛 헬퍼가
        // 디코드하지 못해 실패하고 `helperStatus = nil` 이 된다. 그러면 방금
        // 정확히 진단한 "헬퍼가 오래되었습니다(버전 1, 필요 2)" 가
        // "헬퍼가 설치되지 않았습니다" 로 덮여 사용자가 원인을 잘못 안다.
        if helperVersionMismatch == nil,
           status.autoRelease != settings.autoRelease,
           !isSyncingLimit {
            syncLimitToHelper()
        }

        guard heartbeatTimer == nil else { return }  // 이미 인수함

        engagedAt = status.engagedAt ?? Date()
        Log.model.notice(
            "진행 중인 engagement 인수 — engagedAt=\(String(describing: self.engagedAt), privacy: .public)")
        startHeartbeat()
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
    private func send(_ request: HelperRequest) async -> HelperReply? {
        let helper = self.helper
        do {
            let reply = try await Task.detached { try helper.send(request) }.value
            apply(reply)
            return reply
        } catch {
            helperStatus = nil
            lastMessage = error.localizedDescription
            Log.model.error("헬퍼 요청 실패: \(error.localizedDescription, privacy: .public)")
            return nil
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
            // 거부됐다면 우리가 들고 있던 상태가 더 이상 맞지 않을 수 있다.
            // 토글이 실제와 다른 상태를 계속 표시하지 않도록 다시 물어본다.
            Task { await self.syncHelperStatus() }
        }
        refresh()
    }

    func syncHelperStatus() async {
        await send(.status)
        adoptEngagementIfNeeded()
    }

    // MARK: - 하트비트와 자동 해제

    /// 앱이 살아있음을 헬퍼에 알린다. 끊기면 헬퍼가 baseline 으로 되돌린다.
    private func startHeartbeat() {
        stopHeartbeat()
        // ⚠️ `Timer.scheduledTimer` 는 메인 런루프의 `.default` 모드에만 붙는다.
        // NSMenu 트래킹은 `NSEventTrackingRunLoopMode` 중첩 루프로 전환되므로,
        // 그대로 두면 **메뉴가 열려 있는 동안 하트비트가 한 번도 안 나간다.**
        // 메뉴를 90초 열어두면 헬퍼 워치독이 앱이 죽은 줄 알고 조용히 복원한다.
        // `PowerStateObserver` 가 IOPS 소스를 `.commonModes` 로 넣은 것과 같은 이유다.
        let timer = Timer(timeInterval: HelperConstants.heartbeatInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// 앱 종료 직전에 engagement 를 정리한다.
    ///
    /// 워치독이 어차피 90초 뒤 되돌리지만, 그 90초 동안 사용자는 "앱을 껐다"고
    /// 믿으면서 맥은 여전히 뚜껑을 닫아도 안 자는 상태다. 의도적 종료라면
    /// 즉시 되돌리는 것이 맞다. 종료 경로라 동기로 부른다(최대 폴링 시간만큼 지연).
    func releaseOnQuit() {
        guard engagedByUs else { return }
        stopHeartbeat()
        engagedAt = nil
        Log.model.notice("앱 종료 — engagement 해제")
        _ = try? helper.send(.release)
    }

    private func beat() async {
        refresh()

        // 하트비트를 보내기 전에 스스로 풀어야 할 이유가 없는지 본다.
        if let engagedAt,
           let reason = ClamshellPolicy.autoReleaseReason(
               snapshot, engagedAt: engagedAt, now: Date(), settings: settings) {
            Log.model.notice("자동 해제: \(String(describing: reason), privacy: .public)")
            let reply = await send(.release)
            stopHeartbeat()
            self.engagedAt = nil
            // 헬퍼가 복원을 확인하지 못했으면(재시도 대기 중) 완료라고 말하면 안 된다.
            //
            // 헬퍼 워치독은 10초마다(`heartbeatInterval/3`), 앱 `beat()` 는 30초마다
            // 돈다 — 정상 타임아웃에서는 **헬퍼가 먼저 복원하는 것이 보통이다.**
            // 그때 뒤늦은 `.release` 는 `.alreadyInDesiredState` 를 받는다.
            // `.applied` 만 성공으로 치면 멀쩡히 해제된 상황에 "확인되지 않았습니다"
            // 경고가 뜬다. 이미 풀려 있으면(`engagedByUs == false`) 그것이 곧 성공이다.
            var confirmed = false
            switch reply {
            case .applied:
                confirmed = true
            case .alreadyInDesiredState(let status):
                confirmed = !status.engagedByUs
            default:
                break
            }
            notifyAutoRelease(reason, confirmed: confirmed)
            return
        }
        await send(.heartbeat(limit: settings.autoRelease))
    }

    private func notifyAutoRelease(_ reason: ClamshellPolicy.AutoReleaseReason, confirmed: Bool) {
        let why = switch reason {
        case .lowBattery: "배터리가 \(settings.batteryThresholdPercent)% 아래로 떨어졌습니다."
        case .timeout: "설정한 시간 제한(\(settings.autoRelease.displayName))이 지났습니다."
        }
        let alert = NSAlert()
        if confirmed {
            alert.messageText = "슬립 차단을 자동으로 해제했습니다"
            alert.informativeText = why
            alert.alertStyle = .informational
        } else {
            alert.messageText = "슬립 차단 해제를 요청했으나 확인되지 않았습니다"
            alert.informativeText = why
                + "\n\n헬퍼가 재시도 중입니다. 잠시 후에도 켜져 있으면 메뉴에서 상태를 확인하세요."
            alert.alertStyle = .warning
        }
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

    /// 헬퍼 프로토콜 버전이 앱과 다르면 그 사유. 맞으면 nil.
    ///
    /// 옛 헬퍼는 `engage(limit:)` 의 상한을 무시하고 자기 상수(4시간)를 쓴다.
    /// 그러면 사용자가 '꺼짐' 을 골라도 4시간 뒤에 조용히 풀린다 — 설정 창이
    /// 거짓말을 하게 된다. 조용히 틀리느니 켜지 않는 편이 낫다.
    private var helperVersionMismatch: String? {
        guard let status = helperStatus,
              status.protocolVersion != HelperConstants.protocolVersion
        else { return nil }
        return "헬퍼가 오래되었습니다 (버전 \(status.protocolVersion), 필요 \(HelperConstants.protocolVersion))"
            + " — sudo make install-helper"
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

        if let mismatch = helperVersionMismatch { return mismatch }

        switch ClamshellPolicy.decide(snapshot, settings: settings) {
        case .unnecessary(let reason), .refused(let reason):
            return reason
        case .engage, .needsConfirmation:
            return nil
        }
    }

    /// 헬퍼가 실제로 들고 있는 상한. 앱 설정과 다르면 아직 전달되지 않은 것이다.
    var helperAutoRelease: AutoReleaseLimit? { helperStatus?.autoRelease }

    /// "헬퍼는 아직 옛 상한으로 동작 중" 경고를 띄워야 하는가.
    var shouldWarnLimitMismatch: Bool {
        ClamshellPolicy.shouldWarnLimitMismatch(
            appLimit: settings.autoRelease,
            helperLimit: helperAutoRelease,
            isSyncing: isSyncingLimit)
    }

    /// 지금 켜져 있는 engagement 가 언제 자동 해제되는지.
    ///
    /// 남은 시간이 아니라 **시각**으로 보여준다. 창을 열어둔 채 시간이 흘러도
    /// 문구가 틀려지지 않는다.
    var scheduledReleaseDescription: String {
        guard let status = helperStatus, status.engagedByUs else {
            return "켜져 있지 않습니다"
        }
        guard let limit = status.autoRelease else {
            return "헬퍼가 상한을 보고하지 않았습니다"
        }
        guard case .after(let seconds) = limit else {
            return "시간 제한 꺼짐 — 끌 때까지 유지합니다"
        }
        guard let engagedAt = status.engagedAt else {
            return "\(limit.displayName) 뒤 해제"
        }
        let due = engagedAt.addingTimeInterval(seconds)
        return "\(due.formatted(date: .omitted, time: .shortened)) 에 자동 해제 (\(limit.displayName))"
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
