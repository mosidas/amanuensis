import AppKit
import Observation
import UserNotifications

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

  /// 失敗を利用者に伝える。権限の不足は警告で、それ以外は通知で伝える。
  static func present(_ problem: RecordingProblem) {
    if case .missingPermissions(let missing) = problem {
      if alert(problem, buttons: ["システム設定を開く", "閉じる"]) == .alertFirstButtonReturn,
        let first = missing.first
      {
        NSWorkspace.shared.open(first.settingsURL)
      }
      return
    }
    // UNUserNotificationCenter.current() はアプリのバンドルの外(swift run・テスト)で落ちる。
    guard Bundle.main.bundleIdentifier != nil else {
      alert(problem, buttons: ["閉じる"])
      return
    }
    Task {
      let center = UNUserNotificationCenter.current()
      do {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
          alert(problem, buttons: ["閉じる"])
          return
        }
        let content = UNMutableNotificationContent()
        content.title = RecordingText.title(for: problem)
        content.body = RecordingText.body(for: problem)
        try await center.add(
          UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
      } catch {
        alert(problem, buttons: ["閉じる"])
      }
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
    let state = withObservationTracking {
      recorder.state
    } onChange: {
      Task { @MainActor [weak self] in self?.observe() }
    }
    render(state)
  }

  private func render(_ state: RecorderState) {
    let image = NSImage(
      systemSymbolName: MenuContent.iconName(for: state),
      accessibilityDescription: MenuContent.accessibilityName(for: state))
    image?.isTemplate = true
    statusItem.button?.image = image

    menu.removeAllItems()
    for entry in MenuContent.entries(for: state, now: .now) {
      menu.addItem(item(for: entry))
    }

    clock?.invalidate()
    clock = nil
    guard case .recording = state else { return }
    let clock = Timer(timeInterval: 1, repeats: true) { _ in
      MainActor.assumeIsolated { [weak self] in self?.tick() }
    }
    // メニューを開いている間(イベントトラッキングのモード)も経過時間を進める。
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
  }

  /// 経過時間の行の題だけを今の時刻で書き直す。行の並びは状態が変わるまで変わらない。
  private func tick() {
    for (item, entry) in zip(menu.items, MenuContent.entries(for: recorder.state, now: .now)) {
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

  @objc private func openSettings(_ sender: NSMenuItem) {
    showSettings()
  }
}
