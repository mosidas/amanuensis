import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "selfcheck")

/// 設定画面の「音声認識」に出す見出し・本文・塗りのボタン。
struct SpeechSettingsDisplay: Equatable {
  let title: String
  let body: String?
  let isFailure: Bool
  let primary: SpeechButton?
  var showsLog = false
}

struct SpeechButton: Equatable {
  let label: String
  let action: SpeechAction
}

enum SpeechAction {
  case download, reinstall, check
}

enum SpeechSettingsText {
  /// 「ログを表示」で selfcheck.log を開けなかったときの表示。
  static let logOpenFailed = SpeechSettingsDisplay(
    title: "ログを開けませんでした", body: "フォルダーのアクセス権を確かめてください。", isFailure: true, primary: nil)

  /// `state` のときに出す表示。`folder` はランタイムとモデルの保存先。
  static func display(for state: SetupState, folder: URL) -> SpeechSettingsDisplay {
    let retryDownload = SpeechButton(label: "再試行", action: .download)
    return switch state {
    case .notInstalled:
      .init(
        title: "音声認識モデルは未取得です",
        body:
          "ダウンロードの容量は \(bytes(RemoteFile.speechRuntime.byteCount + RemoteFile.haasModel.byteCount)) です。",
        isFailure: false, primary: SpeechButton(label: "ダウンロード", action: .download))
    case .downloading(let received, let total):
      .init(
        title: "ダウンロードしています…",
        body: "\(received * 100 / max(total, 1))%(\(bytes(received)) / \(bytes(total)))",
        isFailure: false, primary: nil)
    case .verifying:
      .init(title: "ダウンロードしたファイルを確認しています…", body: nil, isFailure: false, primary: nil)
    case .checking:
      .init(title: "音声認識の動作を確認しています…", body: nil, isFailure: false, primary: nil)
    case .checked(.passed):
      .init(
        title: "音声認識の準備ができました",
        body: "\((folder.path as NSString).abbreviatingWithTildeInPath) に保存しています。",
        isFailure: false, primary: nil)
    case .checked(.failed):
      .init(
        title: "音声認識が正しく動いていません", body: "ランタイムとモデルを削除して、ダウンロードし直してください。",
        isFailure: true, primary: SpeechButton(label: "再ダウンロード", action: .reinstall),
        showsLog: true)
    case .checked(.timedOut):
      .init(
        title: "音声認識の動作確認が時間内に終わりませんでした", body: "ほかのアプリを終了してから再試行してください。",
        isFailure: true, primary: SpeechButton(label: "再試行", action: .check))
    case .checked(.unavailable):
      .init(
        title: "動作確認用の音声がありません", body: "このビルドには動作確認用の音声が入っていません。", isFailure: false,
        primary: nil)
    case .insufficientSpace(let required, let available):
      .init(
        title: "空き容量が足りません",
        body:
          "ダウンロードには \(bytes(required)) の空きが必要です(今の空きは \(bytes(available)) です)。不要なファイルを削除してから、もう一度お試しください。",
        isFailure: true, primary: retryDownload)
    case .failed(.network):
      .init(
        title: "ダウンロードできませんでした", body: "ネットワークの接続を確かめてから、もう一度お試しください。", isFailure: true,
        primary: retryDownload)
    case .failed(.server):
      .init(
        title: "ダウンロードできませんでした", body: "時間をおいて、もう一度お試しください。", isFailure: true,
        primary: retryDownload)
    case .failed(.checksumMismatch):
      .init(
        title: "ダウンロードしたファイルが壊れていました", body: "もう一度お試しください。", isFailure: true,
        primary: retryDownload)
    case .failed(.fileSystem):
      .init(
        title: "ファイルを保存できませんでした", body: "空き容量とフォルダーのアクセス権を確かめてから、もう一度お試しください。",
        isFailure: true, primary: retryDownload)
    case .failed(.extraction):
      .init(
        title: "音声認識の準備ができませんでした", body: "もう一度お試しください。", isFailure: true,
        primary: retryDownload)
    case .failed(.removal):
      .init(
        title: "古いファイルを削除できませんでした", body: "フォルダーのアクセス権を確かめてから、もう一度お試しください。",
        isFailure: true, primary: SpeechButton(label: "再試行", action: .reinstall))
    }
  }

  private static func bytes(_ count: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    // 既定の adaptive は MB に小数 1 桁を付ける。表の「662 MB」に合わせて整数にする。
    formatter.isAdaptive = false
    return formatter.string(fromByteCount: count)
  }
}

/// 音声認識の準備の状態と、その状態で取れる 1 つの操作。
struct SpeechSettingsView: View {
  let state: SetupState
  let installation: SpeechInstallation
  let perform: (SpeechAction) -> Void
  @State private var logOpenFailed = false

  var body: some View {
    let display = SpeechSettingsText.display(for: state, folder: installation.directory)
    VStack(alignment: .leading, spacing: 8) {
      Message(title: display.title, detail: display.body, isFailure: display.isFailure)
      if case .downloading(let received, let total) = state {
        ProgressView(value: Double(received), total: Double(max(total, 1)))
          .accessibilityLabel(display.title)
      }
      if display.showsLog && logOpenFailed {
        let failure = SpeechSettingsText.logOpenFailed
        Message(title: failure.title, detail: failure.body, isFailure: failure.isFailure)
      }
      if let primary = display.primary {
        HStack {
          Spacer()
          if display.showsLog {
            Button("ログを表示", action: openLog)
          }
          Button(primary.label) { perform(primary.action) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .onChange(of: state) { logOpenFailed = false }
  }

  private func openLog() {
    logOpenFailed = !NSWorkspace.shared.open(installation.selfCheckLog)
    if logOpenFailed {
      logger.error("open log failed error.type=open_failed app.error.origin=system")
    }
  }
}

/// 見出しと本文。失敗は色だけに頼らず印のアイコンでも示す。
struct Message: View {
  let title: String
  let detail: String?
  let isFailure: Bool

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.semibold)
        if let detail {
          Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    } icon: {
      if isFailure {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .accessibilityLabel("エラー")
      }
    }
  }
}
