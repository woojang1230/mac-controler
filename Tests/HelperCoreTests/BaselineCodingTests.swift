import Foundation
import HelperProtocol
import Testing

@testable import HelperCore

/// baseline 은 **디스크에 남아 헬퍼 재시작과 재부팅을 넘어간다.**
/// 그래서 옛 버전이 남긴 파일을 새 버전이 읽는 상황이 반드시 생긴다.
@Suite("baseline 디스크 표현")
struct BaselineCodingTests {

    @Test("새 baseline 왕복", arguments: AutoReleaseLimit.presets)
    func roundTrip(_ limit: AutoReleaseLimit) throws {
        let baseline = Baseline(
            sleepDisabled: false,
            bootSessionUUID: "SESSION-A",
            engagedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoRelease: limit
        )
        let data = try JSONEncoder().encode(baseline)
        #expect(try JSONDecoder().decode(Baseline.self, from: data) == baseline)
    }

    /// **상한을 잃는 쪽으로 실패하면 안 된다.**
    ///
    /// 옛 헬퍼가 engage 한 채로 새 헬퍼가 설치되면 이 경로를 탄다.
    /// 키가 없다고 `.never` 로 읽으면, 사용자가 고른 적도 없는 '무제한' 이
    /// 조용히 걸리고 절대 상한이 사라진다.
    @Test("autoRelease 키가 없는 옛 baseline 은 기본 상한으로 읽는다")
    func legacyBaselineGetsDefaultLimit() throws {
        let legacy = Data("""
            {"sleepDisabled":false,"bootSessionUUID":"SESSION-A","engagedAt":757339200}
            """.utf8)
        let decoded = try JSONDecoder().decode(Baseline.self, from: legacy)
        #expect(decoded.autoRelease == .default)
        #expect(decoded.autoRelease != .never, "키 없음을 '무제한' 으로 읽으면 안전장치가 사라진다")
        #expect(decoded.bootSessionUUID == "SESSION-A")
    }

    @Test("깨진 autoRelease 값이면 baseline 전체를 버린다")
    func corruptLimitRejectsWholeFile() {
        let broken = Data("""
            {"sleepDisabled":false,"bootSessionUUID":"S","engagedAt":757339200,"autoRelease":"-9"}
            """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Baseline.self, from: broken)
        }
    }

    @Test("저장한 상한이 파일을 거쳐 그대로 돌아온다")
    func storeRoundTrip() throws {
        let store = makeTemporaryStore()
        let baseline = Baseline(
            sleepDisabled: true,
            bootSessionUUID: "SESSION-B",
            engagedAt: Date(timeIntervalSince1970: 1_700_000_000),
            autoRelease: .never
        )
        try store.save(baseline)
        #expect(store.load() == baseline)
    }
}
