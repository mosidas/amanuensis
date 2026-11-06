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
