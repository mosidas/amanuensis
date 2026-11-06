import Foundation

/// 保存先の直下の会議フォルダー 1 つ。
struct Meeting: Equatable {
  /// `RecordingFolder` が録音のときと同じ組み立てで作った URL。`Transcriber.queue` と等価で比べられる。
  let folder: URL
  /// フォルダーの名前が表す日時。一覧の並びの鍵。
  let date: Date
  /// `recording.caf` がある。
  let hasRecording: Bool
  /// `transcript.md` がある。
  let hasTranscript: Bool

  var transcript: URL { folder.appending(path: "transcript.md") }
}

/// 保存先を読んだ結果。
enum MeetingListing: Equatable {
  /// 新しい順。空の配列は録音が 1 つも無い。
  case meetings([Meeting])
  /// 保存先がディレクトリとして無い。`isStandard` は保存先が既定の保存先(利用者が選んでいない)なら true。
  case rootMissing(isStandard: Bool)
  /// 保存先を読めない(アクセス権・プライバシーの許可)。
  case unreadable
}

/// 一覧の行の状態。
enum MeetingStatus: Equatable {
  case recording, transcribing, queued, transcribed, untranscribed, recordingMissing

  /// 優先: 録音中 > 文字起こし中(`queue` の先頭) > 順番待ち > 済み > 録音なし > 未。
  init(of meeting: Meeting, recorder: RecorderState, queue: [URL]) {
    // shortcut: 停止の後の保存中(数秒)は録音中の行を見分けられない(RecorderState.finishing が会議フォルダーを持たない), 書きかけの録音を文字起こしした報告があれば finishing に会議フォルダーを持たせる
    if case .recording(let recording) = recorder, recording.folder == meeting.folder {
      self = .recording
    } else if queue.first == meeting.folder {
      self = .transcribing
    } else if queue.contains(meeting.folder) {
      self = .queued
    } else if meeting.hasTranscript {
      self = .transcribed
    } else if !meeting.hasRecording {
      self = .recordingMissing
    } else {
      self = .untranscribed
    }
  }
}
