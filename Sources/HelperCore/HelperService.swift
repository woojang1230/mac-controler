import ClamshellCore
import Foundation
import HelperProtocol
import IOKit
import OSLog

/// 헬퍼의 두뇌. root 로 돌지만 하는 일은 의도적으로 좁다.
///
/// **정책 판단은 하지 않는다.** 배터리 임계·외부 디스플레이·개입 필요성 같은
/// 판단은 전부 비특권 앱 쪽 `ClamshellPolicy` 가 한다. 헬퍼는 값 하나를
/// 설정하고 baseline 으로 되돌리는 일만 한다.
///
/// 이 맥에는 서명 신원이 없어 XPC 피어를 암호학적으로 검증할 수 없다.
/// 그러므로 "헬퍼가 할 수 있는 일의 범위" 자체가 유일한 방어선이다.
public final class HelperService: @unchecked Sendable {

    private static let log = Logger(subsystem: "dev.maccontroler.helper", category: "service")

    private let lock = NSLock()
    private let store: BaselineStore
    private let reader: any PowerStateReading
    private let control: SleepSwitch
    private let now: @Sendable () -> Date

    private var baseline: Baseline?
    private var lastHeartbeat: Date?

    public init(
        reader: any PowerStateReading,
        writer: any SleepDisabledWriting = SystemSleepDisabledWriter(),
        store: BaselineStore = BaselineStore(),
        confirmationTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.store = store
        self.control = SleepSwitch(
            reader: reader, writer: writer,
            confirmationTimeout: confirmationTimeout, pollInterval: pollInterval)
        self.now = now
        self.baseline = store.load()
    }

    // MARK: - 기동 시 고아 복구

    /// 헬퍼가 뜰 때 단 한 번 부른다.
    ///
    /// baseline 이 남아 있는데 부팅 세션이 다르면, 지난 세션에서 engage 한 채
    /// 정상 종료하지 못했다는 뜻이다. 즉시 되돌린다.
    public func recoverOrphanIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard let saved = baseline else {
            Self.log.notice("기동: baseline 없음 — 복구할 것 없음")
            return
        }

        let current = reader.snapshot().bootSessionUUID
        guard saved.bootSessionUUID != current else {
            // 같은 세션 — 헬퍼만 재시작된 경우다. 워치독이 이어받는다.
            Self.log.notice("기동: 같은 부팅 세션의 baseline 발견 — 워치독이 감시")
            lastHeartbeat = now()
            return
        }

        Self.log.error(
            "기동: 고아 baseline 발견 (저장=\(saved.bootSessionUUID, privacy: .public) 현재=\(current ?? "nil", privacy: .public)) — 즉시 복원")
        restore(reason: "부팅 세션 불일치")
    }

    // MARK: - 요청 처리

    public func handle(_ request: HelperRequest) -> HelperReply {
        lock.lock()
        defer { lock.unlock() }

        switch request {
        case .engage:
            return engage()
        case .release:
            return releaseToBaseline()
        case .heartbeat:
            lastHeartbeat = now()
            return .status(statusLocked())
        case .status:
            return .status(statusLocked())
        }
    }

    private func engage() -> HelperReply {
        guard baseline == nil else {
            lastHeartbeat = now()
            return .alreadyInDesiredState(statusLocked())
        }

        // 반드시 켜기 **전에** 현재 값을 저장한다. 순서가 뒤바뀌면 복원 근거가 사라진다.
        // 되돌릴 대상은 디스크 희망값이다 — 그것만 영구 저장되기 때문이다.
        // nil 은 '키 없음' = 슬립 차단 안 함 = false 다. SleepSwitch.settled 와 **같은**
        // 해석을 써야 한다. 커널값으로 대신 채우면, 디스크에 키가 없는데 커널만 true 인
        // 상태에서 baseline 이 true 가 되고 → release 가 "이미 true"라며 쓰기를 건너뛰고
        // baseline 을 지운다 → 없던 키가 true 로 영구 잔존한다.
        let snapshot = reader.snapshot()
        let saved = Baseline(
            sleepDisabled: snapshot.desiredSleepDisabled ?? false,
            bootSessionUUID: snapshot.bootSessionUUID ?? "unknown",
            engagedAt: now()
        )
        do {
            try store.save(saved)
        } catch {
            Self.log.error("baseline 저장 실패 — engage 거부: \(error.localizedDescription, privacy: .public)")
            return .denied(reason: "baseline 을 저장할 수 없어 되돌릴 방법이 없습니다: \(error.localizedDescription)")
        }
        baseline = saved
        lastHeartbeat = now()

        let outcome = control.apply(true)
        guard outcome.code == kIOReturnSuccess else {
            // 실패했으면 흔적을 남기지 않는다.
            store.clear()
            baseline = nil
            lastHeartbeat = nil
            return .denied(reason: "IOReturn 0x\(String(format: "%08X", outcome.code))")
        }
        return outcome.confirmed ? .applied(statusLocked()) : .notConfirmed(statusLocked())
    }

    private func releaseToBaseline() -> HelperReply {
        guard baseline != nil else { return .alreadyInDesiredState(statusLocked()) }
        return restore(reason: "앱 요청") ? .applied(statusLocked()) : .notConfirmed(statusLocked())
    }

    /// baseline 값으로 되돌린다. lock 을 이미 쥔 상태에서 부른다.
    @discardableResult
    private func restore(reason: String) -> Bool {
        guard let saved = baseline else { return true }
        Self.log.notice(
            "복원 시작 (\(reason, privacy: .public)) → sleepDisabled=\(saved.sleepDisabled, privacy: .public)")

        let outcome = control.apply(saved.sleepDisabled)
        if outcome.confirmed {
            store.clear()
            baseline = nil
            lastHeartbeat = nil
            Self.log.notice("복원 완료")
        } else {
            // baseline 을 지우지 않는다 — 다음 기회에 다시 시도해야 한다.
            Self.log.error("복원 미확인 — baseline 유지하고 재시도 대기")
        }
        return outcome.confirmed
    }

    // MARK: - 워치독

    /// 하트비트가 끊긴 지 오래면 복원한다. 워치독 타이머가 주기적으로 부른다.
    public func checkHeartbeat() {
        lock.lock()
        defer { lock.unlock() }

        guard let saved = baseline else { return }

        // 절대 상한이 먼저다. engagedAt 은 디스크에 있으므로 헬퍼가 몇 번을
        // 재시작해도 살아남는다 — 하트비트 시계만 믿으면 반복 크래시 시
        // 매 재시작마다 리셋되어 워치독이 영영 발동하지 않는다.
        let engaged = now().timeIntervalSince(saved.engagedAt)
        if engaged > HelperConstants.maximumEngagement {
            Self.log.error(
                "engage 후 \(String(format: "%.0f", engaged), privacy: .public)초 경과 — 절대 상한 초과, 복원")
            restore(reason: "절대 상한 초과")
            return
        }

        // baseline 은 있는데 하트비트 기준점이 없다 = 복원이 아직 끝나지 않은 상태다.
        // 고아 복구(`recoverOrphanIfNeeded`)가 미확인으로 끝나면 여기로 온다.
        // 이걸 그냥 return 하면 4시간 절대 상한까지 아무도 다시 시도하지 않는다.
        guard let last = lastHeartbeat else {
            Self.log.notice("복원 미완료 상태 감지 — 재시도")
            restore(reason: "복원 재시도")
            return
        }
        let silence = now().timeIntervalSince(last)
        guard silence > HelperConstants.heartbeatTimeout else { return }

        Self.log.error(
            "하트비트 \(String(format: "%.0f", silence), privacy: .public)초 끊김 — 앱이 죽은 것으로 보고 복원")
        restore(reason: "하트비트 타임아웃")
    }

    // MARK: - 상태

    private func statusLocked() -> HelperStatus {
        HelperStatus(
            effectiveSleepDisabled: reader.snapshot().sleepDisabled,
            baselineSleepDisabled: baseline?.sleepDisabled,
            engagedByUs: baseline != nil,
            engagedBootSessionUUID: baseline?.bootSessionUUID,
            engagedAt: baseline?.engagedAt,
            secondsSinceHeartbeat: lastHeartbeat.map { now().timeIntervalSince($0) }
        )
    }
}
