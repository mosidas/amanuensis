import AppKit
import Testing

@testable import Amanuensis

@Test @MainActor func showSettingsReusesOneWindow() throws {
  _ = NSApplication.shared
  showSettings()
  let first = try #require(settingsWindow)
  defer { first.close() }
  showSettings()
  #expect(settingsWindow === first, "2 回目も同じウィンドウを使う")
  #expect(first.title == "amanuensis の設定")
}
