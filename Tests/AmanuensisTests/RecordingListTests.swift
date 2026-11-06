import AppKit
import SwiftUI
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

/// `url` に `target` を指す Finder エイリアスのファイルを書く。
private func writeAlias(at url: URL, to target: URL) throws {
  try URL.writeBookmarkData(target.bookmarkData(options: .suitableForBookmarkFile), to: url)
}

@Test func filesPlantedAsLinkAliasOrFIFOAreNotRecordingOrTranscript() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let app = sandbox.directory.appending(path: "X.app", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
  let linked = try sandbox.meeting("2026-11-06_101500")
  try FileManager.default.createSymbolicLink(
    at: linked.appending(path: "transcript.md"), withDestinationURL: app)
  let elsewhere = sandbox.directory.appending(path: "recording.caf")
  try Data("x".utf8).write(to: elsewhere)
  try FileManager.default.createSymbolicLink(
    at: linked.appending(path: "recording.caf"), withDestinationURL: elsewhere)
  let aliased = try sandbox.meeting("2026-11-06_110000")
  try writeAlias(at: aliased.appending(path: "transcript.md"), to: app)
  try #require(mkfifo(aliased.appending(path: "recording.caf").path, 0o644) == 0)

  guard case .meetings(let meetings) = sandbox.folder().meetings() else {
    Issue.record("保存先が読めれば .meetings")
    return
  }

  #expect(meetings.map(\.hasRecording) == [false, false], "リンク・FIFO は録音なし")
  #expect(meetings.map(\.hasTranscript) == [false, false], "リンク・エイリアスは文字起こしなし")
}

@Test func onlyPlainFileMayBeOpened() throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let app = sandbox.directory.appending(path: "X.app", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
  let meeting = try sandbox.meeting("2026-11-06_101500", files: ["transcript.md"])
  let link = sandbox.root.appending(path: "link.md")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
  let alias = sandbox.root.appending(path: "alias.md")
  try writeAlias(at: alias, to: app)

  #expect(RecordingFolder.isPlainFile(meeting.appending(path: "transcript.md")), "通常ファイルは可")
  #expect(!RecordingFolder.isPlainFile(link), "アプリへのシンボリックリンクは不可")
  #expect(!RecordingFolder.isPlainFile(alias), "アプリへのエイリアスは不可")
  #expect(!RecordingFolder.isPlainFile(sandbox.root.appending(path: "missing.md")), "存在しないものは不可")
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

private let transcribeButton = MeetingButton(
  label: "文字起こし", help: "録音から transcript.md を作ります。", action: .transcribe)
private let openButton = MeetingButton(
  label: "開く", help: "transcript.md を既定のアプリで開きます。", action: .open)
private let revealButton = MeetingButton(
  label: "Finder で表示", help: "会議のフォルダーを Finder で表示します。", action: .reveal)

@Test func rowTextMatchesTable() {
  let rows: [(MeetingStatus, MeetingRowDisplay)] = [
    (.transcribed, .init(detail: "文字起こし済み", buttons: [openButton, revealButton])),
    (.untranscribed, .init(detail: "文字起こしはまだありません", buttons: [transcribeButton, revealButton])),
    (.transcribing, .init(detail: "文字起こししています…", buttons: [revealButton])),
    (.queued, .init(detail: "文字起こしの順番を待っています", buttons: [revealButton])),
    (.recording, .init(detail: "録音中", buttons: [revealButton])),
    (.recordingMissing, .init(detail: "録音のファイルがありません", buttons: [revealButton])),
  ]
  for (status, display) in rows {
    #expect(RecordingListText.row(for: status) == display, "\(status)")
  }
  for status in [MeetingStatus.transcribing, .queued] {
    #expect(
      !RecordingListText.row(for: status).buttons.contains { $0.action == .transcribe },
      "\(status) の行で文字起こしを二重に始められない")
  }
}

@Test func meetingTitleIsJapaneseDateAndTime() throws {
  let date = try #require(RecordingFolder.meetingDate(named: "2026-11-06_101500"))
  #expect(RecordingListText.title(for: date) == "2026年11月6日(金) 10:15")
}

@Test func emptyTextMatchesTable() {
  let noRecordings = "メニューの「録音を開始」で録音すると、ここに表示します。"
  let rows: [(MeetingListing, MeetingListEmpty?)] = [
    (.meetings([]), .init(title: "まだ録音がありません", body: noRecordings, opensSettings: false)),
    (
      .rootMissing(isStandard: true),
      .init(title: "まだ録音がありません", body: noRecordings + "保存先は設定で変えられます。", opensSettings: true)
    ),
    (
      .rootMissing(isStandard: false),
      .init(
        title: "保存先のフォルダーが見つかりません", body: "設定で保存先を選び直してから、一覧を開き直してください。",
        opensSettings: true)
    ),
    (
      .unreadable,
      .init(
        title: "保存先のフォルダーを読み込めません",
        body: "フォルダーのアクセス権を確かめるか、設定で別の保存先を選んでから、一覧を開き直してください。", opensSettings: true)
    ),
    (.meetings([meeting("2026-11-06_101500")]), nil),
  ]
  for (listing, empty) in rows {
    #expect(RecordingListText.empty(for: listing) == empty, "\(listing)")
  }
  #expect(RecordingListText.openFailed.title == "文字起こしを開けませんでした")
  #expect(RecordingListText.openFailed.body == "transcript.md が移動か削除されています。一覧を読み直しました。")
}

@Test func transcribeStartsOnlyForMeetingStillUntranscribed() {
  let untranscribed = meeting("2026-11-06_101500")
  let nowTranscribed = meeting("2026-11-06_101500", hasTranscript: true)
  let other = meeting("2026-11-05_090000")
  let rows: [(MeetingListing, [URL], Bool, String)] = [
    (.meetings([untranscribed, other]), [], true, "押した時点でも文字起こし前なら始める"),
    (.meetings([nowTranscribed, other]), [], false, "古い行から押しても済みの transcript.md を上書きしない"),
    (.meetings([untranscribed]), [other.folder, untranscribed.folder], false, "順番待ちなら入れ直さない"),
    (.meetings([other]), [], false, "フォルダーが消えていれば始めない"),
    (.unreadable, [], false, "保存先を読めなければ始めない"),
  ]
  for (listing, queue, expected, reason) in rows {
    #expect(
      shouldTranscribe(untranscribed.folder, in: listing, recorder: .idle, queue: queue)
        == expected, "\(reason)")
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"] != nil))
@MainActor func writeRecordingListSnapshots() async throws {
  _ = NSApplication.shared
  let directory = URL(
    filePath: try #require(ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"]))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let transcribing = meeting("2026-11-06_101500")
  let queued = meeting("2026-11-05_160000")
  let done = meeting("2026-11-05_093000", hasTranscript: true)
  let untranscribed = meeting("2026-11-04_140000")
  let noAudio = meeting("2026-11-03_110000", hasRecording: false)
  let queue = [transcribing.folder, queued.folder]

  func write(
    _ name: String, _ listing: MeetingListing, recorder: RecorderState = .idle,
    openFailed: Bool = false
  ) throws {
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      try writeSnapshot(
        RecordingListView(
          listing: listing, recorder: recorder, queue: queue, openFailed: openFailed,
          perform: { _, _ in }, openSettings: {}
        )
        .frame(width: 520, height: 360)
        .background(Color(nsColor: .windowBackgroundColor)),
        height: 360, appearance: appearance,
        to: directory.appending(path: "list-\(name)-\(suffix).png"))
    }
  }

  try await withRecording { state, _ in
    guard case .recording(let recording) = state else { return }
    let live = Meeting(
      folder: recording.folder, date: RecordingFolder.meetingDate(named: "2026-11-06_143000")!,
      hasRecording: true, hasTranscript: false)
    try write(
      "mixed", .meetings([live, transcribing, queued, done, untranscribed, noAudio]),
      recorder: state)
  }
  try write("empty", .meetings([]))
  try write("standard-root-missing", .rootMissing(isStandard: true))
  try write("root-missing", .rootMissing(isStandard: false))
  try write("unreadable", .unreadable)
  try write("open-failed", .meetings([done, untranscribed, noAudio]), openFailed: true)
}
