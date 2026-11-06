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
    name: "no-input-device", problem: .captureFailed(.noInputDevice), title: "録音を開始できませんでした",
    body: "マイクが見つかりません。システム設定の「サウンド」にある「入力」でマイクを選んでから、もう一度録音を開始してください。"),
  ProblemRow(
    name: "selected-microphone-missing",
    problem: .captureFailed(.selectedMicrophoneMissing(name: "Jump Desktop Microphone")),
    title: "録音を開始できませんでした",
    body:
      "「Jump Desktop Microphone」が見つかりません。マイクを接続するか、設定の「マイク」で別のマイクを選んでから、もう一度録音を開始してください。"
  ),
  ProblemRow(
    name: "unsupported-input",
    problem: .captureFailed(.unsupportedInput(name: "Jump Desktop Microphone", channels: 8)),
    title: "録音を開始できませんでした",
    body:
      "「Jump Desktop Microphone」(8 チャンネル)の入力の形式には対応していません。設定の「マイク」で別のマイクを選んでから、もう一度録音を開始してください。"
  ),
  ProblemRow(
    name: "unsupported-input-unnamed",
    problem: .captureFailed(.unsupportedInput(name: nil, channels: 8)), title: "録音を開始できませんでした",
    body:
      "「既定の入力デバイス」(8 チャンネル)の入力の形式には対応していません。設定の「マイク」で別のマイクを選んでから、もう一度録音を開始してください。"
  ),
  ProblemRow(
    name: "tap-create", problem: .captureFailed(.failed(step: "create_tap", type: "-50")),
    title: "録音を開始できませんでした",
    body:
      "システム音声を取り込めませんでした。amanuensis を開き直してから録音を開始し、直らないときはエラー(create_tap / -50)を添えて https://github.com/mosidas/amanuensis/issues に報告してください。"
  ),
  ProblemRow(
    name: "tap-aggregate", problem: .captureFailed(.failed(step: "create_aggregate", type: "-50")),
    title: "録音を開始できませんでした",
    body:
      "システム音声を取り込めませんでした。amanuensis を開き直してから録音を開始し、直らないときはエラー(create_aggregate / -50)を添えて https://github.com/mosidas/amanuensis/issues に報告してください。"
  ),
  ProblemRow(
    name: "unknown",
    problem: .captureFailed(.failed(step: "add_listener", type: "1852797029")),
    title: "録音を開始できませんでした",
    body:
      "録音の準備中にエラー(add_listener / 1852797029)が発生しました。もう一度録音を開始し、直らないときはこのエラーを添えて https://github.com/mosidas/amanuensis/issues に報告してください。"
  ),
  ProblemRow(
    name: "start-timeout", problem: .captureFailed(.failed(step: "start", type: "timeout")),
    title: "録音を開始できませんでした",
    body:
      "録音の準備中にエラー(start / timeout)が発生しました。もう一度録音を開始し、直らないときはこのエラーを添えて https://github.com/mosidas/amanuensis/issues に報告してください。"
  ),
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

/// 録音中と終了時の失敗だけが通知で、権限の不足と開始の失敗は警告で伝わる。
private let notifiedRows: Set = ["interrupted", "write-failed", "save-failed", "discard-failed"]

@Test(arguments: problemRows.map(\.name))
func startFailuresAlertOthersNotify(name: String) throws {
  let row = try #require(problemRows.first { $0.name == name })
  #expect(RecordingText.alerts(for: row.problem) == !notifiedRows.contains(name), "\(name)")
}

@Test(arguments: [
  ("start_device", "-10851"), ("find_microphone", "-50"), ("create_ioproc", "no_ioproc"),
  ("x", "y"),
])
func startFailureTextIsNeverEmpty(step: String, type: String) {
  let problem = RecordingProblem.captureFailed(.failed(step: step, type: type))
  #expect(!RecordingText.title(for: problem).isEmpty)
  let body = RecordingText.body(for: problem)
  #expect(body.contains(step), "本文が step を含む")
  #expect(body.contains(type), "本文が type を含む")
}

@Test func startFailureKeepsLogNames() {
  let cases: [(StartFailure, String, String)] = [
    (.noInputDevice, "find_microphone", "no_input_device"),
    (.unsupportedInput(name: "A", channels: 8), "find_microphone", "unsupported_format"),
    (.selectedMicrophoneMissing(name: "A"), "find_microphone", "selected_device_missing"),
    (.failed(step: "create_tap", type: "-50"), "create_tap", "-50"),
  ]
  for (failure, step, type) in cases {
    #expect(failure.step == step, "\(failure)")
    #expect(failure.type == type, "\(failure)")
  }
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
@MainActor func withRecording(_ body: (RecorderState, Date) throws -> Void) async throws {
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
    report: { Issue.record("録音を開始できる: \($0)") }, saved: { _ in })
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
  var blockedBy: [Permission] = []
  let entries: [MenuContent.Entry]
}

@Test @MainActor func menuMatchesTable() async throws {
  let recordings = MenuContent.Entry.item("録音の一覧…", .recordings)
  let settings = MenuContent.Entry.item("設定…", .settings)
  let quit = MenuContent.Entry.item("amanuensis を終了", .quit)
  let rows = [
    MenuRow(
      name: "idle", state: .idle,
      entries: [.item("録音を開始", .start), recordings, settings, .separator, quit]),
    MenuRow(
      name: "starting", state: .starting,
      entries: [.item("録音を準備しています…", nil), recordings, settings, .separator, quit]),
    MenuRow(
      name: "recording-12s", state: nil, elapsed: 12,
      entries: [
        .item("録音中 0:00:12", nil), .item("停止", .stop), .item("破棄…", .discard), recordings, settings,
        .separator, quit,
      ]),
    MenuRow(
      name: "recording-3725s", state: nil, elapsed: 3_725.9,
      entries: [
        .item("録音中 1:02:05", nil), .item("停止", .stop), .item("破棄…", .discard), recordings, settings,
        .separator, quit,
      ]),
    MenuRow(
      name: "finishing", state: .finishing,
      entries: [.item("録音を保存しています…", nil), recordings, settings, .separator, quit]),
    MenuRow(
      name: "idle-blocked-microphone", state: .idle, blockedBy: [.microphone],
      entries: [
        .item("録音を開始", .start), .separator, .item("会議の検知を停止しています", nil),
        .item("マイクの使用が許可されていません", nil), .item("システム設定を開く", .systemSettings(.microphone)),
        .separator, recordings, settings, .separator, quit,
      ]),
    MenuRow(
      name: "idle-blocked-system-audio", state: .idle, blockedBy: [.systemAudio],
      entries: [
        .item("録音を開始", .start), .separator, .item("会議の検知を停止しています", nil),
        .item("システム音声の録音が許可されていません", nil),
        .item("システム設定を開く", .systemSettings(.systemAudio)), .separator, recordings, settings,
        .separator,
        quit,
      ]),
    MenuRow(
      name: "recording-blocked-both", state: nil, elapsed: 12,
      blockedBy: [.microphone, .systemAudio],
      entries: [
        .item("録音中 0:00:12", nil), .item("停止", .stop), .item("破棄…", .discard), .separator,
        .item("会議の検知を停止しています", nil), .item("マイクとシステム音声の録音が許可されていません", nil),
        .item("システム設定を開く", .systemSettings(.microphone)), .separator, recordings, settings,
        .separator,
        quit,
      ]),
  ]
  for row in rows {
    if let state = row.state {
      #expect(
        MenuContent.entries(for: state, now: .now, detectionBlockedBy: row.blockedBy)
          == row.entries, "\(row.name)")
      continue
    }
    try await withRecording { state, startedAt in
      #expect(
        MenuContent.entries(
          for: state, now: startedAt.addingTimeInterval(row.elapsed),
          detectionBlockedBy: row.blockedBy) == row.entries, "\(row.name)")
    }
  }
}

@Test @MainActor func iconShowsRecording() async throws {
  let idle = MenuBar.icon(for: .idle, transcribing: false, resources: repoResources)
  #expect(idle.isTemplate)
  #expect(idle.representations.contains { $0 is NSPDFImageRep }, "待機時は羽根ペンの PDF")
  #expect(idle.accessibilityDescription == "amanuensis")
  try await withRecording { state, _ in
    let recording = MenuBar.icon(for: state, transcribing: false, resources: repoResources)
    #expect(recording.isTemplate)
    #expect(!recording.representations.contains { $0 is NSPDFImageRep }, "録音中は待機時の PDF でない")
    let bitmaps = recording.representations.compactMap { $0 as? NSBitmapImageRep }
    #expect(Set(bitmaps.map(\.pixelsWide)) == [18, 36], "録音中は @1x と @2x のビットマップ")
    for rep in bitmaps {
      // SVG の座標(左上が原点、18pt)。半径 8.5 の円から 0.92 倍の羽根ペンを抜いた形。
      let scale = Double(rep.pixelsWide) / 18
      func alpha(_ x: Double, _ y: Double) -> CGFloat? {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent
      }
      #expect(alpha(0, 0) == 0, "\(rep.pixelsWide)px: 角は円の外")
      #expect(alpha(4, 5) == 1, "\(rep.pixelsWide)px: 円の内で羽根ペンの外は塗る")
      #expect(alpha(10.4, 6.8) == 0, "\(rep.pixelsWide)px: 羽は抜く")
      #expect(alpha(11, 15.4) == 1, "\(rep.pixelsWide)px: 下線は抜かない")
    }
    let pixels = try #require(recording.tiffRepresentation)
    #expect(pixels != symbolPixels("record.circle"), "録音中は record.circle でない")
    #expect(pixels != symbolPixels("waveform"), "録音中は読めないときの waveform とも違う")
    #expect(recording.accessibilityDescription == "amanuensis(録音中)")
  }
}

@Test @MainActor func iconShowsTranscribing() async throws {
  let transcribing = MenuBar.icon(for: .idle, transcribing: true, resources: repoResources)
  #expect(transcribing.isTemplate)
  #expect(
    !transcribing.representations.contains { $0 is NSPDFImageRep }, "文字起こし中は待機時の PDF でない")
  #expect(transcribing.tiffRepresentation == symbolPixels("pencil.and.scribble"))
  #expect(transcribing.accessibilityDescription == "amanuensis(文字起こし中)")
  try await withRecording { state, _ in
    let recording = MenuBar.icon(for: state, transcribing: true, resources: repoResources)
    let bitmaps = recording.representations.compactMap { $0 as? NSBitmapImageRep }
    #expect(Set(bitmaps.map(\.pixelsWide)) == [18, 36], "録音中は文字起こし中でも録音の TIFF")
    #expect(recording.accessibilityDescription == "amanuensis(録音中)")
  }
}

@Test @MainActor func iconFallsBackWithoutPDF() async throws {
  let empty = FileManager.default.temporaryDirectory.appending(
    path: "RecordingTextTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: empty) }
  let image = MenuBar.icon(for: .idle, transcribing: false, resources: empty)
  #expect(image.isTemplate)
  #expect(!image.representations.contains { $0 is NSPDFImageRep }, "PDF が無ければ SF Symbol")
  #expect(image.accessibilityDescription == "amanuensis")
  try await withRecording { state, _ in
    let recording = MenuBar.icon(for: state, transcribing: false, resources: empty)
    #expect(recording.isTemplate)
    #expect(
      !recording.representations.contains {
        [18, 36].contains(($0 as? NSBitmapImageRep)?.pixelsWide)
      },
      "TIFF が無ければ録音中も SF Symbol")
    #expect(recording.accessibilityDescription == "amanuensis(録音中)")
  }
}

private func symbolPixels(_ name: String) -> Data? {
  NSImage(systemSymbolName: name, accessibilityDescription: nil)?.tiffRepresentation
}

private let repoResources = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources")
