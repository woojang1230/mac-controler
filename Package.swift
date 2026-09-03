// swift-tools-version: 6.2
import PackageDescription

// 이 프로젝트에는 .xcodeproj 가 없다. SwiftPM 이 바이너리까지 만들고,
// .app 번들 조립은 Scripts/bundle.sh 가 맡는다. 이유는 DESIGN.md §2 참조.
//
// 타깃은 Phase 진행에 따라 늘어난다:
//   Phase 0 — MacControlerApp
//   Phase 1 — + ClamshellCore, ClamshellCoreTests
//   Phase 2 — + HelperProtocol, MacControlerHelper
let package = Package(
    name: "MacControler",
    platforms: [.macOS(.v26)],
    targets: [
        // root 권한이 필요 없는 순수 로직과 시스템 상태 읽기.
        // Phase 2 에서 root 헬퍼도 이 모듈을 쓰므로 defaultIsolation 을 걸지 않는다 —
        // MainActor 를 강제하면 헬퍼(비 UI 프로세스)에서 쓸 수 없다.
        //
        // HelperProtocol 에 의존하는 것은 `AutoReleaseLimit` 하나 때문이다.
        // 자동 해제 상한은 앱이 정하고 헬퍼가 지키는 값이라 양쪽이 **같은 타입**을
        // 봐야 한다. 정책(여기)과 계약(HelperProtocol)에 따로 정의해 두면
        // 두 해석이 갈라질 자리가 생긴다. 방향은 이쪽뿐이다 —
        // HelperProtocol 은 의존성 0 을 유지해야 하고(root 프로세스의 공격 표면),
        // ClamshellCore 는 IOKit·CoreGraphics 를 끌고 온다.
        .target(
            name: "ClamshellCore",
            dependencies: ["HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 앱↔헬퍼 XPC 계약. 의존성 0 — 양쪽이 이것만 공유한다.
        .target(
            name: "HelperProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 헬퍼의 로직. 실행 파일과 분리해 둔 이유는 하나다 — 테스트하기 위해서다.
        // baseline 존중·고아 복구·워치독은 치명 리스크의 유일한 방어선이라
        // 반드시 자동 테스트로 못박아야 한다.
        .target(
            name: "HelperCore",
            dependencies: ["ClamshellCore", "HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // root 로 도는 LaunchDaemon. main.swift 하나뿐이다.
        .executableTarget(
            name: "MacControlerHelper",
            dependencies: ["HelperCore", "ClamshellCore", "HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .executableTarget(
            name: "MacControlerApp",
            dependencies: ["ClamshellCore", "HelperProtocol"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // UI 코드 전체를 기본 MainActor 로. @MainActor 어노테이션 노이즈가 사라진다.
                .defaultIsolation(MainActor.self),
            ]
        ),

        .testTarget(
            name: "ClamshellCoreTests",
            dependencies: ["ClamshellCore", "HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "HelperCoreTests",
            dependencies: ["HelperCore", "ClamshellCore", "HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
