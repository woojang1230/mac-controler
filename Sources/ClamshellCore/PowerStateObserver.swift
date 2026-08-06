import CoreGraphics
import Dispatch
import Foundation
import IOKit.ps
import OSLog
import notify

/// 상태 변화를 **푸시로** 받는다. 폴링하지 않는다.
///
/// 세 가지 소스를 구독한다:
///   - 뚜껑 여닫음: notify 키 `com.apple.system.powermanagement.clamshellstate`
///   - 전원 소스/배터리: `IOPSNotificationCreateRunLoopSource`
///   - 디스플레이 연결/해제: `CGDisplayRegisterReconfigurationCallback`
///
/// 콜백은 아무 스레드에서나 온다. 받는 쪽이 자기 액터로 홉해야 한다.
public final class PowerStateObserver: @unchecked Sendable {

    private static let log = Logger(subsystem: "dev.maccontroler.app", category: "observer")

    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.maccontroler.power-observer")

    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var runLoopSource: CFRunLoopSource?
    private var started = false

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard !started else { return }
        started = true

        // 1) 뚜껑 여닫음. Apple Silicon 에서 powerd 가 이 키를 게시한다.
        //    (Intel 은 게시 경로가 달라 미검증 — DESIGN.md §7 참조)
        let status = notify_register_dispatch(
            "com.apple.system.powermanagement.clamshellstate",
            &notifyToken,
            queue
        ) { [weak self] _ in
            Self.log.notice("clamshellstate 알림 수신")
            self?.onChange()
        }
        Self.log.notice("notify 등록: status=\(status) token=\(self.notifyToken)")

        let context = Unmanaged.passUnretained(self).toOpaque()

        // 2) 전원 소스/배터리 잔량.
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerStateObserver>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, context)?.takeRetainedValue() {
            // 메뉴가 열려 있으면 런루프가 이벤트 트래킹 모드로 바뀐다.
            // commonModes 로 넣어야 그때도 갱신이 들어온다.
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
            Self.log.notice("IOPS 런루프 소스 등록됨")
        } else {
            Self.log.error("IOPS 런루프 소스 생성 실패")
        }

        // 3) 디스플레이 연결/해제.
        CGDisplayRegisterReconfigurationCallback({ _, _, ctx in
            guard let ctx else { return }
            Unmanaged<PowerStateObserver>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, context)
    }

    public func stop() {
        guard started else { return }
        started = false

        if notifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(notifyToken)
            notifyToken = NOTIFY_TOKEN_INVALID
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        CGDisplayRemoveReconfigurationCallback({ _, _, ctx in
            guard let ctx else { return }
            Unmanaged<PowerStateObserver>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}
