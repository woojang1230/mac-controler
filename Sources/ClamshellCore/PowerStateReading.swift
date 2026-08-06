import Foundation

/// 슬립을 막고 있는 프로세스 하나.
///
/// "맥이 왜 안 자지?" 에 답하기 위한 것이다. root 없이 읽을 수 있다.
public struct SleepBlocker: Sendable, Equatable, Identifiable {
    public let pid: Int
    public let processName: String
    public let assertionTypes: [String]

    public var id: Int { pid }

    public init(pid: Int, processName: String, assertionTypes: [String]) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
    }
}

/// 시스템 상태를 읽는 창구.
///
/// 프로토콜로 뽑아둔 이유는 하나다 — 테스트에서 가짜를 꽂기 위해서다.
/// 실제 구현(`IOKitPowerStateReader`)은 IOKit 을 직접 부르므로 단위 테스트가 불가능하다.
public protocol PowerStateReading: Sendable {
    func snapshot() -> PowerSnapshot
    func sleepBlockers() -> [SleepBlocker]
}
