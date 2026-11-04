import AppKit
import SwiftUI
import Testing

@testable import Amanuensis

/// 文言の表の 1 行。`state` のときに出す見出し・本文・塗りのボタン。
private struct Row {
  let name: String
  let state: SetupState
  let display: SpeechSettingsDisplay
}

private let folder = FileManager.default.homeDirectoryForCurrentUser.appending(
  path: "Library/Application Support/amanuensis")
private let download = SpeechButton(label: "ダウンロード", action: .download)
private let retryDownload = SpeechButton(label: "再試行", action: .download)

// 662_469_229 はランタイムとモデルの合計。245_200_000 はその 37.01%。
private let rows = [
  Row(
    name: "not-installed", state: .notInstalled,
    display: .init(
      title: "音声認識モデルは未取得です", body: "ダウンロードの容量は 662 MB です。", isFailure: false,
      primary: download)),
  Row(
    name: "downloading",
    state: .downloading(receivedBytes: 245_200_000, totalBytes: 662_469_229),
    display: .init(
      title: "ダウンロードしています…", body: "37%(245 MB / 662 MB)", isFailure: false, primary: nil)),
  Row(
    name: "verifying", state: .verifying,
    display: .init(title: "ダウンロードしたファイルを確認しています…", body: nil, isFailure: false, primary: nil)),
  Row(
    name: "checking", state: .checking,
    display: .init(title: "音声認識の動作を確認しています…", body: nil, isFailure: false, primary: nil)),
  Row(
    name: "checked-passed", state: .checked(.passed),
    display: .init(
      title: "音声認識の準備ができました", body: "~/Library/Application Support/amanuensis に保存しています。",
      isFailure: false, primary: nil)),
  Row(
    name: "checked-failed", state: .checked(.failed),
    display: .init(
      title: "音声認識が正しく動いていません", body: "ランタイムとモデルを削除して、ダウンロードし直してください。",
      isFailure: true, primary: SpeechButton(label: "再ダウンロード", action: .reinstall),
      showsLog: true)),
  Row(
    name: "checked-timed-out", state: .checked(.timedOut),
    display: .init(
      title: "音声認識の動作確認が時間内に終わりませんでした", body: "ほかのアプリを終了してから再試行してください。",
      isFailure: true, primary: SpeechButton(label: "再試行", action: .check))),
  Row(
    name: "checked-unavailable", state: .checked(.unavailable),
    display: .init(
      title: "動作確認用の音声がありません", body: "このビルドには動作確認用の音声が入っていません。", isFailure: false,
      primary: nil)),
  Row(
    name: "insufficient-space",
    state: .insufficientSpace(required: 684_000_000, available: 512_000_000),
    display: .init(
      title: "空き容量が足りません",
      body: "ダウンロードには 684 MB の空きが必要です(今の空きは 512 MB です)。不要なファイルを削除してから、もう一度お試しください。",
      isFailure: true, primary: retryDownload)),
  Row(
    name: "failed-network", state: .failed(.network),
    display: .init(
      title: "ダウンロードできませんでした", body: "ネットワークの接続を確かめてから、もう一度お試しください。", isFailure: true,
      primary: retryDownload)),
  Row(
    name: "failed-server", state: .failed(.server),
    display: .init(
      title: "ダウンロードできませんでした", body: "時間をおいて、もう一度お試しください。", isFailure: true,
      primary: retryDownload)),
  Row(
    name: "failed-checksum", state: .failed(.checksumMismatch),
    display: .init(
      title: "ダウンロードしたファイルが壊れていました", body: "もう一度お試しください。", isFailure: true,
      primary: retryDownload)),
  Row(
    name: "failed-file-system", state: .failed(.fileSystem),
    display: .init(
      title: "ファイルを保存できませんでした", body: "空き容量とフォルダーのアクセス権を確かめてから、もう一度お試しください。",
      isFailure: true, primary: retryDownload)),
  Row(
    name: "failed-extraction", state: .failed(.extraction),
    display: .init(
      title: "音声認識の準備ができませんでした", body: "もう一度お試しください。", isFailure: true,
      primary: retryDownload)),
  Row(
    name: "failed-removal", state: .failed(.removal),
    display: .init(
      title: "古いファイルを削除できませんでした", body: "フォルダーのアクセス権を確かめてから、もう一度お試しください。",
      isFailure: true, primary: SpeechButton(label: "再試行", action: .reinstall))),
]

@Test(arguments: rows.map(\.name))
func settingsTextMatchesTable(name: String) throws {
  let row = try #require(rows.first { $0.name == name })
  #expect(SpeechSettingsText.display(for: row.state, folder: folder) == row.display)
}

@Test func logOpenFailedMatchesTable() {
  #expect(
    SpeechSettingsText.logOpenFailed
      == .init(
        title: "ログを開けませんでした", body: "フォルダーのアクセス権を確かめてください。", isFailure: true,
        primary: nil))
}

@Test func noRemovedButtons() {
  for row in rows {
    let label = SpeechSettingsText.display(for: row.state, folder: folder).primary?.label
    #expect(label != "動作確認" && label != "Finder で開く", "\(row.name) に削除したボタンを出さない")
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"] != nil))
@MainActor func writeSnapshots() throws {
  _ = NSApplication.shared
  let directory = URL(
    filePath: try #require(ProcessInfo.processInfo.environment["AMANUENSIS_SNAPSHOT_DIR"]))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for row in rows {
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let content = Form {
        Section("音声認識") {
          SpeechSettingsView(
            state: row.state, installation: SpeechInstallation(directory: folder),
            perform: { _ in })
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
