import AppKit
import OSLog
import Observation
import UserNotifications

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "menubar")

enum NotificationFailure: Error { case denied, failed }

/// メニューバーのアイコンとメニュー。録音の状態が変わるたびに `MenuContent` から作り直す。
@MainActor
final class MenuBar: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var clock: Timer?

  override init() {
    super.init()
    menu.autoenablesItems = false
    statusItem.menu = menu
    observe()
  }

  /// 状態に応じたメニューバーのアイコン。録音中は `resources` の羽根ペンを抜いた円の TIFF、それ以外は羽根ペンの PDF。
  /// 画像を読めないとき(`swift run`・同梱漏れ)は `waveform` にして、メニューバーの項目を消さない。
  static func icon(for state: RecorderState, resources: URL?) -> NSImage {
    let file =
      switch state {
      case .recording: "MenuBarIconRecording.tiff"
      default: "MenuBarIcon.pdf"
      }
    let image: NSImage
    if let url = resources?.appending(path: file), let loaded = NSImage(contentsOf: url) {
      image = loaded
    } else {
      logger.error(
        "menubar icon missing error.type=menubar_icon_missing app.error.origin=system file=\(file, privacy: .public)"
      )
      image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    }
    image.isTemplate = true
    image.accessibilityDescription = MenuContent.accessibilityName(for: state)
    return image
  }

  /// 失敗を利用者に伝える。権限の不足と開始の失敗は警告で、それ以外は通知で伝える。
  static func present(_ problem: RecordingProblem) {
    if RecordingText.alerts(for: problem) {
      // MainActor のジョブの中の runModal は閉じるまで MainActor の処理を止め、時間切れの後に遅れて始まった
      // 取り込みを止められない。実行ループのブロックから始めたモーダルはメインキューを処理する。
      RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
          if case .missingPermissions(let missing) = problem,
            let action = RecordingText.action(for: problem)
          {
            if alert(problem, buttons: [action, "閉じる"]) == .alertFirstButtonReturn,
              let first = missing.first
            {
              NSWorkspace.shared.open(first.settingsURL)
            }
          } else {
            alert(problem, buttons: ["閉じる"])
          }
        }
      }
      return
    }
    Task {
      do throws(NotificationFailure) {
        try await notify(
          title: RecordingText.title(for: problem), body: RecordingText.body(for: problem))
      } catch {
        alert(problem, buttons: ["閉じる"])
      }
    }
  }

  /// 通知を出す。通知が許可されていなければ `.denied`、バンドルの外・確認や追加の失敗では `.failed` を投げる。
  static func notify(title: String, body: String) async throws(NotificationFailure) {
    // UNUserNotificationCenter.current() はアプリのバンドルの外(swift run・テスト)で落ちる。
    guard Bundle.main.bundleIdentifier != nil else { throw .failed }
    let center = UNUserNotificationCenter.current()
    let granted: Bool
    do {
      granted = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      throw .failed
    }
    guard granted else { throw .denied }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    do {
      try await center.add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    } catch {
      throw .failed
    }
  }

  @discardableResult
  private static func alert(_ problem: RecordingProblem, buttons: [String])
    -> NSApplication.ModalResponse
  {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = RecordingText.title(for: problem)
    alert.informativeText = RecordingText.body(for: problem)
    for button in buttons { alert.addButton(withTitle: button) }
    NSApp.activate()
    return alert.runModal()
  }

  private func observe() {
    let (state, blockedBy) = withObservationTracking {
      (recorder.state, meetingWatcher.blockedBy)
    } onChange: {
      Task { @MainActor [weak self] in self?.observe() }
    }
    render(state, detectionBlockedBy: blockedBy)
  }

  private func render(_ state: RecorderState, detectionBlockedBy: [Permission]) {
    statusItem.button?.image = Self.icon(for: state, resources: Bundle.main.resourceURL)

    menu.removeAllItems()
    for entry in MenuContent.entries(for: state, now: .now, detectionBlockedBy: detectionBlockedBy)
    {
      menu.addItem(item(for: entry))
    }

    clock?.invalidate()
    clock = nil
    guard case .recording = state else { return }
    let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    // メニューを開いている間(イベントトラッキングのモード)も経過時間を進める。
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
  }

  /// 経過時間の行の題だけを今の時刻で書き直す。行の並びは状態が変わるまで変わらない。
  private func tick() {
    let entries = MenuContent.entries(
      for: recorder.state, now: .now, detectionBlockedBy: meetingWatcher.blockedBy)
    for (item, entry) in zip(menu.items, entries) {
      if case .item(let title, _) = entry { item.title = title }
    }
  }

  private func item(for entry: MenuContent.Entry) -> NSMenuItem {
    guard case .item(let title, let action) = entry else { return .separator() }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    switch action {
    case .start: item.action = #selector(start(_:))
    case .stop: item.action = #selector(stop(_:))
    case .discard: item.action = #selector(discard(_:))
    case .settings:
      item.action = #selector(openSettings(_:))
      item.keyEquivalent = ","
    case .quit:
      item.action = #selector(NSApplication.terminate(_:))
      item.keyEquivalent = "q"
    case .systemSettings(let permission):
      item.action = #selector(openSystemSettings(_:))
      item.representedObject = permission.settingsURL
    case nil: break
    }
    item.target = action == .quit ? NSApp : self
    item.isEnabled = action != nil
    return item
  }

  @objc private func start(_ sender: NSMenuItem) {
    Task { await recorder.start() }
  }

  @objc private func stop(_ sender: NSMenuItem) {
    Task { await recorder.stop() }
  }

  @objc private func discard(_ sender: NSMenuItem) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "録音を破棄しますか?"
    alert.informativeText = "この録音の音声ファイルとフォルダーを削除します。元に戻せません。"
    alert.addButton(withTitle: "破棄").hasDestructiveAction = true
    alert.addButton(withTitle: "キャンセル")
    NSApp.activate()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { await recorder.discard() }
  }

  @objc private func openSystemSettings(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func openSettings(_ sender: NSMenuItem) {
    showSettings()
  }
}
