import AppKit
import Testing

@testable import Amanuensis

/// 文言の表の失敗の 1 行。`problem` の見出し・本文・主ボタンの名前。
private struct ProblemRow {
  let name: String
  let problem: RecordingProblem
  let title: String
  let body: String
  var action: String? = nil
}

private let problemRows = [
  ProblemRow(
    name: "missing-microphone", problem: .missingPermissions([.microphone]),
    title: "マイクの使用が許可されていません",
    body: "システム設定の「マイク」で amanuensis を許可してから、もう一度録音を開始してください。", action: "システム設定を開く"),
  ProblemRow(
    name: "missing-system-audio", problem: .missingPermissions([.systemAudio]),
    title: "システム音声の録音が許可されていません",
    body:
      "システム設定の「画面収録とシステムオーディオ録音」にある「システムオーディオ録音のみ」で amanuensis を許可してください。許可した後は amanuensis を開き直してから、録音を開始してください。",
    action: "システム設定を開く"),
  ProblemRow(
    name: "missing-both", problem: .missingPermissions([.microphone, .systemAudio]),
    title: "マイクとシステム音声の録音が許可されていません",
    body:
      "システム設定の「マイク」と、「画面収録とシステムオーディオ録音」にある「システムオーディオ録音のみ」で amanuensis を許可してください。許可した後は amanuensis を開き直してから、録音を開始してください。",
    action: "システム設定を開く"),
  ProblemRow(
    name: "folder-missing", problem: .folderMissing, title: "録音を開始できませんでした",
    body: "保存先のフォルダーが見つかりません。設定で保存先を選び直してください。"),
  ProblemRow(
    name: "folder-not-writable", problem: .folderNotWritable, title: "録音を開始できませんでした",
    body: "保存先のフォルダーに書き込めません。フォルダーのアクセス権を確かめるか、設定で別の保存先を選んでください。"),
  ProblemRow(
    name: "capture-failed", problem: .captureFailed, title: "録音を開始できませんでした",
    body: "もう一度お試しください。"),
  ProblemRow(
    name: "interrupted", problem: .interrupted, title: "録音が途中で止まりました",
    body: "続けて録音するには、もう一度録音を開始してください。"),
  ProblemRow(
    name: "write-failed", problem: .writeFailed, title: "録音を続けられませんでした",
    body: "空き容量を確かめてから、もう一度録音を開始してください。"),
  ProblemRow(
    name: "save-failed", problem: .saveFailed, title: "録音を保存できませんでした",
    body: "空き容量とフォルダーのアクセス権を確かめてください。"),
  ProblemRow(
    name: "discard-failed", problem: .discardFailed, title: "録音を破棄できませんでした",
    body: "Finder で録音のフォルダーを削除してください。"),
]

@Test(arguments: problemRows.map(\.name))
func problemTextMatchesTable(name: String) throws {
  let row = try #require(problemRows.first { $0.name == name })
  #expect(RecordingText.title(for: row.problem) == row.title)
  #expect(RecordingText.body(for: row.problem) == row.body)
  #expect(RecordingText.action(for: row.problem) == row.action)
}

@Test func settingsURLOpensPrivacyPane() {
  #expect(
    Permission.microphone.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  #expect(
    Permission.systemAudio.settingsURL.absoluteString
      == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}

/// 録音中の Recorder を作って `body` に渡し、終わったら止めて保存先を消す。
@MainActor private func withRecording(_ body: (RecorderState, Date) throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "RecordingTextTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let suiteName = "RecordingTextTests-\(UUID().uuidString)"
  defer {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
  let recorder = Recorder(
    folder: RecordingFolder(
      defaults: try #require(UserDefaults(suiteName: suiteName)), standardRoot: directory),
    missingPermissions: { [] }, startCapture: { _, _ in CaptureSession(stop: { 0 }) },
    report: { Issue.record("録音を開始できる: \($0)") })
  await recorder.start()
  guard case .recording(let recording) = recorder.state else {
    Issue.record("録音中になる")
    return
  }
  try body(recorder.state, recording.startedAt)
  await recorder.stop()
}

/// 文言の表のメニューの 1 行。`elapsed` は録音中のときの開始からの秒数。
private struct MenuRow {
  let name: String
  let state: RecorderState?
  var elapsed: TimeInterval = 0
  let entries: [MenuContent.Entry]
}

@Test @MainActor func menuMatchesTable() async throws {
  let settings = MenuContent.Entry.item("設定…", .settings)
  let quit = MenuContent.Entry.item("amanuensis を終了", .quit)
  let rows = [
    MenuRow(
      name: "idle", state: .idle, entries: [.item("録音を開始", .start), settings, .separator, quit]),
    MenuRow(
      name: "starting", state: .starting,
      entries: [.item("録音を準備しています…", nil), settings, .separator, quit]),
    MenuRow(
      name: "recording-12s", state: nil, elapsed: 12,
      entries: [
        .item("録音中 0:00:12", nil), .item("停止", .stop), .item("破棄…", .discard), settings,
        .separator, quit,
      ]),
    MenuRow(
      name: "recording-3725s", state: nil, elapsed: 3_725.9,
      entries: [
        .item("録音中 1:02:05", nil), .item("停止", .stop), .item("破棄…", .discard), settings,
        .separator, quit,
      ]),
    MenuRow(
      name: "finishing", state: .finishing,
      entries: [.item("録音を保存しています…", nil), settings, .separator, quit]),
  ]
  for row in rows {
    if let state = row.state {
      #expect(MenuContent.entries(for: state, now: .now) == row.entries, "\(row.name)")
      continue
    }
    try await withRecording { state, startedAt in
      #expect(
        MenuContent.entries(for: state, now: startedAt.addingTimeInterval(row.elapsed))
          == row.entries, "\(row.name)")
    }
  }
}

@Test @MainActor func iconShowsRecording() async throws {
  let idle = MenuBar.icon(for: .idle, resources: repoResources)
  #expect(idle.isTemplate)
  #expect(idle.representations.contains { $0 is NSPDFImageRep }, "待機時は羽根ペンの PDF")
  #expect(idle.accessibilityDescription == "amanuensis")
  try await withRecording { state, _ in
    let recording = MenuBar.icon(for: state, resources: repoResources)
    #expect(recording.isTemplate)
    #expect(!recording.representations.contains { $0 is NSPDFImageRep }, "録音中は羽根ペンでない")
    #expect(recording.accessibilityDescription == "amanuensis(録音中)")
  }
}

@Test @MainActor func iconFallsBackWithoutPDF() throws {
  let empty = FileManager.default.temporaryDirectory.appending(
    path: "RecordingTextTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: empty) }
  let image = MenuBar.icon(for: .idle, resources: empty)
  #expect(image.isTemplate)
  #expect(!image.representations.contains { $0 is NSPDFImageRep }, "PDF が無ければ SF Symbol")
  #expect(image.accessibilityDescription == "amanuensis")
}

private let repoResources = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources")
