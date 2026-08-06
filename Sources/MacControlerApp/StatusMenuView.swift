import AppKit
import ClamshellCore
import SwiftUI

/// 메뉴바 아이콘을 클릭했을 때 펼쳐지는 메뉴의 내용물.
///
/// Phase 1 은 **읽기 전용**이다. 시스템을 전혀 바꾸지 않는다.
/// 클램쉘 토글은 Phase 2 에서 root 헬퍼와 함께 들어온다.
struct StatusMenuView: View {
    let model: AppModel

    var body: some View {
        // 사용자가 실제로 알고 싶은 것은 이 한 줄이다.
        Text(model.isAwakeOnLidClose ? "지금 뚜껑 닫아도 안 잠" : "지금 뚜껑 닫으면 잠")

        Divider()

        Text("뚜껑: \(model.snapshot.lidClosed ? "닫힘" : "열림")")
        Text("닫으면 자는 조건: \(model.snapshot.clamshellCausesSleep ? "예" : "아니오")")
        Text("슬립 차단(SleepDisabled): \(model.snapshot.sleepDisabled ? "켜짐" : "꺼짐")")
        Text(powerDescription)
        Text("외부 디스플레이: \(model.snapshot.externalDisplayCount)대")

        Divider()

        if model.blockers.isEmpty {
            Text("슬립을 막는 프로세스 없음")
        } else {
            Menu("슬립 막는 프로세스 \(model.blockers.count)개") {
                ForEach(model.blockers) { blocker in
                    Text("\(blocker.processName) — \(blocker.assertionTypes.joined(separator: ", "))")
                }
                Divider()
                // 오해를 막는다: 이 목록에 뭐가 있든 뚜껑 닫힘은 못 막는다.
                Text("※ 이들 중 어느 것도 뚜껑 닫힘 슬립은 막지 못합니다")
            }
        }

        if !model.statusItemVisible {
            Divider()
            Text("⚠︎ 이 아이콘이 노치에 가려 있거나 화면 밖에 있습니다")
            Text("   메뉴바 아이콘을 ⌘-드래그해 자리를 만들어 주세요")
        }

        Divider()

        Toggle(
            "뚜껑 닫아도 안 자기",
            isOn: Binding(get: { model.engagedByUs }, set: { model.setEngaged($0) })
        )
        .disabled(model.toggleBlockedReason != nil)

        // 켤 수 없으면 왜 못 켜는지 바로 아래에 적는다.
        if let reason = model.toggleBlockedReason {
            Text("   \(reason)")
        } else if let status = model.helperStatus,
                  status.engagedByUs,
                  let baseline = status.baselineSleepDisabled {
            Text("   (해제하면 원래 값 \(baseline ? "켜짐" : "꺼짐") 으로 되돌립니다)")
        }

        if let message = model.lastMessage, message != model.toggleBlockedReason {
            Text("   \(message)")
        }

        Divider()

        Button("지금 새로고침") { model.refresh() }
            .keyboardShortcut("r")

        Button("헬퍼 상태 갱신") { Task { await model.syncHelperStatus() } }

        Button("종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var powerDescription: String {
        let source: String
        switch model.snapshot.powerSource {
        case .ac: source = "전원 어댑터"
        case .battery: source = "배터리"
        case .unknown: source = "알 수 없음"
        }
        guard let percent = model.snapshot.batteryPercent else { return "전원: \(source)" }
        return "전원: \(source) · \(percent)%"
    }
}
