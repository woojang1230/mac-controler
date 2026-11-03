import Foundation
import HelperProtocol
import OSLog
import XPC

/// root 헬퍼로 가는 유일한 통로.
///
/// 세션은 한 번 만들어 재사용하고, 끊기면 다음 호출에서 다시 만든다.
/// 헬퍼가 `KeepAlive` 로 상주하므로 보통은 첫 연결이 계속 살아있다.
/// 이 타입만 MainActor 격리에서 벗어난다 — `sendSync` 는 헬퍼가 커널 반영을
/// 폴링하는 동안 최대 2초까지 블록될 수 있어서, 메인 스레드에서 부르면 메뉴가 멈춘다.
nonisolated final class XPCSleepController: @unchecked Sendable {

    enum Failure: Error, LocalizedError {
        case notInstalled(underlying: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let underlying):
                return "헬퍼에 연결할 수 없습니다. 설치되지 않았을 수 있습니다 (sudo make install-helper). 원인: \(underlying)"
            }
        }
    }

    private static let log = Logger(subsystem: "dev.maccontroler.app", category: "xpc")

    private let lock = NSLock()
    private var session: XPCSession?

    // XPCSession 은 활성 상태로 해제되면 libxpc 가 _xpc_api_misuse 로 트랩한다
    // (실측: EXC_BREAKPOINT in XPCSession.__deallocating_deinit).
    // 버리기 전에 반드시 cancel 해야 한다.
    deinit {
        session?.cancel(reason: "controller released")
    }

    private func discardSession(reason: String) {
        session?.cancel(reason: reason)
        session = nil
    }

    /// 요청 하나를 보내고 답을 받는다.
    func send(_ request: HelperRequest) throws -> HelperReply {
        lock.lock()
        defer { lock.unlock() }

        do {
            return try sendLocked(request)
        } catch {
            // 끊긴 세션을 붙들고 있어봐야 계속 실패한다. 버리고 한 번 더.
            Self.log.notice("XPC 재연결 시도 (원인: \(error.localizedDescription, privacy: .public))")
            discardSession(reason: "reconnect")
            return try sendLocked(request)
        }
    }

    private func sendLocked(_ request: HelperRequest) throws -> HelperReply {
        let active: XPCSession
        if let existing = session {
            active = existing
        } else {
            do {
                // .privileged 는 시스템 도메인의 mach 서비스에 붙기 위해 필요하다.
                active = try XPCSession(
                    machService: HelperConstants.machServiceName,
                    options: .privileged
                )
            } catch {
                throw Failure.notInstalled(underlying: error.localizedDescription)
            }
            session = active
        }
        return try active.sendSync(request)
    }
}
