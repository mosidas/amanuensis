import Foundation
import Testing

@testable import Amanuensis

/// 一時ディレクトリと専用の UserDefaults の suite。`remove()` で両方を消す。
private struct Sandbox {
  let suiteName = "RecordingFolderTests-\(UUID().uuidString)"
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "RecordingFolderTests-\(UUID().uuidString)")
  var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func folder(standardRoot: URL? = nil) -> RecordingFolder {
    RecordingFolder(
      defaults: defaults, standardRoot: standardRoot ?? directory.appending(path: "standard"))
  }

  func remove() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

@Test func defaultRootIsDocumentsAmanuensis() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let folder = RecordingFolder(defaults: sandbox.defaults)
  #expect(folder.root.path == URL.documentsDirectory.appending(path: "amanuensis").path)
}

@Test func chosenRootIsReadBackByAnotherInstance() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let chosen = sandbox.directory.appending(path: "chosen", directoryHint: .isDirectory)
  sandbox.folder().setRoot(chosen)
  #expect(sandbox.folder().root.path == chosen.path, "別のインスタンスでも選んだフォルダーを読み戻す")
}

@Test func makeMeetingFolderNamesFolderByLocalDateAndTime() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let folder = sandbox.folder()
  folder.setRoot(sandbox.directory)
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let date = try #require(
    calendar.date(
      from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 5, second: 7)))

  let meeting = try folder.makeMeetingFolder(at: date)

  let expected = sandbox.directory.appending(path: "2026-11-04_090507")
  #expect(meeting.path == expected.path)
  var isDirectory: ObjCBool = false
  #expect(FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory))
  #expect(isDirectory.boolValue)
}

@Test func missingChosenRootIsReportedAndNothingIsCreated() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let missing = sandbox.directory.appending(path: "unplugged-volume/amanuensis")
  let folder = sandbox.folder()
  folder.setRoot(missing)

  #expect(throws: RecordingProblem.folderMissing) { try folder.makeMeetingFolder(at: .now) }
  #expect(!exists(sandbox.directory.appending(path: "unplugged-volume")), "選んだ保存先を勝手に作らない")
}

@Test func readOnlyRootIsReportedAsNotWritable() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let readOnly = sandbox.directory.appending(path: "read-only")
  try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
  }
  let folder = sandbox.folder()
  folder.setRoot(readOnly)

  #expect(throws: RecordingProblem.folderNotWritable) { try folder.makeMeetingFolder(at: .now) }
  let contents = try FileManager.default.contentsOfDirectory(atPath: readOnly.path)
  #expect(contents.isEmpty)
}

@Test func existingMeetingFolderIsNotReused() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let folder = sandbox.folder()
  folder.setRoot(sandbox.directory)
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let first = try folder.makeMeetingFolder(at: date)
  let marker = first.appending(path: "recording.caf")
  try Data("earlier".utf8).write(to: marker)

  #expect(throws: RecordingProblem.folderNotWritable) { try folder.makeMeetingFolder(at: date) }
  #expect(try Data(contentsOf: marker) == Data("earlier".utf8), "前の録音を上書きしない")
}

@Test func missingStandardRootIsCreated() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let standardRoot = sandbox.directory.appending(path: "Documents/amanuensis")
  let folder = sandbox.folder(standardRoot: standardRoot)

  let meeting = try folder.makeMeetingFolder(at: .now)

  #expect(exists(meeting))
  #expect(meeting.deletingLastPathComponent().path == standardRoot.path)
}

/// `defaults write` で壊された値。どれも既定の保存先に戻る。
private func brokenValue(_ name: String) -> Any {
  switch name {
  case "relative": "Recordings/amanuensis"
  case "empty": ""
  case "tilde": "~/Recordings"
  case "number": 42
  default: ["/tmp"]
  }
}

@Test(arguments: ["relative", "empty", "tilde", "number", "array"])
func brokenStoredValueFallsBackToStandardRoot(name: String) throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  sandbox.defaults.set(brokenValue(name), forKey: "recordingFolder")
  let standardRoot = sandbox.directory.appending(path: "standard")

  #expect(sandbox.folder(standardRoot: standardRoot).root.path == standardRoot.path)
}

@Test func meetingDateAcceptsOnlyCanonicalNames() throws {
  let date = try #require(RecordingFolder.meetingDate(named: "2026-11-06_101500"))
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let parts = calendar.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: date)
  #expect(
    parts
      == DateComponents(year: 2026, month: 11, day: 6, hour: 10, minute: 15, second: 0))
  for name in [
    "2026-1-6_101500", "2026-11-06_101500 ", "2026-11-06_10150０", "2026-11-06_1015",
    "2026-13-06_101500",
  ] {
    #expect(RecordingFolder.meetingDate(named: name) == nil, "\(name) は形式から外れる")
  }
}
