import Foundation
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

    public init(sleepDisabled: Bool, bootSessionUUID: String, engagedAt: Date) {
        self.sleepDisabled = sleepDisabled
        self.bootSessionUUID = bootSessionUUID
        self.engagedAt = engagedAt
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
            "baseline 저장: sleepDisabled=\(baseline.sleepDisabled, privacy: .public) session=\(baseline.bootSessionUUID, privacy: .public)")
    }

    public func clear() {
        try? FileManager.default.removeItem(atPath: path)
        Self.log.notice("baseline 삭제")
    }
}
