import Foundation

// 앱(비특권)과 헬퍼(root) 사이의 계약. 의존성 0 — IOKit 도 AppKit 도 import 하지 않는다.
//
// 이 모듈이 얇을수록 좋다. 노출 면적이 곧 root 권한의 공격 표면이기 때문이다.
// 이 맥에는 서명 신원이 없어 XPC 피어를 암호학적으로 검증할 수 없으므로
// (DESIGN.md §3), 방어는 "헬퍼가 할 수 있는 일을 최소화하는 것" 하나뿐이다.
//
// 그래서 정책 판단(배터리 임계, 외부 디스플레이 여부, 개입 필요성)은 전부
// 비특권 앱 쪽에 두고, 헬퍼는 **값 하나를 설정하고 되돌리는 일만** 한다.

public enum HelperConstants {
    /// launchd `MachServices` 에 등록되는 이름. plist 와 반드시 일치해야 한다.
    public static let machServiceName = "dev.maccontroler.helper"

    /// 앱과 헬퍼의 계약 버전. 헬퍼만 갱신하고 앱은 옛 버전인 상황을 잡아낸다.
    public static let protocolVersion = 1

    /// 이 시간 동안 하트비트가 없으면 헬퍼가 baseline 으로 강제 복원한다.
    ///
    /// 앱이 크래시하거나 강제 종료돼도 맥이 영영 안 자는 상태로 남지 않게 하는
    /// 최후 방어선이다. 이것이 sudoers 안을 탈락시킨 이유이기도 하다 —
    /// 상주 데몬이 없으면 이 타이머를 돌릴 주체가 없다.
    public static let heartbeatTimeout: TimeInterval = 90

    /// 앱이 하트비트를 보내는 주기.
    public static let heartbeatInterval: TimeInterval = 30

    /// engage 후 이 시간이 지나면 하트비트와 무관하게 무조건 복원한다.
    ///
    /// 하트비트만으로는 부족하다 — 헬퍼가 반복 크래시하면 재시작할 때마다
    /// 하트비트 시계가 리셋되어 워치독이 영영 발동하지 않는다(실측으로 확인).
    /// `engagedAt` 은 디스크의 baseline 에 있으므로 재시작을 넘어 살아남는다.
    ///
    /// 앱 쪽 절대 타임아웃과 같은 값이지만 역할이 다르다 — 이쪽은 앱이 죽은
    /// 뒤에도 동작하는 최후 방어선이다.
    public static let maximumEngagement: TimeInterval = 4 * 3600
}

/// 앱 → 헬퍼. 엔드포인트는 의도적으로 넷뿐이다.
public enum HelperRequest: Codable, Sendable {
    /// 슬립 차단을 켠다. 헬퍼가 먼저 현재 값을 baseline 으로 저장한다.
    ///
    /// 부팅 세션 UUID 는 인자로 받지 않는다 — 헬퍼가 `IOPMrootDomain` 에서 직접
    /// 읽을 수 있는 값을 클라이언트에게 받으면 노출 면적만 늘어난다.
    /// 피어 인증이 원리적으로 불가능한 전제(DESIGN.md §3)에서는 받을 수 있는
    /// 입력을 하나라도 줄이는 편이 낫다.
    case engage

    /// baseline 값으로 되돌린다. 무조건 false 로 덮지 않는다.
    case release

    /// 앱이 살아있음을 알린다. 끊기면 워치독이 복원한다.
    case heartbeat

    /// 헬퍼가 보는 현재 상태. 진단용.
    case status
}

/// 헬퍼 → 앱.
public enum HelperReply: Codable, Sendable {
    /// 요청대로 반영됐고 커널에서 실적용까지 확인됨.
    case applied(HelperStatus)

    /// 이미 원하는 상태라 아무것도 하지 않음.
    case alreadyInDesiredState(HelperStatus)

    /// SPI 호출은 성공했으나 폴링 시간 안에 커널 반영이 확인되지 않음.
    ///
    /// powerd 를 거치는 비동기 경로라 드물게 발생할 수 있다.
    /// 앱은 이것을 실패가 아니라 "확인 불가" 로 다뤄야 한다.
    case notConfirmed(HelperStatus)

    case denied(reason: String)

    case status(HelperStatus)
}

/// 헬퍼가 보고하는 상태.
public struct HelperStatus: Codable, Sendable, Equatable {
    /// 커널에 실제로 반영된 `SleepDisabled`.
    public var effectiveSleepDisabled: Bool

    /// 우리가 engage 하기 직전에 저장해 둔 값. 복원은 항상 이 값으로 한다.
    public var baselineSleepDisabled: Bool?

    /// 지금 이 헬퍼가 슬립 차단을 걸고 있는가.
    ///
    /// `effectiveSleepDisabled == true` 라도 이 값이 false 면 다른 주체가 켠 것이다.
    /// 그 경우 우리는 건드리지 않는다.
    public var engagedByUs: Bool

    /// engage 당시의 부팅 세션. 재부팅을 건너뛴 고아 상태를 감지한다.
    public var engagedBootSessionUUID: String?

    /// 언제 engage 했는가.
    ///
    /// 앱이 재시작되면 자기가 engage 한 기억이 없다. 이 값이 있어야 진행 중인
    /// engagement 를 인수해 하트비트를 재개하고 배터리·타임아웃 자동 해제를
    /// 이어갈 수 있다. 없으면 앱은 토글이 켜진 것처럼 보여주면서 하트비트를
    /// 안 보내고, 90초 뒤 워치독이 조용히 풀어버린다.
    public var engagedAt: Date?

    /// 마지막 하트비트로부터 경과 시간(초). engage 중이 아니면 nil.
    public var secondsSinceHeartbeat: TimeInterval?

    public var protocolVersion: Int

    public init(
        effectiveSleepDisabled: Bool,
        baselineSleepDisabled: Bool?,
        engagedByUs: Bool,
        engagedBootSessionUUID: String?,
        engagedAt: Date? = nil,
        secondsSinceHeartbeat: TimeInterval?,
        protocolVersion: Int = HelperConstants.protocolVersion
    ) {
        self.effectiveSleepDisabled = effectiveSleepDisabled
        self.baselineSleepDisabled = baselineSleepDisabled
        self.engagedByUs = engagedByUs
        self.engagedBootSessionUUID = engagedBootSessionUUID
        self.engagedAt = engagedAt
        self.secondsSinceHeartbeat = secondsSinceHeartbeat
        self.protocolVersion = protocolVersion
    }
}
