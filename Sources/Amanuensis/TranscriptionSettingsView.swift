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

/// 本文を起こすエンジンの選択。選ぶと下の「音声認識」の表示が選んだエンジンに要るファイルに替わる。
/// 取得と確認の途中は選べない。
struct EngineSettingsView: View {
  let setup: SpeechSetup
  let onChange: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(
        "本文のエンジン",
        selection: Binding(
          get: { setup.engine },
          set: {
            setup.select($0)
            onChange()
          })
      ) {
        Text("Haas").tag(TranscriptionEngine.haas)
        Text("Whisper").tag(TranscriptionEngine.whisper)
      }
      .disabled(setup.isBusy)
      Text("Whisper は英字の略語と数字を正しく起こしやすく、文字起こしに Haas より時間がかかります。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
