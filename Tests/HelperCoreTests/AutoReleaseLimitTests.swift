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
        arguments: [
            "", "abc", "0", "-1", "-3600", "1.5", "nan", "inf", "never ", "NEVER",
            // ★ 상한이 없으면 root 데몬이 트랩으로 죽는다.
            // TimeInterval 로 올렸다 Int 로 되돌릴 때 2^63 이 Int.max 를 넘는다.
            "9223372036854775807",
            "9223372036854775806",
            "99999999999999999999",
            "31536001",  // 1년 + 1초
        ]
    )
    func rejectsNonsense(_ raw: String) {
        #expect(AutoReleaseLimit(rawValue: raw) == nil, "'\(raw)' 를 통과시키면 안 된다")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                AutoReleaseLimit.self, from: Data("\"\(raw)\"".utf8))
        }
    }

    /// 파싱이 통과시킨 값은 **반드시** rawValue 왕복이 되어야 한다.
    ///
    /// 이 왕복이 `Int(Double)` 트랩을 밟으면 do/catch 로 못 잡고 프로세스가 죽는다.
    /// 헬퍼가 그렇게 죽으면 engage 된 채 크래시 루프에 빠지고, 재시작마다
    /// `lastHeartbeat` 이 리셋되어 워치독과 시간 상한이 동시에 무력화된다.
    @Test("★ 파싱을 통과한 값은 인코딩에서 트랩하지 않는다")
    func acceptedValuesNeverTrapOnEncode() throws {
        let candidates = [
            "1", "30", "1800", "14400", "31536000",  // 경계: 1초 ~ 1년
            "9223372036854775807", "99999999999999999999", "31536001",  // 거부돼야 함
        ]
        for raw in candidates {
            guard let limit = AutoReleaseLimit(rawValue: raw) else { continue }
            // 통과했다면 아래 셋 전부 트랩 없이 돌아야 한다.
            #expect(limit.rawValue == raw)
            _ = try JSONEncoder().encode(limit)
            #expect(try JSONDecoder().decode(
                AutoReleaseLimit.self, from: JSONEncoder().encode(limit)) == limit)
        }
    }

    /// 파싱은 방어의 한 겹일 뿐이다. `case after(seconds:)` 가 public 이라
    /// 파싱을 우회한 생성이 언제든 가능하고, 그 값이 `Int(_:)` 에 닿으면
    /// root 데몬이 트랩으로 죽는다 — do/catch 로 못 잡는 프로세스 종료다.
    @Test(
        "★ 파싱을 우회해 만든 값도 rawValue 에서 트랩하지 않는다",
        arguments: [
            TimeInterval.infinity, -TimeInterval.infinity, TimeInterval.nan,
            TimeInterval(Int.max), -1, 0, 1e300, 31_536_001,
        ]
    )
    func bypassedConstructionIsBounded(_ seconds: TimeInterval) throws {
        let limit = AutoReleaseLimit.after(seconds: seconds)

        // 아래 셋 전부 트랩 없이 돌아야 한다.
        let raw = limit.rawValue
        _ = try JSONEncoder().encode(limit)

        // 접힌 값은 반드시 다시 파싱 가능한 범위 안이다.
        let reparsed = AutoReleaseLimit(rawValue: raw)
        #expect(reparsed != nil, "'\(raw)' 를 스스로 다시 못 읽으면 안 된다")
        #expect(reparsed != .never, "접기가 무제한으로 새면 안 된다")
    }

    @Test("경계값: 1초와 1년은 받고 그 밖은 거부한다")
    func boundaries() {
        #expect(AutoReleaseLimit(rawValue: "1") == .after(seconds: 1))
        #expect(AutoReleaseLimit(rawValue: "31536000") == .after(seconds: 31_536_000))
        #expect(AutoReleaseLimit(rawValue: "0") == nil)
        #expect(AutoReleaseLimit(rawValue: "31536001") == nil)
    }

    @Test("기본값은 4시간이다 — 확정된 제품 결정(DESIGN.md §0)")
    func defaultIsFourHours() {
        #expect(AutoReleaseLimit.default == .after(seconds: 4 * 3600))
        #expect(AutoReleaseLimit.presets.contains(.default))
        #expect(AutoReleaseLimit.presets.contains(.never), "'꺼짐' 선택지가 반드시 있어야 한다")
    }
}
