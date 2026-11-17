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
  let engine = installation.engine.rawValue
  logger.info(
    "transcription started folder.name=\(name, privacy: .public) engine=\(engine, privacy: .public)"
  )

  func failed(
    _ failure: TranscriptionFailure, step: String, type: String, status: Int32? = nil,
    stderr: String = "", reason: String? = nil
  ) -> TranscriptionFailure {
    let status = status.map(String.init) ?? "none"
    let reason = reason.map { " reason=\($0)" } ?? ""
    logger.error(
      "transcription failed step=\(step, privacy: .public) error.type=\(type, privacy: .public)\(reason, privacy: .public) app.error.origin=system status=\(status, privacy: .public) engine=\(engine, privacy: .public) folder.name=\(name, privacy: .public) stderr=\(stderr, privacy: .private)"
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

  var skip: SpeakerSkip? =
    separateSpeakers && !installation.hasDiarizationModel ? .modelMissing : nil
  if skip == .modelMissing {
    logger.info(
      "transcription speakers skipped reason=model_missing folder.name=\(name, privacy: .public)")
  }
  let labelsSpeakers = separateSpeakers && skip == nil
  let whole = temporary.appending(path: "whole.wav")
  // shortcut: Whisper でも区間を書く(1 時間で約 345 MB の一時ファイルが余る), 一時ファイルの容量が問題になったら Whisper では区間を書かない
  let writesWhole = installation.engine == .whisper || labelsSpeakers
  let chunks: [AudioChunk]
  let duration: TimeInterval
  do {
    (chunks, duration) = try writeMonoChunks(
      of: meeting.appending(path: "recording.caf"), to: temporary, whole: writesWhole ? whole : nil)
  } catch {
    throw failed(
      error, step: "prepare", type: error == .audioUnreadable ? "audio_unreadable" : "file_system")
  }

  // 実測: M2 で asr の RTFx 30〜95、diarize の RTFx 121〜209。120 秒は初回のモデル読み込みの見込み
  // (runBundledSelfCheck と同じ)、録音の 0.5 倍はその 60 倍以上の余裕。
  // shortcut: 120 秒 + 録音の 0.5 倍, Metal の無い環境で時間切れの報告があれば実測から決め直す
  // shortcut: Whisper も 120 秒 + 録音の 0.5 倍(試作: 75 秒の録音を冷えた 1 回目 19.6 秒、2 回目以降 6 秒前後), Whisper の初回の読み込みを含む実測で決め直す
  let timeout: Duration = .seconds(120) + .seconds(duration * 0.5)
  var tokens: [RecognizedToken] = []
  if !chunks.isEmpty {
    do throws(RecognitionFailure) {
      tokens = try await recognize(
        chunks, whole: whole, duration: duration, installation: installation, timeout: timeout)
    } catch {
      appendLog(error.logLine, to: log)
      throw failed(
        .recognitionFailed, step: error.step, type: error.type, status: error.status,
        stderr: error.stderr, reason: error.reason?.rawValue)
    }
  }

  var speakers: [SpeakerSegment]?
  if labelsSpeakers, !tokens.isEmpty {
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
    meetingName: name, duration: duration, model: installation.recognitionModel.fileName,
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
    "transcription finished folder.name=\(name, privacy: .public) engine=\(engine, privacy: .public) audio_s=\(duration, format: .fixed(precision: 1), privacy: .public) elapsed_s=\(elapsed, format: .fixed(precision: 1), privacy: .public) chunks=\(chunks.count, privacy: .public) paragraphs=\(transcript.paragraphs.count, privacy: .public) speakers.status=\(speakersStatus, privacy: .public) speakers.count=\(speakerCount, privacy: .public)"
  )
  return skip
}

/// 本文の認識が失敗した理由。`step` は `recognize`・`parse`、`type` はログの `error.type`。
private struct RecognitionFailure: Error {
  let step: String
  let type: String
  var status: Int32? = nil
  /// os のログに `privacy: .private` で出す標準エラー出力の末尾。
  var stderr = ""
  /// os のログの `reason`。Whisper の出力を使えなかったときだけ付ける(`transcription.log` には出さない)。
  var reason: WhisperOutputError? = nil
  /// `transcription.log` に追記する 1 行(標準エラー出力はホームを伏せる)。
  let logLine: String

  /// 子プロセスが成功しなかった。`label` は `transcription.log` の行の先頭。
  init(_ failure: SpeechFailure, label: String) {
    step = "recognize"
    type = failure.type
    status = failure.status
    stderr = failure.stderrTail
    let shownStatus = failure.status.map(String.init) ?? "none"
    logLine =
      "\(label) failed error.type=\(failure.type) status=\(shownStatus) stderr=\(failure.maskedStderrTail)"
  }

  /// 出力が想定の形でなかった。
  init(unparsableOutputOf label: String, reason: WhisperOutputError? = nil) {
    step = "parse"
    type = "unparsable_output"
    self.reason = reason
    logLine = "\(label) failed error.type=unparsable_output"
  }
}

/// 選んだエンジンで本文を語の列に起こす。Haas は区間 `chunks` を、Whisper は録音全体の WAVE `whole` を読む。
private func recognize(
  _ chunks: [AudioChunk], whole: URL, duration: TimeInterval, installation: SpeechInstallation,
  timeout: Duration
) async throws(RecognitionFailure) -> [RecognizedToken] {
  switch installation.engine {
  case .haas:
    let stdout: Data
    do {
      stdout = try await runSpeech(
        installation.executable,
        ["asr", installation.modelFile.path, "--timestamps", "--format", "json"]
          + chunks.map(\.file.path),
        timeout: timeout)
    } catch {
      throw RecognitionFailure(error, label: "transcription")
    }
    do {
      return try recognizedTokens(stdout, chunks: chunks)
    } catch {
      throw RecognitionFailure(unparsableOutputOf: "transcription")
    }
  case .whisper:
    // -mc 0: 前の文脈を渡さず、反復の幻聴を減らす(mlx-whisper の --condition-on-previous-text False に当たる)。
    // 区間でなく全体を渡す: 区間が無音で始まると、Whisper はその区間の最初の段落を 0 秒に置く(試作で確かめた)。
    do {
      _ = try await runSpeech(
        installation.whisperExecutable,
        [
          "-m", installation.whisperModelFile.path, "-l", "ja", "-mc", "0", "-ojf", "-f",
          whole.path,
        ],
        timeout: timeout)
    } catch {
      throw RecognitionFailure(error, label: "whisper")
    }
    let output: Data
    do {
      output = try Data(contentsOf: whole.appendingPathExtension("json"))
    } catch {
      throw RecognitionFailure(unparsableOutputOf: "whisper", reason: .missingJSON)
    }
    do {
      return try whisperTokens(output, duration: duration)
    } catch {
      throw RecognitionFailure(unparsableOutputOf: "whisper", reason: error)
    }
  }
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
  /// 「話者を分ける」がオンなのにラベル無しで書いた。
  case finishedWithoutSpeakers(SpeakerSkip, meeting: String)
}

/// 本文を起こすエンジン。保存値は raw value。
enum TranscriptionEngine: String {
  case haas, whisper
}

/// 録音を停止したら自動で文字起こしするか、段落に話者のラベルを付けるか、本文をどのエンジンで起こすかの設定。
struct TranscriptionSetting {
  private static let key = "transcribeAfterRecording"
  private static let separateSpeakersKey = "separateSpeakers"
  private static let engineKey = "transcriptionEngine"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 保存値が Bool でなければ(`defaults write` で壊された値を含む)既定のオン。
  var autoTranscribe: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

  func setAutoTranscribe(_ autoTranscribe: Bool) {
    defaults.set(autoTranscribe, forKey: Self.key)
  }

  /// 保存値が Bool でなければ既定のオフ。
  var separateSpeakers: Bool { defaults.object(forKey: Self.separateSpeakersKey) as? Bool ?? false }

  func setSeparateSpeakers(_ separateSpeakers: Bool) {
    defaults.set(separateSpeakers, forKey: Self.separateSpeakersKey)
  }

  /// 保存値が文字列でないか、どのエンジンの名前でもなければ Haas。
  var engine: TranscriptionEngine {
    (defaults.object(forKey: Self.engineKey) as? String).flatMap(TranscriptionEngine.init) ?? .haas
  }

  func setEngine(_ engine: TranscriptionEngine) {
    defaults.set(engine.rawValue, forKey: Self.engineKey)
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
  private let transcribe:
    (URL, SpeechInstallation, Bool) async throws(TranscriptionFailure) -> SpeakerSkip?
  private let notify: @MainActor (TranscriptionNotice) -> Void

  init(
    installation: SpeechInstallation, setting: TranscriptionSetting,
    transcribe:
      @escaping (URL, SpeechInstallation, Bool) async throws(TranscriptionFailure) -> SpeakerSkip?,
    notify: @escaping @MainActor (TranscriptionNotice) -> Void
  ) {
    self.installation = installation
    self.setting = setting
    self.transcribe = transcribe
    self.notify = notify
  }

  var current: URL? { queue.first }

  /// 今の設定のエンジンを写した取得先。設定は待ち行列に入れた後にも変わりうるので、使うたびに作る。
  private var selected: SpeechInstallation { installation.selecting(setting.engine) }

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
    guard selected.isInstalled else { return }
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
    let job = selected
    guard job.isInstalled else {
      awaitSetup(meeting, engine: job.engine)
      return
    }
    awaitingSetup.removeAll { $0 == meeting }
    queue.append(meeting)
    if queue.count == 1 { Task { await drain() } }
  }

  /// 選んだエンジンに要るファイルが揃うまで `meeting` を待たせ、取得を促す。
  private func awaitSetup(_ meeting: URL, engine: TranscriptionEngine) {
    if !awaitingSetup.contains(meeting) { awaitingSetup.append(meeting) }
    logger.info(
      "transcription deferred reason=not_installed engine=\(engine.rawValue, privacy: .public) folder.name=\(meeting.lastPathComponent, privacy: .public)"
    )
    notify(.setupRequired(meeting: meeting.lastPathComponent))
  }

  private func drain() async {
    while let meeting = queue.first {
      let name = meeting.lastPathComponent
      // 待ち行列に入れた後に、要るファイルの無いエンジンへ替えられうる。
      let job = selected
      if job.isInstalled {
        do {
          let skip = try await transcribe(meeting, job, setting.separateSpeakers)
          notify(
            skip.map { .finishedWithoutSpeakers($0, meeting: name) } ?? .finished(meeting: name))
        } catch {
          notify(.failed(error, meeting: name))
        }
      } else {
        awaitSetup(meeting, engine: job.engine)
      }
      queue.removeFirst()
    }
  }
}

// main.swift のトップレベルはテストバンドルで実行されないため、遅延初期化されるここに置く。
@MainActor let transcriber = Transcriber(
  installation: .standard, setting: TranscriptionSetting(),
  transcribe: { meeting, installation, separateSpeakers async throws(TranscriptionFailure) in
    try await transcribe(
      meeting: meeting, installation: installation, separateSpeakers: separateSpeakers)
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
