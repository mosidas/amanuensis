import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "selfcheck")

/// 動作確認で CER がこの値以下なら合格とする。
let selfCheckMaxCER = 0.15

/// 動作確認の結果。起動できない・異常終了・CER が基準を超えたは `failed`、`timeout` 内に終わらなければ `timedOut`、
/// 同梱の音声が無ければ `unavailable`。
enum SelfCheckOutcome: Equatable {
  case passed, failed, timedOut, unavailable
}

/// `executable asr <model> --format text <audio>` で `audio` を文字起こしし、`reference` に対する CER で合否を決める。
/// 結果は 1 行にして `log` の末尾に追記する。
func runSelfCheck(
  executable: URL, model: URL, audio: URL, reference: String, timeout: Duration, log: URL
) async -> SelfCheckOutcome {
  let stdoutData: Data
  do {
    stdoutData = try await runSpeech(
      executable, ["asr", model.path, "--format", "text", audio.path], timeout: timeout)
  } catch {
    let status = error.status.map(String.init) ?? "none"
    logger.error(
      "selfcheck failed error.type=\(error.type, privacy: .public) status=\(status, privacy: .public) stderr=\(error.stderrTail, privacy: .private)"
    )
    appendLog(
      "selfcheck failed error.type=\(error.type) status=\(status) stderr=\(error.maskedStderrTail)",
      to: log)
    return error.type == "timed_out" ? .timedOut : .failed
  }
  let transcript = String(decoding: stdoutData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cer = characterErrorRate(transcript, reference: reference)
  logger.info(
    "selfcheck finished cer=\(cer, privacy: .public) chars=\(transcript.count, privacy: .public)")
  let scores =
    "cer=\(String(format: "%.4f", cer)) threshold=\(selfCheckMaxCER) transcript=\(oneLine(transcript))"
  guard cer <= selfCheckMaxCER else {
    logger.error("selfcheck failed error.type=cer_over_threshold")
    appendLog("selfcheck failed error.type=cer_over_threshold \(scores)", to: log)
    return .failed
  }
  appendLog("selfcheck passed \(scores)", to: log)
  return .passed
}

/// アプリに同梱した `SelfCheck/sample.wav` と `sample.txt` で動作確認する。同梱されていなければ `.unavailable`。
func runBundledSelfCheck(_ installation: SpeechInstallation) async -> SelfCheckOutcome {
  guard
    let audio = Bundle.main.url(
      forResource: "sample", withExtension: "wav", subdirectory: "SelfCheck"),
    let reference = try? String(
      contentsOf: audio.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
  else {
    logger.error("selfcheck failed error.type=sample_missing app.error.origin=system")
    appendLog(
      "selfcheck failed error.type=sample_missing app.error.origin=system",
      to: installation.selfCheckLog)
    return .unavailable
  }
  return await runSelfCheck(
    executable: installation.executable, model: installation.modelFile, audio: audio,
    reference: reference,
    // 実測: Apple Silicon の Metal で同梱の 30.67 秒の音声を 0.6 秒で処理した(読み込み 0.25 秒、認識 0.321 秒、RTFx 95.4)。
    // 120 秒はその約 200 倍で、Metal が使えない環境と初回のモデル読み込みの遅さを見込んだ上限である。
    timeout: .seconds(120), log: installation.selfCheckLog)
}
