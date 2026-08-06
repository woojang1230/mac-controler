import HelperCore

// root 로 도는 LaunchDaemon 의 진입점.
//
// 본체는 HelperCore.HelperDaemon 에 있다. main.swift 최상위 코드는 Swift 6 에서
// MainActor 로 격리되는데, 거기서 만든 클로저를 백그라운드 큐에서 실행하면
// 격리 검사에 걸려 트랩한다. 자세한 내용은 HelperDaemon 주석 참조.
HelperDaemon.run()
