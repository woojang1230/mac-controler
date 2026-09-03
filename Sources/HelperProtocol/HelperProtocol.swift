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
    ///
    /// 2 — `engage`/`heartbeat` 가 자동 해제 상한을 함께 싣는다.
    public static let protocolVersion = 2

    /// 이 시간 동안 하트비트가 없으면 헬퍼가 baseline 으로 강제 복원한다.
    ///
    /// 앱이 크래시하거나 강제 종료돼도 맥이 영영 안 자는 상태로 남지 않게 하는
    /// 최후 방어선이다. 이것이 sudoers 안을 탈락시킨 이유이기도 하다 —
    /// 상주 데몬이 없으면 이 타이머를 돌릴 주체가 없다.
    public static let heartbeatTimeout: TimeInterval = 90

    /// 앱이 하트비트를 보내는 주기.
    public static let heartbeatInterval: TimeInterval = 30

}

/// engage 를 시간으로 자동 해제하는 상한. 사용자가 설정 창에서 고른다.
///
/// **왜 `TimeInterval?` 이 아닌가.** 이 프로젝트는 nil 의미 불일치로 이미 두 번
/// 물렸다(디스크의 `SleepDisabled` 키 없음 vs 거짓, DESIGN.md §8). '상한 없음' 은
/// 값을 못 읽은 것이 아니라 **사용자가 명시적으로 고른 선택지**다. 둘을 같은
/// 표현으로 뭉뚱그리면 "읽기 실패 → 무제한" 이라는 최악의 오작동이 열린다.
///
/// **이 상한은 시간 제한만 끈다.** 하트비트 워치독(앱이 죽으면 복원)과 부팅 세션
/// 고아 복구는 `never` 에서도 그대로 산다. 그쪽은 사용자 설정 대상이 아니다 —
/// 끄면 앱 크래시 한 번으로 맥이 영영 안 자는 상태가 된다.
public enum AutoReleaseLimit: Sendable, Equatable, Hashable {
    /// 이만큼 지나면 하트비트와 무관하게 복원한다.
    case after(seconds: TimeInterval)

    /// 시간으로는 해제하지 않는다.
    case never

    /// 확정된 제품 결정의 기본값(DESIGN.md §0).
    public static let `default`: AutoReleaseLimit = .after(seconds: 4 * 3600)

    /// 설정 창이 제시하는 선택지. 짧은 것부터, `never` 가 마지막이다.
    public static let presets: [AutoReleaseLimit] = [
        .after(seconds: 30 * 60),
        .after(seconds: 60 * 60),
        .after(seconds: 2 * 3600),
        .after(seconds: 4 * 3600),
        .after(seconds: 8 * 3600),
        .never,
    ]
}

extension AutoReleaseLimit: RawRepresentable {
    /// `"never"` 또는 초 단위 양의 정수 문자열.
    ///
    /// XPC 페이로드·디스크 baseline·UserDefaults 가 **전부 이 하나를 쓴다.**
    /// 표현이 하나뿐이면 세 곳의 해석이 갈라질 여지가 없고, `defaults read` 나
    /// 로그에서 눈으로 바로 읽힌다.
    public var rawValue: String {
        switch self {
        case .never: "never"
        case .after(let seconds): String(Self.boundedSeconds(seconds))
        }
    }

    /// 어떤 값이 들어와도 `Int` 로 안전하게 접는다.
    ///
    /// 파싱(`init?(rawValue:)`)이 막는 것만으로는 부족하다 —
    /// `case after(seconds:)` 가 public 이라 `.after(seconds: .infinity)` 같은
    /// 생성이 문법적으로 가능하고, 그 값이 `Int(_:)` 에 닿으면 root 데몬이
    /// **트랩으로 죽는다**(do/catch 로 못 잡는 프로세스 종료다).
    ///
    /// Double 공간에서 먼저 접은 뒤에 `Int` 로 내린다. 순서가 반대면
    /// 접기 전에 `Int(_:)` 가 먼저 터진다.
    static func boundedSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return maximumSeconds }
        let clamped = Swift.min(Swift.max(seconds.rounded(), 1), Double(maximumSeconds))
        return Int(clamped)
    }

    public init?(rawValue: String) {
        if rawValue == "never" {
            self = .never
            return
        }
        // 헬퍼는 서명 검증이 불가능한 피어에게서 이 값을 받는다(DESIGN.md §3).
        // 음수·0·NaN·소수점·**과도하게 큰 값**을 여기서 전부 잘라낸다.
        // `Int` 파싱이 "1.5"·"nan"·"inf" 를 거르고, 상한이 나머지를 거른다.
        //
        // ⚠️ 상한이 없으면 root 데몬이 죽는다. `Int(rawValue)` 는
        // "9223372036854775807" 를 통과시키고, `TimeInterval` 로 올렸다가
        // `rawValue` 에서 `Int(_:)` 로 되돌릴 때 2^63 이 `Int.max` 를 넘어
        // **트랩한다**(재현 확인: "Double value cannot be converted to Int").
        // do/catch 로는 못 잡는다 — 에러가 아니라 프로세스 종료다.
        // 그러면 engage 된 채로 헬퍼가 크래시 루프에 빠지고, 재시작마다
        // `recoverOrphanIfNeeded` 가 `lastHeartbeat` 를 리셋해
        // **하트비트 워치독과 시간 상한이 동시에 무력화된다**(DESIGN.md §7-2 (3)).
        //
        // 파싱은 방어의 한 겹일 뿐이다. `case after(seconds:)` 가 public 이라
        // 파싱을 우회한 생성이 언제든 가능하므로 `rawValue` 에서도 접는다
        // (`boundedSeconds`). `displayName`·`encode` 는 그 값을 쓴다.
        guard let seconds = Int(rawValue), seconds > 0, seconds <= Self.maximumSeconds
        else { return nil }
        self = .after(seconds: TimeInterval(seconds))
    }

    /// 받아들이는 최대 초. 1년이면 실질적 무제한이고, 진짜 무제한은 `never` 가 따로 있다.
    /// 값 자체보다 **유한한 상한이 존재한다는 것**이 중요하다.
    static let maximumSeconds = 365 * 24 * 3600
}

extension AutoReleaseLimit: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "자동 해제 상한으로 해석할 수 없는 값: '\(raw)'"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 앱 → 헬퍼. 엔드포인트는 의도적으로 넷뿐이다.
public enum HelperRequest: Codable, Sendable {
    /// 슬립 차단을 켠다. 헬퍼가 먼저 현재 값을 baseline 으로 저장한다.
    ///
    /// 부팅 세션 UUID 는 인자로 받지 않는다 — 헬퍼가 `IOPMrootDomain` 에서 직접
    /// 읽을 수 있는 값을 클라이언트에게 받으면 노출 면적만 늘어난다.
    /// 피어 인증이 원리적으로 불가능한 전제(DESIGN.md §3)에서는 받을 수 있는
    /// 입력을 하나라도 줄이는 편이 낫다.
    ///
    /// 상한만은 예외다 — 헬퍼가 스스로 알아낼 방법이 없는 **사용자의 선택**이고,
    /// 앱이 죽은 뒤에도 지켜져야 하므로 헬퍼가 들고 있어야 한다.
    /// 이것으로 늘어나는 권한은 크지 않지만 0 도 아니다. 상한을 길게 부르는 것은
    /// 대체로 하트비트를 계속 보내는 것과 같은 효과다 — 그건 원래 막을 수 없다.
    /// **다만 `never` 는 디스크 baseline 에 남아 헬퍼 재시작을 넘긴다**는 점에서
    /// 하트비트 반복과 완전히 등가는 아니다. 악성 피어에 대해 헬퍼 쪽에 실제로
    /// 남는 방어는 (a) 재부팅 후 고아 복구, (b) 피어가 하트비트를 멈춘 뒤
    /// 90초 워치독 — 이 둘이다. 배터리 임계와 시간 상한은 앱이 판단하므로
    /// 앱을 거치지 않는 피어에게는 적용되지 않는다.
    case engage(limit: AutoReleaseLimit)

    /// baseline 값으로 되돌린다. 무조건 false 로 덮지 않는다.
    case release

    /// 앱이 살아있음을 알리고, 지금 설정된 상한을 함께 알린다.
    ///
    /// 끊기면 워치독이 복원한다. 상한을 매번 싣는 이유는 설정 창에서 값을 바꿨을 때
    /// **이미 켜져 있는** engagement 에도 반영되게 하기 위해서다. 안 그러면
    /// '꺼짐' 으로 바꿔도 헬퍼는 옛 4시간을 들고 있다가 조용히 풀어버린다.
    case heartbeat(limit: AutoReleaseLimit)

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

    /// 헬퍼가 실제로 들고 있는 자동 해제 상한. engage 중이 아니면 nil.
    ///
    /// 앱이 보낸 값이 헬퍼에 도달했는지를 이걸로 확인한다 — 설정 창에서 바꾼 값이
    /// 반영됐는지 사용자가 눈으로 볼 수 있어야 한다.
    public var autoRelease: AutoReleaseLimit?

    public var protocolVersion: Int

    public init(
        effectiveSleepDisabled: Bool,
        baselineSleepDisabled: Bool?,
        engagedByUs: Bool,
        engagedBootSessionUUID: String?,
        engagedAt: Date? = nil,
        secondsSinceHeartbeat: TimeInterval?,
        autoRelease: AutoReleaseLimit? = nil,
        protocolVersion: Int = HelperConstants.protocolVersion
    ) {
        self.effectiveSleepDisabled = effectiveSleepDisabled
        self.baselineSleepDisabled = baselineSleepDisabled
        self.engagedByUs = engagedByUs
        self.engagedBootSessionUUID = engagedBootSessionUUID
        self.engagedAt = engagedAt
        self.secondsSinceHeartbeat = secondsSinceHeartbeat
        self.autoRelease = autoRelease
        self.protocolVersion = protocolVersion
    }
}
