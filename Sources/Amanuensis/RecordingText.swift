import Foundation

/// 録音の失敗を利用者に伝える文言。失敗から一意に決まる。
enum RecordingText {
  static func title(for problem: RecordingProblem) -> String {
    switch problem {
    case .missingPermissions(let missing):
      switch (missing.contains(.microphone), missing.contains(.systemAudio)) {
      case (true, true): "マイクとシステム音声の録音が許可されていません"
      case (true, false): "マイクの使用が許可されていません"
      case (false, _): "システム音声の録音が許可されていません"
      }
    case .folderMissing, .folderNotWritable, .captureFailed: "録音を開始できませんでした"
    case .interrupted: "録音が途中で止まりました"
    case .writeFailed: "録音を続けられませんでした"
    case .saveFailed: "録音を保存できませんでした"
    case .discardFailed: "録音を破棄できませんでした"
    }
  }

  static func body(for problem: RecordingProblem) -> String {
    switch problem {
    case .missingPermissions(let missing):
      switch (missing.contains(.microphone), missing.contains(.systemAudio)) {
      case (true, true):
        "システム設定の「マイク」と、「画面収録とシステムオーディオ録音」にある「システムオーディオ録音のみ」で amanuensis を許可してください。許可した後は amanuensis を開き直してから、録音を開始してください。"
      case (true, false): "システム設定の「マイク」で amanuensis を許可してから、もう一度録音を開始してください。"
      case (false, _):
        "システム設定の「画面収録とシステムオーディオ録音」にある「システムオーディオ録音のみ」で amanuensis を許可してください。許可した後は amanuensis を開き直してから、録音を開始してください。"
      }
    case .folderMissing: "保存先のフォルダーが見つかりません。設定で保存先を選び直してください。"
    case .folderNotWritable: "保存先のフォルダーに書き込めません。フォルダーのアクセス権を確かめるか、設定で別の保存先を選んでください。"
    case .captureFailed(.noInputDevice):
      "マイクが見つかりません。システム設定の「サウンド」にある「入力」でマイクを選んでから、もう一度録音を開始してください。"
    case .captureFailed(.unsupportedInput(let name, let channels)):
      "「\(name ?? "既定の入力デバイス")」(\(channels) チャンネル)の入力の形式には対応していません。設定の「マイク」で別のマイクを選んでから、もう一度録音を開始してください。"
    case .captureFailed(.selectedMicrophoneMissing(let name)):
      "「\(name)」が見つかりません。マイクを接続するか、設定の「マイク」で別のマイクを選んでから、もう一度録音を開始してください。"
    case .captureFailed(.failed(let step, let type))
    where ["create_tap", "create_aggregate"].contains(step):
      "システム音声を取り込めませんでした。amanuensis を開き直してから録音を開始し、直らないときはエラー(\(step) / \(type))を添えて \(issuesURL) に報告してください。"
    case .captureFailed(.failed(let step, let type)):
      "録音の準備中にエラー(\(step) / \(type))が発生しました。もう一度録音を開始し、直らないときはこのエラーを添えて \(issuesURL) に報告してください。"
    case .interrupted: "続けて録音するには、もう一度録音を開始してください。"
    case .writeFailed: "空き容量を確かめてから、もう一度録音を開始してください。"
    case .saveFailed: "空き容量とフォルダーのアクセス権を確かめてください。"
    case .discardFailed: "Finder で録音のフォルダーを削除してください。"
    }
  }

  static let issuesURL = "https://github.com/mosidas/amanuensis/issues"

  /// 主ボタンの名前。押せる操作が無い失敗では nil。
  static func action(for problem: RecordingProblem) -> String? {
    if case .missingPermissions = problem { "システム設定を開く" } else { nil }
  }

  /// 警告で伝えるなら true、通知で伝えるなら false。権限の不足と開始の失敗は警告で伝える。
  static func alerts(for problem: RecordingProblem) -> Bool {
    switch problem {
    case .missingPermissions, .folderMissing, .folderNotWritable, .captureFailed: true
    case .interrupted, .writeFailed, .saveFailed, .discardFailed: false
    }
  }
}

extension Permission {
  /// システム設定のこの権限の画面。
  var settingsURL: URL {
    switch self {
    case .microphone:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    case .systemAudio:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }
  }
}

/// メニューバーのメニューとアイコン。録音の状態から一意に決まる。
enum MenuContent {
  enum Action { case start, stop, discard, recordings, settings, quit }

  enum Entry: Equatable {
    /// `action` が nil の行は押せない。
    case item(String, Action?)
    case separator
  }

  static func entries(for state: RecorderState, now: Date) -> [Entry] {
    let head: [Entry] =
      switch state {
      case .idle: [.item("録音を開始", .start)]
      case .starting: [.item("録音を準備しています…", nil)]
      case .recording(let recording):
        [
          .item("録音中 \(elapsed(from: recording.startedAt, to: now))", nil), .item("停止", .stop),
          .item("破棄…", .discard),
        ]
      case .finishing: [.item("録音を保存しています…", nil)]
      }
    return head + [
      .item("録音の一覧…", .recordings), .item("設定…", .settings), .separator,
      .item("amanuensis を終了", .quit),
    ]
  }

  static func accessibilityName(for state: RecorderState, transcribing: Bool) -> String {
    if case .recording = state {
      "amanuensis(録音中)"
    } else if transcribing {
      "amanuensis(文字起こし中)"
    } else {
      "amanuensis"
    }
  }

  private static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
}
