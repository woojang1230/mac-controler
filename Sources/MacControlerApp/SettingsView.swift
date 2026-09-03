import AppKit
import ClamshellCore
import HelperProtocol
import SwiftUI

/// 옵션 창. `Settings` Scene 에 담기므로 ⌘, 로도 열린다.
///
/// 여기서 바꿀 수 있는 것은 **시간 제한 하나뿐**이다. 나머지 안전장치
/// (하트비트 워치독·부팅 세션 고아 복구·배터리 임계)는 끄지 못한다 —
/// 그것들이 없으면 앱이 죽거나 배터리가 바닥나도 맥이 계속 깨어 있게 되고,
/// 사용자가 되돌릴 방법이 남지 않는다. 그래서 무엇이 꺼지고 무엇이 안 꺼지는지를
/// 창 안에 그대로 적는다. 조용한 안전장치는 없느니만 못하다.
struct SettingsView: View {
    let model: AppModel

    private var limit: Binding<AutoReleaseLimit> {
        Binding(get: { model.settings.autoRelease }, set: { model.setAutoRelease($0) })
    }

    var body: some View {
        Form {
            Section {
                Picker("시간 제한", selection: limit) {
                    // 프리셋이 아니라 `choices` 를 쓴다 — 저장된 값이 프리셋 밖이면
                    // Picker 가 빈칸이 되어 현재 설정을 화면에서 알 수 없다.
                    ForEach(
                        AutoReleaseLimit.choices(including: model.settings.autoRelease),
                        id: \.self
                    ) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("현재 상태") {
                    Text(model.scheduledReleaseDescription)
                        .foregroundStyle(.secondary)
                }

                // 앱이 보낸 값이 헬퍼에 **끝내** 안 닿았을 때만 알린다.
                // 설정 창이 바뀐 값을 보여주는데 실제로 지켜지는 값이 다르면
                // 그것이 가장 위험한 상태다. 다만 왕복 중(33밀리초)은 두 값이
                // 다른 것이 정상이므로, 그때 띄우면 깜빡임밖에 안 된다.
                // 판정은 `ClamshellPolicy.shouldWarnLimitMismatch` 가 한다.
                if model.shouldWarnLimitMismatch, let helper = model.helperAutoRelease {
                    Label(
                        "헬퍼가 아직 \(helper.displayName) 로 동작 중입니다",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("자동 해제")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("정해진 시간이 지나면 슬립 차단을 원래 값으로 되돌립니다.")
                    Text("‘꺼짐’ 을 고르면 시간으로는 해제하지 않습니다. 직접 끌 때까지 유지됩니다.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            Section {
                ForEach(Self.alwaysOnGuards, id: \.self) { line in
                    Label(line, systemImage: "checkmark.shield")
                        .labelStyle(.titleAndIcon)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                Text("끄지 못하는 안전장치")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("시간 제한을 ‘꺼짐’ 으로 두어도 위 셋은 그대로 동작합니다.")

                    // 위 문구를 무조건적 보증으로 읽으면 안 된다. 앞의 두 안전장치는
                    // **헬퍼가 살아 있을 때만** 동작하고, 시간 제한은 헬퍼까지 반복해서
                    // 죽는 경우에 대한 유일한 방어선이다(DESIGN.md §7-2 (3)).
                    // '꺼짐' 을 고른 사람에게는 그 사실을 알려야 위험을 제대로 계산한다.
                    if model.settings.autoRelease == .never {
                        Label(
                            "다만 앞의 둘은 헬퍼가 살아 있을 때만 동작합니다."
                                + " 시간 제한은 헬퍼까지 반복해서 죽는 드문 경우의 마지막 방어선인데,"
                                + " ‘꺼짐’ 은 그것까지 없앱니다.",
                            systemImage: "info.circle"
                        )
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // LSUIElement(.accessory) 앱의 창은 열려도 앞으로 안 나오는 경우가 있다.
        .onAppear { NSApp.activate() }
    }

    private static let alwaysOnGuards = [
        "배터리 15% 미만이면 시간 제한과 무관하게 해제합니다",
        "앱이 예기치 않게 종료되면 90초 안에 헬퍼가 되돌립니다",
        "재부팅 후 남은 흔적은 헬퍼가 기동 즉시 되돌립니다",
    ]
}
