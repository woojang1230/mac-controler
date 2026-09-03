import Foundation
import HelperProtocol
import OSLog

/// engage 직전의 시스템 상태. 복원은 **항상 이 값으로만** 한다.
///
/// 무조건 `false` 로 덮으면 다른 도구나 사용자가 켜둔 설정을 파괴한다.
public struct Baseline: Codable, Sendable, Equatable {
    /// engage 직전의 `SleepDisabled` 값.
    public var sleepDisabled: Bool

    /// engage 당시의 부팅 세션. 재부팅을 건너뛴 고아 상태를 감지한다.
    public var bootSessionUUID: String

    public var engagedAt: Date

    /// 앱이 알려준 자동 해제 상한.
    ///
    /// 여기 있어야 하는 이유는 하나다 — **헬퍼가 재시작해도 살아남아야 한다.**
    /// 메모리에만 두면 헬퍼가 죽고 뜨는 순간 상한이 증발하고, 사용자가 고른
    /// 30분짜리 engagement 가 무기한이 된다.
    public var autoRelease: AutoReleaseLimit

    public init(
        sleepDisabled: Bool,
        bootSessionUUID: String,
        engagedAt: Date,
        autoRelease: AutoReleaseLimit
    ) {
        self.sleepDisabled = sleepDisabled
        self.bootSessionUUID = bootSessionUUID
        self.engagedAt = engagedAt
        self.autoRelease = autoRelease
    }

    /// 옛 버전이 남긴 파일에는 `autoRelease` 키가 없다.
    ///
    /// 합성 디코더에 맡기면 '키 없음' 이 곧 nil 이 되어, 안전한 쪽이 아니라
    /// **가장 위험한 쪽**(상한 없음)으로 떨어진다. 옛 헬퍼가 engage 한 채로
    /// 새 헬퍼가 설치되면 바로 이 경로다. 키가 없으면 기본 상한으로 읽는다.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sleepDisabled = try container.decode(Bool.self, forKey: .sleepDisabled)
        bootSessionUUID = try container.decode(String.self, forKey: .bootSessionUUID)
        engagedAt = try container.decode(Date.self, forKey: .engagedAt)
        autoRelease =
            try container.decodeIfPresent(AutoReleaseLimit.self, forKey: .autoRelease)
            ?? .default
    }
}

/// baseline 을 디스크에 남긴다.
///
/// 왜 디스크인가: 헬퍼가 죽거나 맥이 재부팅돼도 "원래 값이 무엇이었는지"를
/// 알아야 복원할 수 있다. `SleepDisabled` 자체가 영구 저장되는 설정이라
/// 메모리에만 들고 있으면 복원 근거가 사라진다.
public struct BaselineStore: Sendable {
    public static let defaultDirectory = "/Library/Application Support/dev.maccontroler"

    private static let log = Logger(subsystem: "dev.maccontroler.helper", category: "baseline")

    let directory: String
    var path: String { directory + "/baseline.json" }

    /// 테스트는 임시 디렉터리를 넘긴다. 실제 헬퍼는 기본값을 쓴다.
    public init(directory: String = defaultDirectory) {
        self.directory = directory
    }

    public func load() -> Baseline? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try JSONDecoder().decode(Baseline.self, from: data)
        } catch {
            // 깨진 파일을 붙들고 있어봐야 복원에 못 쓴다. 지우고 없는 셈 친다.
            Self.log.error("baseline 파싱 실패, 폐기: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
    }

    public func save(_ baseline: Baseline) throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try JSONEncoder().encode(baseline)

        // 원자적 쓰기. 도중에 죽어도 반쪽짜리 baseline 이 남지 않는다.
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        Self.log.notice(
            "baseline 저장: sleepDisabled=\(baseline.sleepDisabled, privacy: .public) session=\(baseline.bootSessionUUID, privacy: .public) 상한=\(baseline.autoRelease.rawValue, privacy: .public)")
    }

    public func clear() {
        try? FileManager.default.removeItem(atPath: path)
        Self.log.notice("baseline 삭제")
    }
}
