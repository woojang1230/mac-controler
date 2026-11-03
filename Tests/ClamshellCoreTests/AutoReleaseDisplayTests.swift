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

    @Test(
        "★ 파싱을 우회해 만든 값도 이름 만들기에서 트랩하지 않는다",
        arguments: [
            TimeInterval.infinity, TimeInterval.nan, TimeInterval(Int.max), -1, 0, 1e300,
        ]
    )
    func bypassedConstructionHasName(_ seconds: TimeInterval) {
        let name = AutoReleaseLimit.after(seconds: seconds).displayName
        #expect(!name.isEmpty)
        #expect(name != "꺼짐", "시간 상한을 '꺼짐' 으로 표시하면 안 된다")
    }

    @Test("프리셋은 전부 서로 다른 이름을 갖는다")
    func presetNamesAreDistinct() {
        let names = AutoReleaseLimit.presets.map(\.displayName)
        #expect(Set(names).count == names.count, "같은 이름이 두 번 뜨면 고를 수가 없다")
    }

    /// 저장된 값이 프리셋 밖이면 Picker 가 빈칸이 된다 — 현재 설정을 화면에서
    /// 알 수 없는 상태다. `choices` 가 그것을 목록에 끼워 넣는다.
    @Test("★ 프리셋 밖의 값도 선택지에 들어간다")
    func choicesIncludeNonPresetValue() {
        let odd = AutoReleaseLimit.after(seconds: 5400)  // 1시간 30분
        let choices = AutoReleaseLimit.choices(including: odd)

        #expect(choices.contains(odd))
        #expect(choices.count == AutoReleaseLimit.presets.count + 1)
        #expect(choices.last == .never, "'꺼짐' 은 항상 마지막이다")

        // 짧은 것부터 정렬된 자리에 들어가야 한다 (1시간 뒤, 2시간 앞).
        let seconds = choices.compactMap { limit -> TimeInterval? in
            if case .after(let s) = limit { return s }
            return nil
        }
        #expect(seconds == seconds.sorted())
    }

    @Test("프리셋 값이면 목록이 그대로다", arguments: AutoReleaseLimit.presets)
    func choicesUnchangedForPresets(_ preset: AutoReleaseLimit) {
        #expect(AutoReleaseLimit.choices(including: preset) == AutoReleaseLimit.presets)
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
