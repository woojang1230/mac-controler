import ClamshellCore
import Dispatch
import Foundation
import HelperProtocol
import OSLog
import XPC

/// LaunchDaemon 본체.
///
/// **왜 `main.swift` 가 아니라 여기 있는가**: Swift 6 에서 `main.swift` 의 최상위
/// 코드는 MainActor 로 격리된다. 거기서 만든 클로저는 그 격리를 물려받으므로,
/// 워치독 타이머가 유틸리티 큐에서 그 클로저를 실행하는 순간 격리 검사에 걸려
/// 프로세스가 트랩한다(실측: `_dispatch_assert_queue_fail` →
/// `swift_task_checkIsolatedSwift`, 30초마다 크래시·재시작).
///
/// `HelperCore` 는 `defaultIsolation` 을 걸지 않았으므로 여기 코드는 nonisolated 다.
public enum HelperDaemon {

    private static let log = Logger(subsystem: "dev.maccontroler.helper", category: "main")

    // 리스너와 타이머는 프로세스 수명 동안 살아 있어야 한다.
    // 스코프를 벗어나 해제되면 mach 서비스가 내려가고 KeepAlive 가 계속 되살린다.
    // 둘 다 dispatchMain() 전에 한 번만 대입하므로 경쟁이 없다.
    nonisolated(unsafe) private static var listener: XPCListener?
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?

    public static func run() -> Never {
        log.notice(
            "헬퍼 기동 uid=\(getuid()) euid=\(geteuid()) 프로토콜=\(HelperConstants.protocolVersion)")

        guard getuid() == 0 || geteuid() == 0 else {
            log.error("root 가 아니면 SleepDisabled 를 쓸 수 없다. 종료.")
            exit(EXIT_FAILURE)
        }

        let service = HelperService(reader: IOKitPowerStateReader())
        service.recoverOrphanIfNeeded()

        // 하트비트 주기의 1/3 로 돌려 타임아웃 판정이 늦어지지 않게 한다.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now() + HelperConstants.heartbeatInterval,
            repeating: HelperConstants.heartbeatInterval / 3
        )
        timer.setEventHandler { service.checkHeartbeat() }
        timer.resume()
        watchdog = timer

        do {
            listener = try XPCListener(service: HelperConstants.machServiceName) { request in
                request.accept { (message: HelperRequest) -> (any Encodable)? in
                    service.handle(message)
                }
            }
        } catch {
            // 여기서 실패하면 XPCListener 가 launchd MachServices 에 바인딩되지 않는다는 뜻이다.
            // 폴백은 NSXPCListener(machServiceName:) — DESIGN.md §8 참조.
            log.error("XPC 리스너 등록 실패: \(error.localizedDescription, privacy: .public)")
            exit(EXIT_FAILURE)
        }
        log.notice("XPC 리스너 등록: \(HelperConstants.machServiceName, privacy: .public)")

        dispatchMain()
    }
}
