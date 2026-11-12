import AppKit

/// 録音中に終了を求められたら、録音を保存してから終了する。
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard recorder.state != .idle else { return .terminateNow }
    Task {
      // 準備中と保存中は、録音中か待機中になるまで待つ。
      while recorder.state != .idle {
        await recorder.stop(reason: .appQuit)
        if recorder.state != .idle { try? await Task.sleep(for: .milliseconds(100)) }
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// トップレベルで保持する。delegate は弱参照で、解放されると終了の確認が呼ばれない。
let appDelegate = AppDelegate()
app.delegate = appDelegate

// トップレベルで保持する。解放されるとメニューバーのアイコンが消える。
let menuBar = MenuBar()
meetingWatcher.start()

app.run()
