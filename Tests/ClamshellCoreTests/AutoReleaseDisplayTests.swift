import Foundation
import HelperProtocol
import Testing

@testable import ClamshellCore

/// 설정 창과 메뉴에 그대로 나가는 문자열이다. 틀리면 사용자가 잘못 이해한다.
@Suite("자동 해제 상한 표기")
struct AutoReleaseDisplayTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let limit: AutoReleaseLimit
        let expected: String
        var testDescription: String { "\(expected)" }
    }

    @Test(
        "사람이 읽는 이름",
        arguments: [
            Case(limit: .after(seconds: 1800), expected: "30분"),
            Case(limit: .after(seconds: 3600), expected: "1시간"),
            Case(limit: .after(seconds: 2 * 3600), expected: "2시간"),
            Case(limit: .after(seconds: 4 * 3600), expected: "4시간"),
            Case(limit: .after(seconds: 8 * 3600), expected: "8시간"),
            Case(limit: .after(seconds: 90 * 60), expected: "1시간 30분"),
            Case(limit: .after(seconds: 30), expected: "30초"),
            Case(limit: .never, expected: "꺼짐"),
        ]
    )
    func displayName(_ c: Case) {
        #expect(c.limit.displayName == c.expected)
    }

    @Test("프리셋은 전부 서로 다른 이름을 갖는다")
    func presetNamesAreDistinct() {
        let names = AutoReleaseLimit.presets.map(\.displayName)
        #expect(Set(names).count == names.count, "같은 이름이 두 번 뜨면 고를 수가 없다")
    }

    @Test("프리셋은 짧은 것부터 정렬돼 있고 '꺼짐' 이 마지막이다")
    func presetsAreOrdered() {
        let seconds = AutoReleaseLimit.presets.compactMap { limit -> TimeInterval? in
            if case .after(let s) = limit { return s }
            return nil
        }
        #expect(seconds == seconds.sorted())
        #expect(AutoReleaseLimit.presets.last == .never)
    }
}
