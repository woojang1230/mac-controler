import Testing

@testable import ClamshellCore

/// 진행 표시가 고착되면 괴리 경고와 자동 재동기화가 **함께** 죽는다.
/// 이 타입의 유일한 임무는 그 고착을 구조적으로 막는 것이다.
@Suite("상한 동기화 진행 추적")
struct LimitSyncTrackerTests {

    @Test("처음에는 기다리는 요청이 없다")
    func idleAtStart() {
        #expect(LimitSyncTracker().isSyncing == false)
    }

    @Test("요청을 시작하면 기다리는 중이 되고, 끝나면 풀린다")
    func singleRoundTrip() {
        var tracker = LimitSyncTracker()
        let generation = tracker.begin()
        #expect(tracker.isSyncing)

        tracker.finish(generation)
        #expect(tracker.isSyncing == false)
    }

    @Test("겹친 요청은 마지막 것이 끝나야 풀린다")
    func overlappingRequests() {
        var tracker = LimitSyncTracker()
        let first = tracker.begin()
        let second = tracker.begin()

        tracker.finish(first)
        #expect(tracker.isSyncing, "앞선 요청이 끝났다고 풀면 뒤 요청 왕복이 새어 나온다")

        tracker.finish(second)
        #expect(tracker.isSyncing == false)
    }

    /// bool + 값 비교 구현이 여기서 고착됐다.
    /// 왕복 중 XPC 가 실패해 새 요청이 못 뜬 사이 사용자가 값을 바꾼 상황이다.
    @Test("★ 뒤이은 요청이 아예 못 떠도 진행 표시는 반드시 풀린다")
    func settlesEvenWhenNoFollowUpIsIssued() {
        var tracker = LimitSyncTracker()
        let generation = tracker.begin()

        // 사용자가 값을 바꿨지만 engagedByUs 가 false 라 새 요청이 뜨지 못했다.
        // 진행 중이던 요청이 끝나는 것 말고는 아무 일도 일어나지 않는다.
        tracker.finish(generation)

        #expect(tracker.isSyncing == false, "여기서 고착되면 경고도 자가복구도 죽는다")
    }

    @Test("끝난 세대를 다시 알려도 상태가 흔들리지 않는다")
    func duplicateFinishIsHarmless() {
        var tracker = LimitSyncTracker()
        let generation = tracker.begin()
        tracker.finish(generation)
        tracker.finish(generation)
        #expect(tracker.isSyncing == false)

        let next = tracker.begin()
        #expect(tracker.isSyncing)
        tracker.finish(generation)  // 낡은 세대
        #expect(tracker.isSyncing, "낡은 세대가 새 요청을 풀어버리면 안 된다")
        tracker.finish(next)
        #expect(tracker.isSyncing == false)
    }

    @Test("요청을 많이 겹쳐도 마지막 하나로 수렴한다")
    func manyOverlaps() {
        var tracker = LimitSyncTracker()
        var generations: [Int] = []
        for _ in 0..<50 { generations.append(tracker.begin()) }

        for generation in generations.dropLast() {
            tracker.finish(generation)
            #expect(tracker.isSyncing)
        }
        tracker.finish(generations.last!)
        #expect(tracker.isSyncing == false)
    }
}
