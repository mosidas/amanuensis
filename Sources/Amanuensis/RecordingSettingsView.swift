import AppKit
import SwiftUI

/// 録音の保存先の表示と変更。
struct RecordingSettingsView: View {
  let folder: RecordingFolder
  @State private var root: URL

  init(folder: RecordingFolder) {
    self.folder = folder
    _root = State(initialValue: folder.root)
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
