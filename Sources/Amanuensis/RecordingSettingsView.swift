import AppKit
import SwiftUI

/// 録音の保存先とマイクの表示と変更。
struct RecordingSettingsView: View {
  let folder: RecordingFolder
  let microphone: MicrophoneSetting
  let microphones: MicrophoneList
  @State private var root: URL
  @State private var choice: MicrophoneChoice

  init(folder: RecordingFolder, microphone: MicrophoneSetting, microphones: MicrophoneList) {
    self.folder = folder
    self.microphone = microphone
    self.microphones = microphones
    _root = State(initialValue: folder.root)
    _choice = State(initialValue: microphone.choice)
  }

  var body: some View {
    LabeledContent("保存先") {
      HStack {
        Text(NSString(string: root.path).abbreviatingWithTildeInPath)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(root.path)
        Button("変更…", action: chooseRoot)
      }
    }
    let rows = MicrophoneMenu.rows(for: choice, devices: microphones.devices)
    Picker(
      "マイク",
      selection: Binding(
        get: { choice.uid },
        set: { uid in
          guard let row = rows.first(where: { $0.choice.uid == uid }) else { return }
          microphone.setChoice(row.choice)
          choice = row.choice
        })
    ) {
      ForEach(rows, id: \.choice.uid) { row in
        Text(row.label).tag(row.choice.uid)
        if row.choice == .systemDefault { Divider() }
      }
    }
  }

  private func chooseRoot() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.canChooseFiles = false
    panel.title = "録音の保存先を選択"
    panel.message = "会議ごとのフォルダーをこの下に作ります。"
    panel.prompt = "選択"
    panel.directoryURL = root
    guard panel.runModal() == .OK, let url = panel.url else { return }
    folder.setRoot(url)
    root = folder.root
  }
}
