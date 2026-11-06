import Foundation

/// 文字起こしの結果を利用者に伝える通知の文言。通知の種類から一意に決まる。
enum TranscriptionText {
  static func title(for notice: TranscriptionNotice) -> String {
    switch notice {
    case .finished: "文字起こしが終わりました"
    case .autoOff: "録音を保存しました"
    case .setupRequired: "文字起こしを始められませんでした"
    case .failed(.recognitionFailed, _), .failed(.audioUnreadable, _): "文字起こしできませんでした"
    case .failed(.saveFailed, _): "文字起こしを保存できませんでした"
    case .finishedWithoutSpeakers: "話者を分けずに文字起こししました"
    }
  }

  static func body(for notice: TranscriptionNotice) -> String {
    switch notice {
    case .finished(let meeting): "\(meeting) のフォルダーに transcript.md を保存しました。"
    case .autoOff(let meeting): "\(meeting) に保存しました。設定で自動の文字起こしをオフにしているため、文字起こしは始めていません。"
    case .setupRequired: "音声認識モデルが未取得です。「設定…」の「音声認識」でダウンロードすると、この録音の文字起こしを始めます。"
    case .failed(.recognitionFailed, let meeting):
      "録音は \(meeting) に残っています。そのフォルダーの transcription.log を添えて \(RecordingText.issuesURL) に報告してください。"
    case .failed(.audioUnreadable, let meeting):
      "録音のファイルを読み込めませんでした。\(meeting) に recording.caf があるかを確かめてください。"
    case .failed(.saveFailed, _): "空き容量とフォルダーのアクセス権を確かめてください。"
    case .finishedWithoutSpeakers(.modelMissing, _):
      "話者分離のモデルが未取得です。「設定…」の「音声認識」でダウンロードすると、次の文字起こしから話者を分けます。"
    case .finishedWithoutSpeakers(.failed, let meeting):
      "話者分離が失敗しました。\(meeting) の transcription.log を添えて \(RecordingText.issuesURL) に報告してください。"
    }
  }
}

extension MenuContent {
  /// 文字起こし中の録音の行。メニューの先頭に置く。
  static func transcriptionEntries(for meeting: URL?) -> [Entry] {
    guard let meeting else { return [] }
    return [.item("\(meeting.lastPathComponent) を文字起こししています…", nil), .separator]
  }
}
