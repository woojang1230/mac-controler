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

    /// **상한 하나 때문에 복원 근거를 통째로 잃으면 안 된다.**
    ///
    /// throw 하면 `BaselineStore.load()` 가 "파싱 실패" 로 보고 파일을 지운다.
    /// 그러면 헬퍼는 engage 한 적이 없다고 판단하고, `SleepDisabled=true` 가
    /// 영구히 남는다. 앱도 "이미 켜져 있습니다" 로 토글을 비활성화하므로
    /// 사용자에게 되돌릴 방법이 하나도 남지 않는다.
    @Test(
        "★ 깨진 autoRelease 값이어도 복원 근거는 지킨다",
        arguments: ["-9", "0", "abc", "9223372036854775807", ""]
    )
    func corruptLimitKeepsRestoreAnchor(_ raw: String) throws {
        let broken = Data("""
            {"sleepDisabled":true,"bootSessionUUID":"SESSION-A","engagedAt":757339200,"autoRelease":"\(raw)"}
            """.utf8)
        let decoded = try JSONDecoder().decode(Baseline.self, from: broken)

        #expect(decoded.sleepDisabled == true, "복원할 값을 잃으면 되돌릴 방법이 없다")
        #expect(decoded.bootSessionUUID == "SESSION-A")
        #expect(decoded.autoRelease == .default, "못 읽은 상한은 안전한 쪽으로")
        #expect(decoded.autoRelease != .never)
    }

    @Test("baseline 의 필수 필드가 깨지면 그때는 버린다")
    func missingRequiredFieldStillThrows() {
        // 상한과 달리 이쪽은 대체할 안전한 기본값이 없다.
        let broken = Data("""
            {"bootSessionUUID":"S","engagedAt":757339200}
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
