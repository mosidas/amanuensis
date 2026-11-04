import AppKit
import SwiftUI

@MainActor var settingsWindow: NSWindow?

/// 設定ウィンドウを開く。ウィンドウは 1 つだけ作って使い回す。
@MainActor
func showSettings() {
  let window =
    settingsWindow
    ?? {
      let window = NSWindow(
        contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered,
        defer: false)
      window.title = "amanuensis の設定"
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 520, height: 400))
      settingsWindow = window
      return window
    }()
  // 開くたびにビューを作り直し、保存値とディスクの中身を読み直す。
  speechSetup.refresh()
  let hosting = NSHostingView(rootView: SettingsView())
  hosting.sizingOptions = [.minSize]
  window.contentView = hosting
  window.center()
  NSApp.activate()
  window.makeKeyAndOrderFront(nil)
}

private struct SettingsView: View {
  var body: some View {
    Form {
      Section("音声認識") {
        SpeechSettingsView(
          state: speechSetup.state, selfCheck: speechSetup.selfCheck,
          folder: speechSetup.installation.directory,
          onDownload: { Task { await speechSetup.download() } },
          onSelfCheck: { Task { await speechSetup.runSelfCheck() } })
      }
    }
    .formStyle(.grouped)
  }
}
