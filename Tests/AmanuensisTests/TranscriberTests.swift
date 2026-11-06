import Foundation
import Testing

@testable import Amanuensis

/// 一時ディレクトリの取得先、専用の UserDefaults の suite、偽の文字起こし、通知の記録。
@MainActor private final class Harness {
  let suiteName = "TranscriberTests-\(UUID().uuidString)"
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "TranscriberTests-\(UUID().uuidString)")
  var installation: SpeechInstallation { SpeechInstallation(directory: directory) }
  /// true のあいだ、文字起こしは `release()` まで終わらない。
  var holds = false
  var failing: Set<URL> = []
  /// true なら、呼ばれた会議フォルダーに `transcript.md` を書く。
  var writesTranscript = false
  private(set) var calls: [URL] = []
  private(set) var notices: [TranscriptionNotice] = []
  private(set) var running = 0
  private(set) var maxRunning = 0
  private var pending: [CheckedContinuation<Void, Never>] = []

  func transcriber(autoTranscribe: Bool = true) throws -> Transcriber {
    let setting = TranscriptionSetting(
      defaults: try #require(UserDefaults(suiteName: suiteName)))
    setting.setAutoTranscribe(autoTranscribe)
    return Transcriber(
      installation: installation, setting: setting,
      transcribe: { [unowned self] meeting, _ async throws(TranscriptionFailure) in
        try await transcribe(meeting)
      },
      notify: { [unowned self] in notices.append($0) })
  }

  /// ランタイムとモデルのファイルを置いて取得済みにする。
  func install() throws {
    try FileManager.default.createDirectory(
      at: installation.runtimeDirectory, withIntermediateDirectories: true)
    try Data().write(to: installation.executable)
    try Data().write(to: installation.modelFile)
  }

  func release() {
    if !pending.isEmpty { pending.removeFirst().resume() }
  }

  func remove() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  private func transcribe(_ meeting: URL) async throws(TranscriptionFailure) {
    calls.append(meeting)
    running += 1
    maxRunning = max(maxRunning, running)
    defer { running -= 1 }
    if holds { await withCheckedContinuation { pending.append($0) } }
    if failing.contains(meeting) { throw .recognitionFailed }
    if writesTranscript {
      do {
        try Data("# transcript\n".utf8).write(to: meeting.appending(path: "transcript.md"))
      } catch {
        throw .saveFailed
      }
    }
  }
}

private let first = URL(filePath: "/meetings/2026-11-06_101500", directoryHint: .isDirectory)
private let second = URL(filePath: "/meetings/2026-11-06_113000", directoryHint: .isDirectory)

/// 保存先の一覧が会議フォルダー 1 つでない。
private struct ListingMismatch: Error {}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<500 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Suite(.serialized) @MainActor struct TranscriberTests {
  @Test func savedRecordingIsTranscribedAndNotified() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    harness.holds = true
    let transcriber = try harness.transcriber()

    transcriber.recordingSaved(first)
    try await waitUntil { harness.calls.count == 1 }

    #expect(transcriber.current == first, "処理中はその会議フォルダー")
    harness.release()
    try await waitUntil { transcriber.current == nil }
    #expect(transcriber.current == nil)
    #expect(harness.calls == [first])
    #expect(harness.notices == [.finished(meeting: "2026-11-06_101500")])
  }

  @Test func autoOffOnlyNotifiesSaved() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    let transcriber = try harness.transcriber(autoTranscribe: false)

    transcriber.recordingSaved(first)
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.calls.isEmpty, "自動がオフなら文字起こしを始めない")
    #expect(transcriber.current == nil)
    #expect(harness.notices == [.autoOff(meeting: "2026-11-06_101500")])
  }

  @Test func notInstalledWaitsForSetupThenTranscribes() async throws {
    let harness = Harness()
    defer { harness.remove() }
    let transcriber = try harness.transcriber()

    transcriber.recordingSaved(first)
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.calls.isEmpty, "未取得なら文字起こしを始めない")
    #expect(harness.notices == [.setupRequired(meeting: "2026-11-06_101500")])

    transcriber.resumeAfterSetup()
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.calls.isEmpty, "未取得のままなら再開しない")

    try harness.install()
    transcriber.resumeAfterSetup()
    try await waitUntil { harness.calls.count == 1 && transcriber.current == nil }
    transcriber.resumeAfterSetup()
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.calls == [first], "取得後に同じ録音を 1 回だけ文字起こしする")
    #expect(
      harness.notices == [
        .setupRequired(meeting: "2026-11-06_101500"), .finished(meeting: "2026-11-06_101500"),
      ])
  }

  @Test func failureIsNotifiedAndNextRecordingIsProcessed() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    harness.failing = [first]
    let transcriber = try harness.transcriber()

    transcriber.recordingSaved(first)
    transcriber.recordingSaved(second)
    try await waitUntil { harness.calls.count == 2 && transcriber.current == nil }

    #expect(harness.calls == [first, second])
    #expect(
      harness.notices == [
        .failed(.recognitionFailed, meeting: "2026-11-06_101500"),
        .finished(meeting: "2026-11-06_113000"),
      ])
  }

  @Test func recordingSavedWhileTranscribingWaitsForTheFirst() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    harness.holds = true
    let transcriber = try harness.transcriber()

    transcriber.recordingSaved(first)
    try await waitUntil { harness.calls.count == 1 }
    transcriber.recordingSaved(second)
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.calls == [first], "1 件目が終わるまで 2 件目を始めない")
    #expect(transcriber.current == first)
    harness.release()
    try await waitUntil { harness.calls.count == 2 }
    #expect(transcriber.current == second)
    harness.release()
    try await waitUntil { transcriber.current == nil }

    #expect(harness.calls == [first, second])
    #expect(harness.maxRunning == 1, "speech は同時に 1 つだけ動く")
    #expect(
      harness.notices == [
        .finished(meeting: "2026-11-06_101500"), .finished(meeting: "2026-11-06_113000"),
      ])
  }

  @Test func requestTranscribesEvenWhenAutoIsOff() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    let transcriber = try harness.transcriber(autoTranscribe: false)

    transcriber.request(first)
    try await waitUntil { harness.calls.count == 1 && transcriber.current == nil }

    #expect(harness.calls == [first], "自動がオフでも一覧の要求なら文字起こしする")
    #expect(harness.notices == [.finished(meeting: "2026-11-06_101500")])
  }

  @Test func requestOfQueuedMeetingIsIgnored() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    harness.holds = true
    let transcriber = try harness.transcriber()

    transcriber.request(first)
    transcriber.request(first)
    try await waitUntil { harness.calls.count == 1 }
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.calls == [first], "二重の要求で 2 回目を始めない")
    #expect(transcriber.queue == [first], "待ち行列に 1 回だけ入る")

    transcriber.recordingSaved(second)
    transcriber.request(second)
    #expect(transcriber.queue == [first, second], "自動と手動の重複も 1 回だけ")

    harness.release()
    try await waitUntil { harness.calls.count == 2 }
    harness.release()
    try await waitUntil { transcriber.current == nil }
    #expect(harness.calls == [first, second])

    transcriber.request(first)
    try await waitUntil { harness.calls.count == 3 }
    harness.release()
    try await waitUntil { transcriber.current == nil }
    #expect(harness.calls == [first, second, first], "終わった後は再び要求できる")
  }

  @Test func requestBeforeSetupWaitsOnceAndNotifiesEachTime() async throws {
    let harness = Harness()
    defer { harness.remove() }
    let transcriber = try harness.transcriber()

    transcriber.request(first)
    transcriber.request(first)
    #expect(
      harness.notices == [
        .setupRequired(meeting: "2026-11-06_101500"), .setupRequired(meeting: "2026-11-06_101500"),
      ], "押すたびに通知する")

    try harness.install()
    transcriber.resumeAfterSetup()
    try await waitUntil { harness.calls.count >= 1 && transcriber.current == nil }
    try await Task.sleep(for: .milliseconds(100))

    #expect(harness.calls == [first], "未取得の待ちには 1 回だけ入る")
  }

  @Test func requestedTranscriptAppearsInListing() async throws {
    let harness = Harness()
    defer { harness.remove() }
    try harness.install()
    harness.holds = true
    harness.writesTranscript = true
    let suiteName = "TranscriberTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let root = harness.directory.appending(path: "recordings", directoryHint: .isDirectory)
    let folder = RecordingFolder(
      defaults: try #require(UserDefaults(suiteName: suiteName)), standardRoot: root)
    let meetingFolder = try folder.makeMeetingFolder(at: .now)
    try Data("x".utf8).write(to: meetingFolder.appending(path: "recording.caf"))
    let transcriber = try harness.transcriber(autoTranscribe: false)

    func listed() throws -> Meeting {
      guard case .meetings(let meetings) = folder.meetings(), meetings.count == 1 else {
        throw ListingMismatch()
      }
      return meetings[0]
    }

    let before = try listed()
    #expect(!before.hasTranscript)
    transcriber.request(before.folder)
    try await waitUntil { harness.calls.count == 1 }
    #expect(
      MeetingStatus(of: try listed(), recorder: .idle, queue: transcriber.queue) == .transcribing)

    harness.release()
    try await waitUntil { transcriber.queue.isEmpty }
    let after = try listed()
    #expect(after.hasTranscript)
    #expect(MeetingStatus(of: after, recorder: .idle, queue: transcriber.queue) == .transcribed)
  }

  @Test func stoppingRecordingWritesTranscriptToMeetingFolder() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "TranscriberTests-\(UUID().uuidString)")
    let suiteName = "TranscriberTests-\(UUID().uuidString)"
    defer {
      UserDefaults().removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let installation = try fakeInstallation(
      #"""
      for a in "$@"; do
        case "$a" in *.wav)
          printf '{"file":"%s","text":"","tokens":[{"start":0.2,"end":0.6,"text":"こんにちは"}]}\n' "$a";;
        esac
      done
      """#)
    defer { try? FileManager.default.removeItem(at: installation.directory) }
    try Data().write(to: installation.modelFile)
    var notices: [TranscriptionNotice] = []
    let transcriber = Transcriber(
      installation: installation, setting: TranscriptionSetting(defaults: defaults),
      transcribe: { meeting, installation async throws(TranscriptionFailure) in
        try await transcribe(meeting: meeting, installation: installation)
      },
      notify: { notices.append($0) })
    let folder = RecordingFolder(defaults: defaults, standardRoot: directory)
    var reports: [RecordingProblem] = []
    let recorder = Recorder(
      folder: folder, missingPermissions: { [] },
      startCapture: { file, _ in
        let writer = try FakeWriter(url: file)
        return CaptureSession(stop: { try await writer.finish() })
      },
      report: { reports.append($0) }, saved: transcriber.recordingSaved)

    await recorder.start()
    guard case .recording(let recording) = recorder.state else {
      Issue.record("録音中になる: \(recorder.state)")
      return
    }
    await recorder.stop()
    #expect(transcriber.current == recording.folder, "停止すると文字起こしが始まる")
    try await waitUntil { transcriber.current == nil }

    #expect(reports.isEmpty)
    #expect(notices == [.finished(meeting: recording.folder.lastPathComponent)])
    let transcript = try String(
      contentsOf: recording.folder.appending(path: "transcript.md"), encoding: .utf8)
    #expect(transcript.contains("\n[00:00:00] こんにちは\n"), "\(transcript)")
  }
}

@Suite struct TranscriptionSettingTests {
  @Test func autoTranscribeDefaultsToOnAndKeepsChoice() throws {
    let suiteName = "TranscriptionSettingTests-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let setting = TranscriptionSetting(defaults: defaults)

    #expect(setting.autoTranscribe, "保存値が無ければオン")
    setting.setAutoTranscribe(false)
    #expect(!setting.autoTranscribe)
    defaults.set("broken", forKey: "transcribeAfterRecording")
    #expect(setting.autoTranscribe, "保存値が Bool でなければ既定のオン")
  }
}

/// 文言の表の通知の 1 行。
private struct NoticeRow {
  let name: String
  let notice: TranscriptionNotice
  let title: String
  let body: String
}

private let noticeRows = [
  NoticeRow(
    name: "finished", notice: .finished(meeting: "2026-11-06_101500"), title: "文字起こしが終わりました",
    body: "2026-11-06_101500 のフォルダーに transcript.md を保存しました。"),
  NoticeRow(
    name: "auto-off", notice: .autoOff(meeting: "2026-11-06_101500"), title: "録音を保存しました",
    body: "2026-11-06_101500 に保存しました。設定で自動の文字起こしをオフにしているため、文字起こしは始めていません。"),
  NoticeRow(
    name: "setup-required", notice: .setupRequired(meeting: "2026-11-06_101500"),
    title: "文字起こしを始められませんでした",
    body: "音声認識モデルが未取得です。「設定…」の「音声認識」でダウンロードすると、この録音の文字起こしを始めます。"),
  NoticeRow(
    name: "recognition-failed",
    notice: .failed(.recognitionFailed, meeting: "2026-11-06_101500"), title: "文字起こしできませんでした",
    body:
      "録音は 2026-11-06_101500 に残っています。そのフォルダーの transcription.log を添えて https://github.com/mosidas/amanuensis/issues に報告してください。"
  ),
  NoticeRow(
    name: "audio-unreadable", notice: .failed(.audioUnreadable, meeting: "2026-11-06_101500"),
    title: "文字起こしできませんでした",
    body: "録音のファイルを読み込めませんでした。2026-11-06_101500 に recording.caf があるかを確かめてください。"),
  NoticeRow(
    name: "save-failed", notice: .failed(.saveFailed, meeting: "2026-11-06_101500"),
    title: "文字起こしを保存できませんでした", body: "空き容量とフォルダーのアクセス権を確かめてください。"),
]

@Suite struct TranscriptionTextTests {
  @Test(arguments: noticeRows.map(\.name))
  func noticeTextMatchesTable(name: String) throws {
    let row = try #require(noticeRows.first { $0.name == name })
    #expect(TranscriptionText.title(for: row.notice) == row.title)
    #expect(TranscriptionText.body(for: row.notice) == row.body)
  }

  @Test func menuShowsTranscribingMeeting() {
    #expect(
      MenuContent.transcriptionEntries(for: URL(filePath: "/x/2026-11-06_101500"))
        == [.item("2026-11-06_101500 を文字起こししています…", nil), .separator])
    #expect(MenuContent.transcriptionEntries(for: nil) == [])
  }
}
