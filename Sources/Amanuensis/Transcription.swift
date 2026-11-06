import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "transcription")

/// 利用者に見せる文字起こしの失敗の区別。ログの `error.type` はこれより細かい。
enum TranscriptionFailure: Error, Equatable {
  case audioUnreadable, recognitionFailed, saveFailed
}

/// 会議フォルダーの `recording.caf` を文字起こしし、同じフォルダーの `transcript.md` に書く(既にあれば置き換える)。
/// 録音は消さず動かさない。認識の失敗は `transcription.log` に 1 行追記する。
func transcribe(meeting: URL, installation: SpeechInstallation) async throws(TranscriptionFailure) {
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

  let temporary = FileManager.default.temporaryDirectory.appending(
    path: "amanuensis-transcription-\(UUID().uuidString)", directoryHint: .isDirectory)
  do {
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  } catch {
    throw failed(.saveFailed, step: "prepare", type: "file_system")
  }
  defer { try? FileManager.default.removeItem(at: temporary) }

  let chunks: [AudioChunk]
  let duration: TimeInterval
  do {
    (chunks, duration) = try writeMonoChunks(
      of: meeting.appending(path: "recording.caf"), to: temporary)
  } catch {
    throw failed(
      error, step: "prepare", type: error == .audioUnreadable ? "audio_unreadable" : "file_system")
  }

  var tokens: [RecognizedToken] = []
  if !chunks.isEmpty {
    let stdout: Data
    do {
      // 実測: M2 で RTFx 30〜95。120 秒は初回のモデル読み込みの見込み(runBundledSelfCheck と同じ)、
      // 録音の 0.5 倍はその 60 倍以上の余裕。
      // shortcut: 120 秒 + 録音の 0.5 倍, Metal の無い環境で時間切れの報告があれば実測から決め直す
      stdout = try await runSpeech(
        installation.executable,
        ["asr", installation.modelFile.path, "--timestamps", "--format", "json"]
          + chunks.map(\.file.path),
        timeout: .seconds(120) + .seconds(duration * 0.5))
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

  let transcript = Transcript(
    meetingName: name, duration: duration, model: installation.model.fileName,
    paragraphs: paragraphs(tokens))
  do {
    try Data(transcript.markdown.utf8).write(
      to: meeting.appending(path: "transcript.md"), options: .atomic)
  } catch {
    throw failed(.saveFailed, step: "write", type: "file_system")
  }
  let elapsed = (ContinuousClock.now - started) / .seconds(1)
  logger.info(
    "transcription finished folder.name=\(name, privacy: .public) audio_s=\(duration, format: .fixed(precision: 1), privacy: .public) elapsed_s=\(elapsed, format: .fixed(precision: 1), privacy: .public) chunks=\(chunks.count, privacy: .public) paragraphs=\(transcript.paragraphs.count, privacy: .public)"
  )
}
