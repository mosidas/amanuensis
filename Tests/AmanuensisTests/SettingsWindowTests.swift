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

@Test @MainActor func showRecordingsReusesOneWindowAndRereadsFolder() throws {
  _ = NSApplication.shared
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SettingsWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  let root = directory.appending(path: "root", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let suiteName = "SettingsWindowTests-\(UUID().uuidString)"
  defer {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
  let folder = RecordingFolder(
    defaults: try #require(UserDefaults(suiteName: suiteName)),
    standardRoot: directory.appending(path: "standard"))
  folder.setRoot(root)

  #expect(showRecordings(folder: folder) == .meetings([]))
  let first = try #require(recordingsWindow)
  defer { first.close() }
  try FileManager.default.createDirectory(
    at: root.appending(path: "2026-11-06_101500"), withIntermediateDirectories: false)

  guard case .meetings(let meetings) = showRecordings(folder: folder) else {
    Issue.record("保存先が読めれば .meetings")
    return
  }
  #expect(meetings.map(\.folder.lastPathComponent) == ["2026-11-06_101500"], "開き直すと読み直す")
  #expect(recordingsWindow === first, "2 回目も同じウィンドウを使う")
  #expect(first.title == "録音の一覧")

  folder.setRoot(directory.appending(path: "unplugged-volume"))
  #expect(showRecordings(folder: folder) == .rootMissing(isStandard: false))
}

/// 一時ディレクトリにランタイム・Haas・話者分離のモデルを置き、専用の UserDefaults の suite に設定を持つ。
@MainActor private struct EngineHarness {
  let suiteName = "SettingsWindowTests-\(UUID().uuidString)"
  let installation = SpeechInstallation(
    directory: FileManager.default.temporaryDirectory.appending(
      path: "SettingsWindowTests-\(UUID().uuidString)"))
  var setting: TranscriptionSetting {
    TranscriptionSetting(defaults: UserDefaults(suiteName: suiteName)!)
  }

  init() throws {
    try FileManager.default.createDirectory(
      at: installation.runtimeDirectory, withIntermediateDirectories: true)
    for file in [
      installation.executable, installation.modelFile, installation.diarizationModelFile,
    ] {
      try Data().write(to: file)
    }
  }

  func remove() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: installation.directory)
  }
}

/// `EngineSettingsView` をウィンドウに置き、ビューの中のポップアップを返す。
@MainActor private func hostEngineSettings(_ view: EngineSettingsView) throws -> (
  NSWindow, NSPopUpButton
) {
  _ = NSApplication.shared
  let hosting = NSHostingView(rootView: Form { view }.formStyle(.grouped))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: 160), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  hosting.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  let popup = try #require(findPopUp(in: hosting), "「本文のエンジン」のポップアップがある")
  // SwiftUI はメニューを開くときに項目を作るので、開いて閉じる。
  let cell = try #require(popup.cell as? NSPopUpButtonCell)
  let menu = try #require(popup.menu)
  menu.delegate?.menuWillOpen?(menu)
  cell.attachPopUp(withFrame: popup.bounds, in: popup)
  cell.dismissPopUp()
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  return (window, popup)
}

@MainActor private func findPopUp(in view: NSView) -> NSPopUpButton? {
  view as? NSPopUpButton ?? view.subviews.lazy.compactMap { findPopUp(in: $0) }.first
}

/// `condition` が真になるまで 10ms ごとに確かめる。5 秒で諦める。
@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() {
    try #require(ContinuousClock.now < deadline, "5 秒以内に条件を満たす")
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Test @MainActor func choosingWhisperSavesEngineAndShowsWhisperModelMissing() async throws {
  let harness = try EngineHarness()
  defer { harness.remove() }
  let setup = SpeechSetup(
    installation: harness.installation, selfCheck: { _ in .passed }, setting: harness.setting)
  try await waitUntil { setup.state == .checked(.passed) }
  var changes = 0
  let (window, popup) = try hostEngineSettings(EngineSettingsView(setup: setup) { changes += 1 })
  defer { window.close() }
  #expect(popup.itemTitles == ["Haas", "Whisper"], "Haas を先に並べる")
  #expect(popup.title == "Haas", "保存値が無ければ Haas を出す")
  #expect(popup.isEnabled)

  popup.menu?.performActionForItem(at: popup.indexOfItem(withTitle: "Whisper"))

  #expect(harness.setting.engine == .whisper, "選ぶと保存する")
  #expect(
    setup.state == .whisperModelMissing(downloadBytes: RemoteFile.whisperLargeV3Turbo.byteCount))
  #expect(changes == 1)
}

@Test @MainActor func engineCannotBeChosenWhileChecking() async throws {
  let harness = try EngineHarness()
  defer { harness.remove() }
  let (gate, open) = AsyncStream.makeStream(of: Never.self)
  defer { open.finish() }
  let setup = SpeechSetup(
    installation: harness.installation,
    selfCheck: { _ in
      for await _ in gate {}
      return .passed
    }, setting: harness.setting)
  #expect(setup.state == .checking)
  let (window, popup) = try hostEngineSettings(EngineSettingsView(setup: setup) {})
  defer { window.close() }

  #expect(!popup.isEnabled, "確認中は選べない")
}
