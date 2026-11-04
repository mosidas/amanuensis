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
/// 結果は 1 行にして `log` の末尾に追記する。
func runSelfCheck(
  executable: URL, model: URL, audio: URL, reference: String, timeout: Duration, log: URL
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
    appendSelfCheckLog("selfcheck failed error.type=launch_failed status=none stderr=", to: log)
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
    logger.error(
      "selfcheck failed error.type=\(type, privacy: .public) status=\(status, privacy: .public) stderr=\(oneLine(tail), privacy: .private)"
    )
    // ファイルは利用者が開いて共有しうるので、個人名の入ったホームのパスを伏せる。
    let maskedTail = oneLine(tail.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    appendSelfCheckLog(
      "selfcheck failed error.type=\(type) status=\(status) stderr=\(maskedTail)", to: log)
    throw failure
  }
  let transcript = String(decoding: stdoutData, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let cer = characterErrorRate(transcript, reference: reference)
  logger.info(
    "selfcheck finished cer=\(cer, privacy: .public) chars=\(transcript.count, privacy: .public)")
  let scores =
    "cer=\(String(format: "%.4f", cer)) threshold=\(selfCheckCERThreshold) transcript=\(oneLine(transcript))"
  appendSelfCheckLog(
    cer <= selfCheckCERThreshold
      ? "selfcheck passed \(scores)" : "selfcheck failed error.type=cer_over_threshold \(scores)",
    to: log)
  return SelfCheckResult(transcript: transcript, cer: cer)
}

/// アプリに同梱した `SelfCheck/sample.wav` と `sample.txt` で動作確認する。同梱されていなければ `.unavailable`。
func runBundledSelfCheck(_ installation: SpeechInstallation) async -> SelfCheckState {
  guard
    let audio = Bundle.main.url(
      forResource: "sample", withExtension: "wav", subdirectory: "SelfCheck"),
    let reference = try? String(
      contentsOf: audio.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
  else {
    logger.error("selfcheck failed error.type=sample_missing app.error.origin=system")
    appendSelfCheckLog(
      "selfcheck failed error.type=sample_missing app.error.origin=system",
      to: installation.selfCheckLog)
    return .unavailable
  }
  do throws(SelfCheckError) {
    return .finished(
      try await runSelfCheck(
        executable: installation.executable, model: installation.modelFile, audio: audio,
        reference: reference,
        // 実測: Apple Silicon の Metal で同梱の 30.67 秒の音声を 0.6 秒で処理した(読み込み 0.25 秒、認識 0.321 秒、RTFx 95.4)。
        // 120 秒はその約 200 倍で、Metal が使えない環境と初回のモデル読み込みの遅さを見込んだ上限である。
        timeout: .seconds(120), log: installation.selfCheckLog))
  } catch {
    return .failed(error)
  }
}

/// 改行と CR をエスケープし、偽の行を作らせずに 1 行に収める。
private func oneLine(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
}

/// `line` に時刻を付けて `url` の末尾に追記する。書けなくても動作確認の結果は変えない。
private func appendSelfCheckLog(_ line: String, to url: URL) {
  // shortcut: ローテーションなし(1 回の確認で 1 行、約 1 KB), ファイルが 1 MB を超える報告があれば古い行を切り捨てる
  let data = Data("\(Date.now.ISO8601Format()) \(line)\n".utf8)
  do {
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  } catch {
    logger.error("selfcheck log write failed error.type=file_system app.error.origin=system")
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
