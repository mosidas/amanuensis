import Foundation

/// 一覧の行で押せる操作。
enum MeetingAction {
  case transcribe, open, reveal
}

struct MeetingButton: Equatable {
  let label: String
  let help: String
  let action: MeetingAction
}

/// 一覧の 1 行の状態の本文とボタンの並び。
struct MeetingRowDisplay: Equatable {
  let detail: String
  let buttons: [MeetingButton]
}

/// 一覧に行が無いときに中央に出す見出しと本文。`opensSettings` なら「設定を開く」を出す。
struct MeetingListEmpty: Equatable {
  let title: String
  let body: String
  let opensSettings: Bool
}

/// 録音の一覧の文言。状態から一意に決まる。
enum RecordingListText {
  /// 「開く」で transcript.md を開けなかったときに一覧の上に出す表示。
  static let openFailed = (
    title: "文字起こしを開けませんでした", body: "transcript.md が移動か削除されています。一覧を読み直しました。"
  )

  static func row(for status: MeetingStatus) -> MeetingRowDisplay {
    let transcribe = MeetingButton(
      label: "文字起こし", help: "録音から transcript.md を作ります。", action: .transcribe)
    let open = MeetingButton(
      label: "開く", help: "transcript.md を既定のアプリで開きます。", action: .open)
    let reveal = MeetingButton(
      label: "Finder で表示", help: "会議のフォルダーを Finder で表示します。", action: .reveal)
    return switch status {
    case .transcribed: .init(detail: "文字起こし済み", buttons: [open, reveal])
    case .untranscribed: .init(detail: "文字起こしはまだありません", buttons: [transcribe, reveal])
    case .transcribing: .init(detail: "文字起こししています…", buttons: [reveal])
    case .queued: .init(detail: "文字起こしの順番を待っています", buttons: [reveal])
    case .recording: .init(detail: "録音中", buttons: [reveal])
    case .recordingMissing: .init(detail: "録音のファイルがありません", buttons: [reveal])
    }
  }

  /// 行が 1 つも無いときの表示。行があれば nil。
  static func empty(for listing: MeetingListing) -> MeetingListEmpty? {
    let noRecordings = "メニューの「録音を開始」で録音すると、ここに表示します。"
    return switch listing {
    case .meetings(let meetings):
      meetings.isEmpty
        ? .init(title: "まだ録音がありません", body: noRecordings, opensSettings: false) : nil
    case .rootMissing(isStandard: true):
      .init(title: "まだ録音がありません", body: noRecordings + "保存先は設定で変えられます。", opensSettings: true)
    case .rootMissing(isStandard: false):
      .init(
        title: "保存先のフォルダーが見つかりません", body: "設定で保存先を選び直してから、一覧を開き直してください。",
        opensSettings: true)
    case .unreadable:
      .init(
        title: "保存先のフォルダーを読み込めません",
        body: "フォルダーのアクセス権を確かめるか、設定で別の保存先を選んでから、一覧を開き直してください。", opensSettings: true)
    }
  }

  /// 行の見出しの日時。例: 2026年11月6日(金) 10:15。
  static func title(for date: Date) -> String {
    meetingTitle.string(from: date)
  }

  private static let meetingTitle: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy年M月d日(EEE) H:mm"
    return formatter
  }()
}
