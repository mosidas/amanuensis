import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "speech")

/// `speech` の子プロセスが成功しなかった理由。`type` は `launch_failed`・`exited`・`timed_out` のどれか。
/// `status` は起動できなかったときだけ nil。
struct SpeechFailure: Error {
  let type: String
  let status: Int32?
  let stderr: Data

  /// 標準エラー出力の末尾 512 バイトを 1 行にしたもの。os のログに `privacy: .private` で出す。
  var stderrTail: String {
    oneLine(String(decoding: stderr.suffix(512), as: UTF8.self))
  }

  /// ホームのパスを `~` に伏せてから末尾 512 バイトを 1 行にしたもの。利用者が開くファイルのログに書く。
  var maskedStderrTail: String {
    // ファイルは利用者が開いて共有しうるので、個人名の入ったホームのパスを伏せる。
    // 切り詰めの前に伏せる。切れ目がホームのパスの途中に来ると、残りの部分は一致せず利用者名が残る。
    let masked = String(decoding: stderr, as: UTF8.self)
      .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    return oneLine(String(decoding: Data(masked.utf8.suffix(512)), as: UTF8.self))
  }
}

/// `executable` を `arguments` で起動し、終了コード 0 で終われば標準出力を返す。
/// `timeout` を過ぎたら子を終了させて `timed_out` で失敗する。
func runSpeech(_ executable: URL, _ arguments: [String], timeout: Duration)
  async throws(SpeechFailure) -> Data
{
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
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
    throw SpeechFailure(type: "launch_failed", status: nil, stderr: Data())
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

  if timedOut || status != 0 {
    throw SpeechFailure(
      type: timedOut ? "timed_out" : "exited", status: status, stderr: stderrData)
  }
  return stdoutData
}

/// 改行と CR をエスケープし、偽の行を作らせずに 1 行に収める。
func oneLine(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
}

/// `line` に時刻を付けて `url` の末尾に追記する。書けなくても呼び出し元の結果は変えない。
func appendLog(_ line: String, to url: URL) {
  // shortcut: ローテーションなし(1 回の確認で 1 行、約 1 KB), ファイルが 1 MB を超える報告があれば古い行を切り捨てる
  let data = Data("\(Date.now.ISO8601Format()) \(line)\n".utf8)
  do {
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  } catch {
    logger.error(
      "log write failed error.type=file_system app.error.origin=system file=\(url.lastPathComponent, privacy: .public)"
    )
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
