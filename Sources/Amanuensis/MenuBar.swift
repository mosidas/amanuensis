import AppKit

/// メニューバーのアイコンとメニュー。設定・終了を置く。
@MainActor
final class MenuBar: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  override init() {
    super.init()
    let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "amanuensis")
    image?.isTemplate = true
    statusItem.button?.image = image

    let menu = NSMenu()
    let settingsItem = NSMenuItem(
      title: "設定…", action: #selector(openSettings(_:)), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(
      title: "amanuensis を終了", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  @objc private func openSettings(_ sender: NSMenuItem) {
    showSettings()
  }
}
