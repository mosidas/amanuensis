import AppKit
import SwiftUI
import Testing

@testable import Amanuensis

// showSettings はウィンドウを 1 つだけ使い回すので、開いて閉じるテストを並行させない。
@Suite(.serialized) struct SettingsWindowTests {
  @Test @MainActor func showSettingsReusesOneWindow() throws {
    _ = NSApplication.shared
    showSettings()
    let first = try #require(settingsWindow)
    defer { first.close() }
    showSettings()
    #expect(settingsWindow === first, "2 回目も同じウィンドウを使う")
    #expect(first.title == "amanuensis の設定")
  }

  @Test @MainActor func autoRecordToggleSavesSetting() throws {
    _ = NSApplication.shared
    let suiteName = "SettingsWindowTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let setting = MeetingDetectionSetting(
      defaults: try #require(UserDefaults(suiteName: suiteName)))
    let hosting = NSHostingView(
      rootView: Form { MeetingDetectionSettingsView(setting: setting) }.formStyle(.grouped))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    // SwiftUI はトグルのラベルを accessibility の要素にせず描くだけなので、ビューの中のスイッチを押す。
    let toggle = try #require(findSwitch(in: hosting))
    #expect(setting.autoRecord, "保存値が無ければオン")
    #expect(toggle.state == .on, "保存値がオンならトグルもオン")
    toggle.performClick(nil)
    #expect(!setting.autoRecord, "切ると保存値が false になる")
    toggle.performClick(nil)
    #expect(setting.autoRecord, "入れ直すと保存値が true に戻る")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"] != nil))
  @MainActor func writeSettingsSnapshot() throws {
    _ = NSApplication.shared
    let directory = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    showSettings()
    let window = try #require(settingsWindow)
    defer { window.close() }
    let content = try #require(window.contentView)
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      content.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: directory.appending(path: "settings-window-\(suffix).png"))
    }
  }
}

@MainActor private func findSwitch(in view: NSView) -> NSSwitch? {
  view as? NSSwitch ?? view.subviews.lazy.compactMap { findSwitch(in: $0) }.first
}
