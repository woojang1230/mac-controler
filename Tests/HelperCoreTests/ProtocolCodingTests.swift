import Foundation
import Testing

@testable import HelperProtocol

/// 앱과 헬퍼는 다른 프로세스다. 계약이 인코딩을 못 견디면 설치 직후에 터진다.
///
/// 연관값을 가진 enum 은 Codable 합성이 되긴 하지만 중첩 컨테이너를 쓰므로,
/// 실제로 왕복이 되는지 눈으로 확인해 둔다.
@Suite("XPC 계약 인코딩")
struct ProtocolCodingTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test(
        "HelperRequest 왕복",
        arguments: [
            HelperRequest.engage(limit: .default),
            .engage(limit: .never),
            .engage(limit: .after(seconds: 1800)),
            .release,
            .heartbeat(limit: .default),
            .heartbeat(limit: .never),
            .status,
        ]
    )
    func requestRoundTrip(_ request: HelperRequest) throws {
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)

        // HelperRequest 는 Equatable 이 아니므로 케이스로 비교한다.
        switch (request, decoded) {
        case (.engage(let a), .engage(let b)), (.heartbeat(let a), .heartbeat(let b)):
            #expect(a == b, "상한이 왕복에서 바뀌면 헬퍼가 다른 시간에 풀어버린다")
        case (.release, .release), (.status, .status):
            break
        default:
            Issue.record("케이스가 바뀌었다: \(request) → \(decoded)")
        }
    }

    @Test("HelperStatus 왕복 — nil 필드 포함")
    func statusRoundTrip() throws {
        let status = HelperStatus(
            effectiveSleepDisabled: true,
            baselineSleepDisabled: false,
            engagedByUs: true,
            engagedBootSessionUUID: "SESSION-A",
            // 앱이 재시작 후 engagement 를 인수하려면 이 값이 살아남아야 한다.
            engagedAt: Date(timeIntervalSince1970: 1_700_000_000),
            secondsSinceHeartbeat: 12.5,
            autoRelease: .never
        )
        let decoded = try roundTrip(status)
        #expect(decoded == status)
        #expect(decoded.engagedAt == status.engagedAt, "engagedAt 이 사라지면 자동 해제가 죽는다")

        // baseline 이 nil 인 상태(= engage 중 아님)도 왕복돼야 한다.
        let idle = HelperStatus(
            effectiveSleepDisabled: false,
            baselineSleepDisabled: nil,
            engagedByUs: false,
            engagedBootSessionUUID: nil,
            secondsSinceHeartbeat: nil
        )
        #expect(try roundTrip(idle) == idle)
    }

    @Test("HelperReply 왕복 — 연관값이 붙은 모든 케이스")
    func replyRoundTrip() throws {
        let status = HelperStatus(
            effectiveSleepDisabled: true, baselineSleepDisabled: false,
            engagedByUs: true, engagedBootSessionUUID: "S", secondsSinceHeartbeat: 1)

        let cases: [HelperReply] = [
            .applied(status), .alreadyInDesiredState(status),
            .notConfirmed(status), .status(status),
            .denied(reason: "IOReturn 0xE00002C1"),
        ]

        for reply in cases {
            let data = try JSONEncoder().encode(reply)
            let decoded = try JSONDecoder().decode(HelperReply.self, from: data)
            switch (reply, decoded) {
            case (.applied(let a), .applied(let b)),
                 (.alreadyInDesiredState(let a), .alreadyInDesiredState(let b)),
                 (.notConfirmed(let a), .notConfirmed(let b)),
                 (.status(let a), .status(let b)):
                #expect(a == b)
            case (.denied(let a), .denied(let b)):
                #expect(a == b)
            default:
                Issue.record("케이스가 바뀌었다: \(reply) → \(decoded)")
            }
        }
    }

    /// 헬퍼는 서명 검증이 불가능한 피어에게서 이 페이로드를 받는다(DESIGN.md §3).
    /// 상한이 말이 안 되면 **요청 전체가** 디코드에 실패해야 한다 —
    /// 그래야 `request.accept` 클로저가 아예 실행되지 않는다.
    @Test(
        "★ 말이 안 되는 상한이 실린 요청은 통째로 거부된다",
        arguments: ["9223372036854775807", "99999999999999999999", "-1", "0", "abc", "31536001"]
    )
    func maliciousLimitRejectsWholeRequest(_ raw: String) {
        for verb in ["engage", "heartbeat"] {
            let payload = Data("{\"\(verb)\":{\"limit\":\"\(raw)\"}}".utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(HelperRequest.self, from: payload)
            }
        }
    }

    @Test("정상 상한이 실린 요청은 통과한다")
    func validLimitPassesRequestDecoding() throws {
        let payload = Data("{\"heartbeat\":{\"limit\":\"1800\"}}".utf8)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: payload)
        guard case .heartbeat(let limit) = decoded else {
            Issue.record("heartbeat 가 아니다: \(decoded)")
            return
        }
        #expect(limit == .after(seconds: 1800))
    }

    @Test("프로토콜 버전과 하트비트 상수가 일관적이다")
    func constantsAreSane() {
        #expect(HelperConstants.heartbeatInterval < HelperConstants.heartbeatTimeout,
                "보내는 주기가 타임아웃보다 길면 멀쩡한 앱이 끊긴 것으로 오인된다")
        #expect(HelperConstants.heartbeatTimeout >= HelperConstants.heartbeatInterval * 2,
                "한 번 걸러도 버틸 여유가 있어야 한다")
        #expect(HelperStatus(
            effectiveSleepDisabled: false, baselineSleepDisabled: nil,
            engagedByUs: false, engagedBootSessionUUID: nil, secondsSinceHeartbeat: nil
        ).protocolVersion == HelperConstants.protocolVersion)

        // 상한을 프로토콜에 실은 변경이므로 버전이 올라가 있어야 한다.
        // 옛 헬퍼는 상한을 무시하고 자기 상수를 쓰므로 앱이 이걸로 걸러낸다.
        #expect(HelperConstants.protocolVersion >= 2)
    }
}
