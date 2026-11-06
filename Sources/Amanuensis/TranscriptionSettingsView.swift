import SwiftUI

/// 録音を停止したときに自動で文字起こしするかの切り替え。
struct TranscriptionSettingsView: View {
  let setting: TranscriptionSetting
  @State private var autoTranscribe: Bool

  init(setting: TranscriptionSetting) {
    self.setting = setting
    _autoTranscribe = State(initialValue: setting.autoTranscribe)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        "録音を停止したら自動で文字起こし",
        isOn: Binding(
          get: { autoTranscribe },
          set: {
            setting.setAutoTranscribe($0)
            autoTranscribe = setting.autoTranscribe
          }))
      Text("オフにすると、停止したときに通知だけを出します。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
