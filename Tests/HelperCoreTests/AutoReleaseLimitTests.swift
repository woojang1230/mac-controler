import Foundation
import Testing

@testable import HelperProtocol

/// 자동 해제 상한은 **앱과 헬퍼가 같은 뜻으로 읽어야 하는 값**이다.
///
/// `TimeInterval?` 로 두지 않고 별도 타입을 만든 이유가 여기 걸려 있다 —
/// 이 프로젝트는 nil 의미 불일치로 이미 두 번 물렸다(DESIGN.md §8).
/// '상한 없음' 은 값의 부재가 아니라 사용자가 고른 선택지다.
@Suite("자동 해제 상한")
struct AutoReleaseLimitTests {

    @Test("프리셋은 전부 rawValue 왕복이 된다", arguments: AutoReleaseLimit.presets)
    func rawValueRoundTrip(_ limit: AutoReleaseLimit) {
        #expect(AutoReleaseLimit(rawValue: limit.rawValue) == limit)
    }

    @Test("JSON 은 문자열 하나로 인코딩된다")
    func encodesAsSingleString() throws {
        let data = try JSONEncoder().encode(AutoReleaseLimit.after(seconds: 1800))
        #expect(String(decoding: data, as: UTF8.self) == "\"1800\"")

        let never = try JSONEncoder().encode(AutoReleaseLimit.never)
        #expect(String(decoding: never, as: UTF8.self) == "\"never\"")
    }

    @Test("JSON 왕복", arguments: AutoReleaseLimit.presets)
    func jsonRoundTrip(_ limit: AutoReleaseLimit) throws {
        let data = try JSONEncoder().encode(limit)
        #expect(try JSONDecoder().decode(AutoReleaseLimit.self, from: data) == limit)
    }

    /// 헬퍼는 서명 검증이 불가능한 피어에게서 이 값을 받는다(DESIGN.md §3).
    /// 파싱 단계에서 걸러야 `checkHeartbeat` 가 NaN/음수를 들고 비교하는 일이 없다.
    @Test(
        "말이 안 되는 값은 파싱 단계에서 거부한다",
        arguments: ["", "abc", "0", "-1", "-3600", "1.5", "nan", "inf", "never ", "NEVER"]
    )
    func rejectsNonsense(_ raw: String) {
        #expect(AutoReleaseLimit(rawValue: raw) == nil, "'\(raw)' 를 통과시키면 안 된다")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                AutoReleaseLimit.self, from: Data("\"\(raw)\"".utf8))
        }
    }

    @Test("기본값은 4시간이다 — 확정된 제품 결정(DESIGN.md §0)")
    func defaultIsFourHours() {
        #expect(AutoReleaseLimit.default == .after(seconds: 4 * 3600))
        #expect(AutoReleaseLimit.presets.contains(.default))
        #expect(AutoReleaseLimit.presets.contains(.never), "'꺼짐' 선택지가 반드시 있어야 한다")
    }
}
