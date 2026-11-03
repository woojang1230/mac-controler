/// 상한 동기화 요청이 몇 개나 응답을 기다리고 있는가.
///
/// **왜 boolean 하나로는 안 되는가.** "보내는 중" 을 bool 로 두고 완료 시
/// 값을 비교해 내리면 고착된다 — 왕복 중 XPC 가 실패해(`helperStatus = nil`)
/// 새 요청이 뜨지 못한 사이 사용자가 값을 바꾸면, 진행 중이던 요청이
/// "내 값이 아니네" 하고 표시를 안 내려 **영영 참으로 남는다.**
/// 그러면 괴리 경고도 안 뜨고 자동 재동기화도 막혀서, 이 표시가 막으려던
/// 실패 모드 그 자체가 된다.
///
/// 값이 아니라 **세대 번호**로 "마지막 요청" 을 판정하면 그 경로가 닫힌다.
public struct LimitSyncTracker: Sendable, Equatable {
    private var issued = 0
    private var settled = 0

    public init() {}

    /// 새 요청을 시작한다. 반환한 세대를 완료 시 `finish(_:)` 에 그대로 넘긴다.
    public mutating func begin() -> Int {
        issued &+= 1
        return issued
    }

    /// 요청 하나가 끝났다.
    ///
    /// 마지막 요청만 진행 표시를 내린다. 앞선 요청이 늦게 끝나도 뒤따르는
    /// 요청의 왕복이 다시 깜빡임으로 새지 않는다.
    public mutating func finish(_ generation: Int) {
        guard generation == issued else { return }
        settled = issued
    }

    /// 아직 응답을 기다리는 요청이 있는가.
    public var isSyncing: Bool { settled != issued }
}
