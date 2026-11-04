import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "selfcheck")

/// 動作確認で CER をこの値以下なら基準内とする。
let selfCheckCERThreshold = 0.15

enum SelfCheckError: Error, Equatable {
  case launchFailed
  case exited(status: Int32)
  case timedOut
}

struct SelfCheckResult: Equatable {
  let transcript: String
  let cer: Double
}

enum SelfCheckState: Equatable {
  case idle, running
  case finished(SelfCheckResult)
  case failed(SelfCheckError)
  case unavailable
}

/// `executable asr <model> --format text <audio>` で `audio` を文字起こしし、`reference` に対する CER を返す。
func runSelfCheck(
  executable: URL, model: URL, audio: URL, reference: String, timeout: Duration
) async throws(SelfCheckError) -> SelfCheckResult {
  let process = Process()
  process.executableURL = executable
  process.arguments = ["asr", model.path, "--format", "text", audio.path]
  let output = Pipe()
  let errorOutput = Pipe()
  process.standardOutput = output
  process.standardError = errorOutput
  let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
  process.terminationHandler = {
    exited.yield($0.terminationStatus)
    exited.finish()
  }
  do {
    try process.run()
  } catch {
    logger.error("selfcheck failed error.type=launch_failed status=none stderr=")
    throw .launchFailed
  }
  // 片方のパイプだけを読むと、もう片方が埋まった時点で子が書き込みで止まる。
  async let stdout = readToEnd(output)
  async let stderr = readToEnd(errorOutput)
  let timer = Task { () -> Bool in
    do { try await Task.sleep(for: timeout) } catch { return false }
    process.terminate()
    return true
  }
  var status: Int32 = -1
  for await value in exits { status = value }
  timer.cancel()
  let timedOut = await timer.value
  let (stdoutData, stderrData) = await (stdout, stderr)

  let failure: SelfCheckError? =
    timedOut ? .timedOut : status == 0 ? nil : .exited(status: status)
  if let failure {
    let type =
      switch failure {
      case .launchFailed: "launch_failed"
      case .exited: "exited"
      case .timedOut: "timed_out"
      }
    let tail = String(decoding: stderrData.suffix(512), as: UTF8.self)
      .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    logger.error(
      "selfcheck failed error.type=\(type, privacy: .public) status=\(status, privacy: .public) stderr=\(tail, privacy: .public)"
    )
    throw failure
  }
  let transcript = String(decoding: stdoutData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cer = characterErrorRate(transcript, reference: reference)
  logger.info(
    "selfcheck finished cer=\(cer, privacy: .public) chars=\(transcript.count, privacy: .public)")
  return SelfCheckResult(transcript: transcript, cer: cer)
}

/// アプリに同梱した `SelfCheck/sample.wav` と `sample.txt` で動作確認する。同梱されていなければ `.unavailable`。
func runBundledSelfCheck(_ installation: SpeechInstallation) async -> SelfCheckState {
  guard
    let audio = Bundle.main.url(
      forResource: "sample", withExtension: "wav", subdirectory: "SelfCheck"),
    let reference = try? String(
      contentsOf: audio.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
  else { return .unavailable }
  do throws(SelfCheckError) {
    return .finished(
      try await runSelfCheck(
        executable: installation.executable, model: installation.modelFile, audio: audio,
        reference: reference,
        // shortcut: 30 秒の音声に対する仮の値, 実測が出たら見直す
        timeout: .seconds(120)))
  } catch {
    return .failed(error)
  }
}

/// パイプを閉じられるまで読む。読み取りで待つ間、Swift の並行処理のスレッドを塞がない。
private func readToEnd(_ pipe: Pipe) async -> Data {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
    }
  }
}
