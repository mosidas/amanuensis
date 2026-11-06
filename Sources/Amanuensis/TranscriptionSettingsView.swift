import SwiftUI

/// 録音を停止したときに自動で文字起こしするかと、段落に話者のラベルを付けるかの切り替え。
struct TranscriptionSettingsView: View {
  let setting: TranscriptionSetting
  @State private var autoTranscribe: Bool
  @State private var separateSpeakers: Bool

  init(setting: TranscriptionSetting) {
    self.setting = setting
    _autoTranscribe = State(initialValue: setting.autoTranscribe)
    _separateSpeakers = State(initialValue: setting.separateSpeakers)
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
      Toggle(
        "話者を分ける",
        isOn: Binding(
          get: { separateSpeakers },
          set: {
            setting.setSeparateSpeakers($0)
            separateSpeakers = setting.separateSpeakers
          }))
      Text("transcript.md の段落の先頭に「話者 1:」のようなラベルを付けます。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
