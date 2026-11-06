import Foundation
import Testing

@testable import Amanuensis

/// 一時ディレクトリの保存先と専用の UserDefaults の suite。`remove()` で両方を消す。
private struct Sandbox {
  let suiteName = "RecordingListTests-\(UUID().uuidString)"
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "RecordingListTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  var root: URL { directory.appending(path: "root", directoryHint: .isDirectory) }
  var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

  init() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  /// 保存先に `root` を選んだ `RecordingFolder`。既定の保存先は別の(作らない)場所。
  func folder() -> RecordingFolder {
    let folder = RecordingFolder(
      defaults: defaults, standardRoot: directory.appending(path: "standard"))
    folder.setRoot(root)
    return folder
  }

  /// 保存先に会議フォルダーを作り、指定のファイルを置く。
  @discardableResult
  func meeting(_ name: String, files: [String] = []) throws -> URL {
    let folder = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    for file in files {
      try Data("x".utf8).write(to: folder.appending(path: file))
    }
    return folder
  }

  func remove() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
}

private func names(_ listing: MeetingListing) -> [String]? {
  guard case .meetings(let meetings) = listing else { return nil }
  return meetings.map(\.folder.lastPathComponent)
}

@Test func meetingsAreNewestFirstWithFileFlags() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  try sandbox.meeting("2026-11-04_090000", files: ["recording.caf", "transcript.md"])
  try sandbox.meeting("2026-11-06_101500", files: ["recording.caf"])
  try sandbox.meeting("2026-11-05_140000")

  guard case .meetings(let meetings) = sandbox.folder().meetings() else {
    Issue.record("保存先が読めれば .meetings")
    return
  }

  #expect(
    meetings.map(\.folder.lastPathComponent)
      == ["2026-11-06_101500", "2026-11-05_140000", "2026-11-04_090000"], "新しい順")
  #expect(meetings.map(\.hasRecording) == [true, false, true])
  #expect(meetings.map(\.hasTranscript) == [false, false, true])
  for meeting in meetings {
    #expect(
      meeting.folder
        == sandbox.root.appending(
          path: meeting.folder.lastPathComponent, directoryHint: .isDirectory),
      "録音側と同じ組み立ての URL")
  }
  #expect(
    meetings.last?.transcript.path
      == sandbox.root.appending(path: "2026-11-04_090000/transcript.md").path)
}

@Test func meetingsSkipNonMeetingEntries() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  try sandbox.meeting("2026-11-06_101500")
  for name in ["notes", "2026-1-6_101500", ".DS_Store"] {
    try sandbox.meeting(name)
  }
  try Data("x".utf8).write(to: sandbox.root.appending(path: "2026-11-06_110000"))
  let elsewhere = sandbox.directory.appending(path: "elsewhere", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(
    at: sandbox.root.appending(path: "2026-11-06_120000"), withDestinationURL: elsewhere)

  #expect(names(sandbox.folder().meetings()) == ["2026-11-06_101500"])
}

@Test func chosenRootMissingIsRootMissing() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let folder = sandbox.folder()
  let missing = sandbox.directory.appending(path: "unplugged-volume/amanuensis")
  folder.setRoot(missing)

  #expect(folder.meetings() == .rootMissing(isStandard: false))
  #expect(
    !FileManager.default.fileExists(
      atPath: sandbox.directory.appending(path: "unplugged-volume").path),
    "選んだ保存先を作らない")

  let file = sandbox.directory.appending(path: "file")
  try Data("x".utf8).write(to: file)
  folder.setRoot(file)
  #expect(folder.meetings() == .rootMissing(isStandard: false), "ファイルは保存先でない")
}

@Test func standardRootNotYetCreatedIsRootMissing() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let standardRoot = sandbox.directory.appending(path: "Documents/amanuensis")
  let folder = RecordingFolder(defaults: sandbox.defaults, standardRoot: standardRoot)

  #expect(folder.meetings() == .rootMissing(isStandard: true))
  #expect(
    !FileManager.default.fileExists(atPath: sandbox.directory.appending(path: "Documents").path),
    "既定の保存先を作らない")
}

@Test func unreadableRootIsUnreadable() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  try sandbox.meeting("2026-11-06_101500")
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o000], ofItemAtPath: sandbox.root.path)
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: sandbox.root.path)
  }

  #expect(sandbox.folder().meetings() == .unreadable)
}

@Test func meetingsAreReadAgainEachCall() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let folder = sandbox.folder()
  #expect(folder.meetings() == .meetings([]), "録音が無ければ空の一覧")

  try sandbox.meeting("2026-11-06_101500", files: ["recording.caf"])

  #expect(names(folder.meetings()) == ["2026-11-06_101500"])
}

private let root = URL(filePath: "/meetings", directoryHint: .isDirectory)

private func meeting(
  _ name: String, hasRecording: Bool = true, hasTranscript: Bool = false
) -> Meeting {
  Meeting(
    folder: root.appending(path: name, directoryHint: .isDirectory),
    date: RecordingFolder.meetingDate(named: name)!, hasRecording: hasRecording,
    hasTranscript: hasTranscript)
}

@Test @MainActor func statusFollowsRecorderAndQueue() async throws {
  let a = meeting("2026-11-06_101500")
  let b = meeting("2026-11-06_113000")
  let done = meeting("2026-11-05_090000", hasTranscript: true)
  let noAudio = meeting("2026-11-04_090000", hasRecording: false)
  let rows: [(Meeting, [URL], MeetingStatus)] = [
    (a, [a.folder, b.folder], .transcribing),
    (b, [a.folder, b.folder], .queued),
    (a, [], .untranscribed),
    (done, [], .transcribed),
    (noAudio, [], .recordingMissing),
    (done, [done.folder], .transcribing),
  ]
  for (meeting, queue, expected) in rows {
    #expect(
      MeetingStatus(of: meeting, recorder: .idle, queue: queue) == expected,
      "\(meeting.folder.lastPathComponent) queue=\(queue.map(\.lastPathComponent))")
  }

  try await withRecording { state, _ in
    guard case .recording(let recording) = state else { return }
    let recordingMeeting = Meeting(
      folder: recording.folder, date: .now, hasRecording: true, hasTranscript: false)
    #expect(MeetingStatus(of: recordingMeeting, recorder: state, queue: []) == .recording)
    #expect(
      MeetingStatus(of: recordingMeeting, recorder: state, queue: [recording.folder]) == .recording,
      "録音中は待ち行列より優先する")
    #expect(MeetingStatus(of: a, recorder: state, queue: []) == .untranscribed, "別の行は録音中にならない")
  }
}
