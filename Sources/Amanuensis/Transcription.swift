import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "transcription")

/// 利用者に見せる文字起こしの失敗の区別。ログの `error.type` はこれより細かい。
enum TranscriptionFailure: Error, Equatable {
  case audioUnreadable, recognitionFailed, saveFailed
}

/// 「話者を分ける」がオンなのに話者のラベルを付けなかった理由。
enum SpeakerSkip: Equatable {
  case modelMissing, failed
}

/// 会議フォルダーの `recording.caf` を文字起こしし、同じフォルダーの `transcript.md` に書く(既にあれば置き換える)。
/// 録音は消さず動かさない。認識と話者分離の失敗は `transcription.log` に 1 行追記する。
/// `separateSpeakers` なら段落に話者のラベルを付ける。付けられなければラベル無しで書き、その理由を返す。
@discardableResult
func transcribe(meeting: URL, installation: SpeechInstallation, separateSpeakers: Bool)
  async throws(TranscriptionFailure) -> SpeakerSkip?
{
  let name = meeting.lastPathComponent
  let log = meeting.appending(path: "transcription.log")
  let started = ContinuousClock.now
  logger.info("transcription started folder.name=\(name, privacy: .public)")

  func failed(
    _ failure: TranscriptionFailure, step: String, type: String, status: Int32? = nil,
    stderr: String = ""
  ) -> TranscriptionFailure {
    let status = status.map(String.init) ?? "none"
    logger.error(
      "transcription failed step=\(step, privacy: .public) error.type=\(type, privacy: .public) app.error.origin=system status=\(status, privacy: .public) folder.name=\(name, privacy: .public) stderr=\(stderr, privacy: .private)"
    )
    return failure
  }

  // shortcut: 文字起こし中にアプリが終了すると一時ディレクトリの音声の写しが OS の掃除まで残る(起動時の削除は入れていない), 残った写しが問題になる報告があれば起動時に `amanuensis-transcription-*` を削除する
  let temporary = FileManager.default.temporaryDirectory.appending(
    path: "amanuensis-transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
  do {
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  } catch {
    throw failed(.saveFailed, step: "prepare", type: "file_system")
  }
  defer { try? FileManager.default.removeItem(at: temporary) }

  let diarize = separateSpeakers && installation.hasDiarizationModel
  if separateSpeakers && !diarize {
    logger.info(
      "transcription speakers skipped reason=model_missing folder.name=\(name, privacy: .public)")
  }
  let whole = diarize ? temporary.appending(path: "whole.wav") : nil
  let chunks: [AudioChunk]
  let duration: TimeInterval
  do {
    (chunks, duration) = try writeMonoChunks(
      of: meeting.appending(path: "recording.caf"), to: temporary, whole: whole)
  } catch {
    throw failed(
      error, step: "prepare", type: error == .audioUnreadable ? "audio_unreadable" : "file_system")
  }

  // 実測: M2 で asr の RTFx 30〜95、diarize の RTFx 121〜209。120 秒は初回のモデル読み込みの見込み
  // (runBundledSelfCheck と同じ)、録音の 0.5 倍はその 60 倍以上の余裕。
  // shortcut: 120 秒 + 録音の 0.5 倍, Metal の無い環境で時間切れの報告があれば実測から決め直す
  let timeout: Duration = .seconds(120) + .seconds(duration * 0.5)
  var tokens: [RecognizedToken] = []
  if !chunks.isEmpty {
    let stdout: Data
    do {
      stdout = try await runSpeech(
        installation.executable,
        ["asr", installation.modelFile.path, "--timestamps", "--format", "json"]
          + chunks.map(\.file.path),
        timeout: timeout)
    } catch {
      let status = error.status.map(String.init) ?? "none"
      appendLog(
        "transcription failed error.type=\(error.type) status=\(status) stderr=\(error.maskedStderrTail)",
        to: log)
      throw failed(
        .recognitionFailed, step: "recognize", type: error.type, status: error.status,
        stderr: error.stderrTail)
    }
    do {
      tokens = try recognizedTokens(stdout, chunks: chunks)
    } catch {
      appendLog("transcription failed error.type=unparsable_output", to: log)
      throw failed(.recognitionFailed, step: "parse", type: "unparsable_output")
    }
  }

  var speakers: [SpeakerSegment]?
  var skip: SpeakerSkip? = separateSpeakers && !diarize ? .modelMissing : nil
  if let whole, !tokens.isEmpty {
    do throws(SpeakerFailure) {
      speakers = try await diarizeSpeakers(
        of: whole, duration: duration, installation: installation, timeout: timeout)
    } catch {
      logger.warning(
        "transcription speakers failed step=\(error.step, privacy: .public) error.type=\(error.type, privacy: .public) app.error.origin=system status=\(error.status, privacy: .public) folder.name=\(name, privacy: .public) stderr=\(error.stderr, privacy: .private)"
      )
      appendLog(error.logLine, to: log)
      skip = .failed
    }
  }

  let transcript = Transcript(
    meetingName: name, duration: duration, model: installation.model.fileName,
    paragraphs: paragraphs(tokens, speakers: speakers))
  do {
    try Data(transcript.markdown.utf8).write(
      to: meeting.appending(path: "transcript.md"), options: .atomic)
  } catch {
    throw failed(.saveFailed, step: "write", type: "file_system")
  }
  let elapsed = (ContinuousClock.now - started) / .seconds(1)
  let speakersStatus =
    switch (separateSpeakers, skip) {
    case (false, _): "off"
    case (_, .modelMissing): "model_missing"
    case (_, .failed): "failed"
    case (true, nil): "labeled"
    }
  let speakerCount = Set(transcript.paragraphs.compactMap(\.speaker)).count
  logger.info(
    "transcription finished folder.name=\(name, privacy: .public) audio_s=\(duration, format: .fixed(precision: 1), privacy: .public) elapsed_s=\(elapsed, format: .fixed(precision: 1), privacy: .public) chunks=\(chunks.count, privacy: .public) paragraphs=\(transcript.paragraphs.count, privacy: .public) speakers.status=\(speakersStatus, privacy: .public) speakers.count=\(speakerCount, privacy: .public)"
  )
  return skip
}

/// 話者分離が失敗した理由。`step` は `diarize`・`parse`、`type` はログの `error.type`。
private struct SpeakerFailure: Error {
  let step: String
  let type: String
  var status = "none"
  /// os のログに `privacy: .private` で出す標準エラー出力の末尾。
  var stderr = ""
  /// `transcription.log` に追記する 1 行(標準エラー出力はホームを伏せる)。
  let logLine: String
}

/// 録音全体の WAVE `whole` を `speech diarize` に渡し、検証した話者の区間を返す。
/// 語があるのに区間が 0 個なら、話者を分けられなかったとして投げる。
private func diarizeSpeakers(
  of whole: URL, duration: TimeInterval, installation: SpeechInstallation, timeout: Duration
) async throws(SpeakerFailure) -> [SpeakerSegment] {
  let stdout: Data
  do {
    stdout = try await runSpeech(
      installation.executable,
      ["diarize", installation.diarizationModelFile.path, "--format", "json", whole.path],
      timeout: timeout)
  } catch {
    let status = error.status.map(String.init) ?? "none"
    throw SpeakerFailure(
      step: "diarize", type: error.type, status: status, stderr: error.stderrTail,
      logLine:
        "speakers failed error.type=\(error.type) status=\(status) stderr=\(error.maskedStderrTail)"
    )
  }
  let segments: [SpeakerSegment]
  do {
    segments = try speakerSegments(stdout, file: whole, duration: duration)
  } catch {
    throw SpeakerFailure(
      step: "parse", type: "unparsable_output",
      logLine: "speakers failed error.type=unparsable_output")
  }
  guard !segments.isEmpty else {
    throw SpeakerFailure(
      step: "parse", type: "no_segments", logLine: "speakers failed error.type=no_segments")
  }
  return segments
}

/// 利用者に通知する文字起こしの結果。`meeting` は会議フォルダーの名前。
enum TranscriptionNotice: Equatable {
  case finished(meeting: String)
  case autoOff(meeting: String)
  case setupRequired(meeting: String)
  case failed(TranscriptionFailure, meeting: String)
}

/// 録音を停止したら自動で文字起こしするかの設定。
struct TranscriptionSetting {
  private static let key = "transcribeAfterRecording"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 保存値が Bool でなければ(`defaults write` で壊された値を含む)既定のオン。
  var autoTranscribe: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

  func setAutoTranscribe(_ autoTranscribe: Bool) {
    defaults.set(autoTranscribe, forKey: Self.key)
  }
}

/// 文字起こしの待ち行列を持つ。状態の持ち主はこの型だけである。speech は同時に 1 つだけ動かす。
// shortcut: 待ち行列と未取得の待ちはメモリだけ(アプリの終了で消える), R5 の一覧の手動実行で足りなければ永続化する
@MainActor @Observable final class Transcriber {
  /// 先頭が文字起こし中の会議フォルダー。
  private(set) var queue: [URL] = []
  /// ランタイムかモデルが未取得で待たせている会議フォルダー。
  private var awaitingSetup: [URL] = []
  private let installation: SpeechInstallation
  private let setting: TranscriptionSetting
  private let transcribe: (URL, SpeechInstallation) async throws(TranscriptionFailure) -> Void
  private let notify: @MainActor (TranscriptionNotice) -> Void

  init(
    installation: SpeechInstallation, setting: TranscriptionSetting,
    transcribe: @escaping (URL, SpeechInstallation) async throws(TranscriptionFailure) -> Void,
    notify: @escaping @MainActor (TranscriptionNotice) -> Void
  ) {
    self.installation = installation
    self.setting = setting
    self.transcribe = transcribe
    self.notify = notify
  }

  var current: URL? { queue.first }

  /// 録音が保存されたとき。自動がオンなら文字起こしを待ち行列に入れる。
  func recordingSaved(_ meeting: URL) {
    guard setting.autoTranscribe else {
      logger.info(
        "transcription skipped reason=auto_off folder.name=\(meeting.lastPathComponent, privacy: .public)"
      )
      notify(.autoOff(meeting: meeting.lastPathComponent))
      return
    }
    enqueue(meeting)
  }

  /// 一覧の「文字起こし」。自動の設定によらず待ち行列に入れる。
  func request(_ meeting: URL) {
    logger.info(
      "transcription requested source=list folder.name=\(meeting.lastPathComponent, privacy: .public)"
    )
    enqueue(meeting)
  }

  /// ランタイムとモデルの取得・動作確認の後。取得済みなら未取得で待たせた録音を文字起こしする。
  func resumeAfterSetup() {
    guard installation.isInstalled else { return }
    let waiting = awaitingSetup
    awaitingSetup = []
    waiting.forEach(enqueue)
  }

  private func enqueue(_ meeting: URL) {
    guard !queue.contains(meeting) else {
      logger.info(
        "transcription request ignored reason=already_queued folder.name=\(meeting.lastPathComponent, privacy: .public)"
      )
      return
    }
    guard installation.isInstalled else {
      if !awaitingSetup.contains(meeting) { awaitingSetup.append(meeting) }
      logger.info(
        "transcription deferred reason=not_installed folder.name=\(meeting.lastPathComponent, privacy: .public)"
      )
      notify(.setupRequired(meeting: meeting.lastPathComponent))
      return
    }
    awaitingSetup.removeAll { $0 == meeting }
    queue.append(meeting)
    if queue.count == 1 { Task { await drain() } }
  }

  private func drain() async {
    while let meeting = queue.first {
      do {
        try await transcribe(meeting, installation)
        notify(.finished(meeting: meeting.lastPathComponent))
      } catch {
        notify(.failed(error, meeting: meeting.lastPathComponent))
      }
      queue.removeFirst()
    }
  }
}

// main.swift のトップレベルはテストバンドルで実行されないため、遅延初期化されるここに置く。
@MainActor let transcriber = Transcriber(
  installation: .standard, setting: TranscriptionSetting(),
  transcribe: { meeting, installation async throws(TranscriptionFailure) in
    try await transcribe(meeting: meeting, installation: installation, separateSpeakers: false)
  },
  notify: { notice in
    // 会議中にモーダルを出さないよう、出せなくても警告に逃がさない。
    Task {
      do throws(NotificationFailure) {
        try await MenuBar.notify(
          title: TranscriptionText.title(for: notice), body: TranscriptionText.body(for: notice))
      } catch {
        logger.warning(
          "transcription notification failed error.type=notification_failed app.error.origin=system"
        )
      }
    }
  })
