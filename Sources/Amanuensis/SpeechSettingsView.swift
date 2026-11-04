import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "settings")

/// 設定画面の「音声認識」に出す文言。状態から一意に決まる。
enum SpeechSettingsText {
  static func title(for state: SetupState) -> String {
    switch state {
    case .notInstalled: "音声認識モデルは未取得です"
    case .downloading: "ダウンロードしています…"
    case .verifying: "ダウンロードしたファイルを確認しています…"
    case .installed: "音声認識モデルは取得済みです"
    case .insufficientSpace: "空き容量が足りません"
    case .failed(.network), .failed(.server): "ダウンロードできませんでした"
    case .failed(.checksumMismatch): "ダウンロードしたファイルが壊れていました"
    case .failed(.fileSystem): "ファイルを保存できませんでした"
    case .failed(.extraction): "音声認識の準備ができませんでした"
    }
  }

  static func body(for state: SetupState) -> String? {
    switch state {
    case .notInstalled:
      "ダウンロードの容量は \(bytes(RemoteFile.speechRuntime.byteCount + RemoteFile.haasModel.byteCount)) です。"
    case .downloading(let received, let total):
      "\(received * 100 / max(total, 1))%(\(bytes(received)) / \(bytes(total)))"
    case .verifying, .installed: nil
    case .insufficientSpace(let required, let available):
      "ダウンロードには \(bytes(required)) の空きが必要です(今の空きは \(bytes(available)) です)。不要なファイルを削除してから、もう一度お試しください。"
    case .failed(.network): "ネットワークの接続を確かめてから、もう一度お試しください。"
    case .failed(.server): "時間をおいて、もう一度お試しください。"
    case .failed(.checksumMismatch), .failed(.extraction): "もう一度お試しください。"
    case .failed(.fileSystem): "空き容量とフォルダーのアクセス権を確かめてから、もう一度お試しください。"
    }
  }

  /// 塗りのボタンの名前。押せる操作が無い状態では nil。
  static func primaryAction(for state: SetupState) -> String? {
    switch state {
    case .notInstalled: "ダウンロード"
    case .insufficientSpace, .failed: "再試行"
    case .downloading, .verifying, .installed: nil
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

/// 音声認識のランタイムとモデルの取得の状態と操作。
struct SpeechSettingsView: View {
  let state: SetupState
  let folder: URL
  let onDownload: () -> Void
  @State private var folderOpenFailed = false

  var body: some View {
    let isFailure =
      switch state {
      case .insufficientSpace, .failed: true
      default: false
      }
    VStack(alignment: .leading, spacing: 8) {
      Message(
        title: SpeechSettingsText.title(for: state), detail: SpeechSettingsText.body(for: state),
        isFailure: isFailure)
      if case .downloading(let received, let total) = state {
        ProgressView(value: Double(received), total: Double(max(total, 1)))
          .accessibilityLabel(SpeechSettingsText.title(for: state))
      }
      HStack {
        if folderOpenFailed {
          Message(
            title: "フォルダーを開けませんでした", detail: "フォルダーのアクセス権を確かめてください。", isFailure: true)
        }
        Spacer()
        Button("Finder で開く", action: openFolder)
        if let action = SpeechSettingsText.primaryAction(for: state) {
          Button(action, action: onDownload)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func openFolder() {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      guard NSWorkspace.shared.open(folder) else { throw CocoaError(.fileReadUnknown) }
      folderOpenFailed = false
    } catch {
      logger.error(
        "open folder failed error.type=\(String(describing: type(of: error)), privacy: .public)")
      folderOpenFailed = true
    }
  }
}

/// 見出しと本文。失敗は色だけに頼らず印のアイコンでも示す。
private struct Message: View {
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
