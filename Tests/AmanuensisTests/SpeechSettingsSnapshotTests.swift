import AppKit
import SwiftUI
import Testing

@testable import Amanuensis

/// 文言の表の 1 行。`state` と `selfCheck` の見出し・本文・塗りのボタンの名前。
private struct Row {
  let name: String
  let state: SetupState
  var selfCheck = SelfCheckState.idle
  let title: String
  let body: String?
  let primaryAction: String?
}

// 662_469_229 はランタイムとモデルの合計。245_200_000 はその 37.01%。
private let rows = [
  Row(
    name: "not-installed", state: .notInstalled, title: "音声認識モデルは未取得です",
    body: "ダウンロードの容量は 662 MB です。", primaryAction: "ダウンロード"),
  Row(
    name: "downloading",
    state: .downloading(receivedBytes: 245_200_000, totalBytes: 662_469_229),
    title: "ダウンロードしています…", body: "37%(245 MB / 662 MB)", primaryAction: nil),
  Row(
    name: "verifying", state: .verifying, title: "ダウンロードしたファイルを確認しています…", body: nil,
    primaryAction: nil),
  Row(
    name: "installed", state: .installed, title: "音声認識モデルは取得済みです", body: nil,
    primaryAction: "動作確認"),
  Row(
    name: "insufficient-space",
    state: .insufficientSpace(required: 684_000_000, available: 512_000_000),
    title: "空き容量が足りません",
    body: "ダウンロードには 684 MB の空きが必要です(今の空きは 512 MB です)。不要なファイルを削除してから、もう一度お試しください。",
    primaryAction: "再試行"),
  Row(
    name: "failed-network", state: .failed(.network), title: "ダウンロードできませんでした",
    body: "ネットワークの接続を確かめてから、もう一度お試しください。", primaryAction: "再試行"),
  Row(
    name: "failed-server", state: .failed(.server), title: "ダウンロードできませんでした",
    body: "時間をおいて、もう一度お試しください。", primaryAction: "再試行"),
  Row(
    name: "failed-checksum", state: .failed(.checksumMismatch), title: "ダウンロードしたファイルが壊れていました",
    body: "もう一度お試しください。", primaryAction: "再試行"),
  Row(
    name: "failed-file-system", state: .failed(.fileSystem), title: "ファイルを保存できませんでした",
    body: "空き容量とフォルダーのアクセス権を確かめてから、もう一度お試しください。", primaryAction: "再試行"),
  Row(
    name: "failed-extraction", state: .failed(.extraction), title: "音声認識の準備ができませんでした",
    body: "もう一度お試しください。", primaryAction: "再試行"),
  Row(
    name: "selfcheck-running", state: .installed, selfCheck: .running, title: "文字起こししています…",
    body: nil, primaryAction: nil),
  Row(
    name: "selfcheck-passed", state: .installed,
    selfCheck: .finished(SelfCheckResult(transcript: "明日 10時から会議を初めます", cer: 0.042)),
    title: "動作確認の結果", body: "明日 10時から会議を初めます\n文字誤り率(CER)は 4.2% で、基準の 15% 以下です。",
    primaryAction: "動作確認"),
  Row(
    name: "selfcheck-over", state: .installed,
    selfCheck: .finished(SelfCheckResult(transcript: "あした じゅうじから かいぎ", cer: 0.235)),
    title: "動作確認の結果", body: "あした じゅうじから かいぎ\n文字誤り率(CER)は 23.5% で、基準の 15% を超えています。",
    primaryAction: "動作確認"),
  Row(
    name: "selfcheck-unavailable", state: .installed, selfCheck: .unavailable,
    title: "動作確認用の音声がありません", body: "このビルドには動作確認用の音声が入っていません。", primaryAction: nil),
  Row(
    name: "selfcheck-launch-failed", state: .installed, selfCheck: .failed(.launchFailed),
    title: "文字起こしに失敗しました", body: "もう一度お試しください。", primaryAction: "動作確認"),
  Row(
    name: "selfcheck-exited", state: .installed, selfCheck: .failed(.exited(status: 3)),
    title: "文字起こしに失敗しました", body: "もう一度お試しください。", primaryAction: "動作確認"),
  Row(
    name: "selfcheck-timed-out", state: .installed, selfCheck: .failed(.timedOut),
    title: "文字起こしが時間内に終わりませんでした", body: "ほかのアプリを終了してから、もう一度お試しください。",
    primaryAction: "動作確認"),
]

@Test(arguments: rows.map(\.name))
func settingsTextMatchesTable(name: String) throws {
  let row = try #require(rows.first { $0.name == name })
  #expect(SpeechSettingsText.title(for: row.state, selfCheck: row.selfCheck) == row.title)
  #expect(SpeechSettingsText.body(for: row.state, selfCheck: row.selfCheck) == row.body)
  #expect(
    SpeechSettingsText.primaryAction(for: row.state, selfCheck: row.selfCheck) == row.primaryAction)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"] != nil))
@MainActor func writeSnapshots() throws {
  _ = NSApplication.shared
  let directory = URL(
    filePath: try #require(ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"]))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let folder = FileManager.default.temporaryDirectory.appending(path: "amanuensis-snapshot")
  for row in rows {
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let content = Form {
        Section("音声認識") {
          SpeechSettingsView(
            state: row.state, selfCheck: row.selfCheck, folder: folder, onDownload: {},
            onSelfCheck: {})
        }
      }
      .formStyle(.grouped)
      try writeSnapshot(
        content, height: 240, appearance: appearance,
        to: directory.appending(path: "\(row.name)-\(suffix).png"))
    }
  }
  let suiteName = "SpeechSettingsSnapshotTests-\(UUID().uuidString)"
  defer { UserDefaults().removePersistentDomain(forName: suiteName) }
  let recordingFolder = RecordingFolder(defaults: try #require(UserDefaults(suiteName: suiteName)))
  for (name, root) in [
    ("recording-default", nil), ("recording-custom", URL(filePath: "/Volumes/会議の録音/amanuensis")),
  ] {
    if let root { recordingFolder.setRoot(root) }
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let content = Form {
        Section("録音") { RecordingSettingsView(folder: recordingFolder) }
      }
      .formStyle(.grouped)
      try writeSnapshot(
        content, height: 120, appearance: appearance,
        to: directory.appending(path: "\(name)-\(suffix).png"))
    }
  }
}

@MainActor private func writeSnapshot(
  _ content: some View, height: CGFloat, appearance: NSAppearance.Name, to url: URL
) throws {
  let hosting = NSHostingView(rootView: content)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 520, height: height), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: appearance)
  window.contentView = hosting
  hosting.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  let png = try #require(bitmap.representation(using: .png, properties: [:]))
  try png.write(to: url)
  window.close()
}
