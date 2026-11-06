import SwiftUI

/// 会議を検知したときに自動で録音するかの切り替え。
struct MeetingDetectionSettingsView: View {
  let setting: MeetingDetectionSetting
  @State private var autoRecord: Bool

  init(setting: MeetingDetectionSetting) {
    self.setting = setting
    _autoRecord = State(initialValue: setting.autoRecord)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        "会議を検知したら自動で録音",
        isOn: Binding(
          get: { autoRecord },
          set: {
            setting.setAutoRecord($0)
            autoRecord = setting.autoRecord
          }))
      Text(
        "Zoom・Microsoft Teams・Google Meet(Google Chrome)・Slack のハドルを検知します。オフにすると、検知したときに通知だけを出します。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
