import Foundation
import Testing

@testable import Amanuensis

/// 動作確認のログの置き場所。テストごとに別のファイルにする。
private func temporaryLog() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "selfcheck-\(UUID().uuidString).log")
}

private func readLog(_ url: URL) throws -> String {
  try String(contentsOf: url, encoding: .utf8)
}

private let model = URL(filePath: "/tmp/model dir/model.gguf")
private let audio = URL(filePath: "/tmp/sample.wav")

@Test func selfCheckPassesArgumentsAndScoresTranscript() async throws {
  let (executable, directory) = try fakeSpeech(
    """
    printf '%s\\n' "$@" > "$(dirname "$0")/args"
    echo '今日はいい天気です'
    echo 'progress 50%' >&2
    exit 0
    """)
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "今日は良い天気です。",
    timeout: .seconds(10), log: log)
  #expect(outcome == .passed)
  let args = try String(contentsOf: directory.appending(path: "args"), encoding: .utf8)
  #expect(args == "asr\n/tmp/model dir/model.gguf\n--format\ntext\n/tmp/sample.wav\n")
  let line = try readLog(log)
  #expect(line.contains(" selfcheck passed cer=0.1111 threshold=0.15 transcript=今日はいい天気です\n"))
}

@Test func selfCheckReportsExitStatus() async throws {
  let (executable, _) = try fakeSpeech("echo broken >&2; exit 3")
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
    log: log)
  #expect(outcome == .failed)
  let line = try readLog(log)
  #expect(line.contains(" selfcheck failed error.type=exited status=3 stderr=broken"))
}

@Test func selfCheckReportsLaunchFailure() async throws {
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: URL(filePath: "/nonexistent/speech"), model: model, audio: audio,
    reference: "x", timeout: .seconds(10), log: log)
  #expect(outcome == .failed)
  #expect(try readLog(log).contains(" selfcheck failed error.type=launch_failed"))
}

@Test func selfCheckTimesOutAndTerminates() async throws {
  // `exec sleep` だと引数からスクリプトのパスが消えて探せないため、子を持たない待ちの繰り返しにする。
  let (executable, directory) = try fakeSpeech("while :; do :; done")
  let started = ContinuousClock.now
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "x",
    timeout: .milliseconds(500), log: log)
  #expect(outcome == .timedOut)
  #expect(try readLog(log).contains(" selfcheck failed error.type=timed_out"))
  #expect(ContinuousClock.now - started < .seconds(5), "タイムアウトで待たずに戻る")
  let pgrep = Process()
  pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
  pgrep.arguments = ["-f", directory.path]
  pgrep.standardOutput = FileHandle.nullDevice
  try pgrep.run()
  pgrep.waitUntilExit()
  #expect(pgrep.terminationStatus == 1, "プロセスが残らない")
}

@Test func selfCheckLogsOverThreshold() async throws {
  let (executable, _) = try fakeSpeech("echo 'まったく違う'; exit 0")
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "今日は良い天気です。",
    timeout: .seconds(10), log: log)
  #expect(outcome == .failed, "終了コード 0 でも基準を超えたら失敗")
  let line = try readLog(log)
  #expect(
    line.contains(
      " selfcheck failed error.type=cer_over_threshold cer=1.0000 threshold=0.15 transcript=まったく違う\n"
    ))
}

@Test func selfCheckPassesAtThreshold() async throws {
  let (executable, _) = try fakeSpeech("echo 'XYZdefghijklmnopqrst'; exit 0")
  let log = temporaryLog()
  let outcome = await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "abcdefghijklmnopqrst",
    timeout: .seconds(10), log: log)
  #expect(outcome == .passed, "CER がちょうど基準なら合格")
  #expect(try readLog(log).contains(" selfcheck passed cer=0.1500 threshold=0.15 "))
}

@Test func selfCheckLogMasksHomeAndKeepsOneLine() async throws {
  let (executable, _) = try fakeSpeech(#"printf '%s\n%s\n' "$HOME/x" second >&2; exit 1"#)
  let log = temporaryLog()
  #expect(
    await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
      log: log) == .failed)
  let contents = try readLog(log)
  #expect(contents.split(separator: "\n").count == 1, "1 回の確認で 1 行")
  #expect(contents.contains(#"stderr=~/x\nsecond\n"#))
  #expect(!contents.contains(NSHomeDirectory()), "ホームのパスを出さない")
}

@Test func selfCheckLogMasksHomeCutByTail() async throws {
  let home = NSHomeDirectory()
  // 末尾 512 バイトの切れ目がホームのパスの 3 文字目に来る長さにする。
  let padding = String(repeating: "x", count: 512 - (home.utf8.count - 3) - 1)
  let (executable, _) = try fakeSpeech("printf '%s%s\\n' '\(home)' '\(padding)' >&2; exit 1")
  let log = temporaryLog()
  #expect(
    await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
      log: log) == .failed)
  let contents = try readLog(log)
  #expect(contents.contains("stderr=~\(padding)\\n"))
  #expect(!contents.contains((home as NSString).lastPathComponent), "利用者名を出さない")
}

@Test func selfCheckLogAppends() async throws {
  let (executable, _) = try fakeSpeech("echo broken >&2; exit 3")
  let log = temporaryLog()
  for _ in 0..<2 {
    _ = await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
      log: log)
  }
  #expect(try readLog(log).split(separator: "\n").count == 2, "前の行を残して追記する")
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["AMANUENSIS_E2E"] == "1"
      && SpeechInstallation.standard.isInstalled
      && FileManager.default.fileExists(
        atPath: bundledSampleDirectory.appending(path: "sample.wav").path)
  ))
func selfCheckOnBundledSample() async throws {
  let directory = bundledSampleDirectory
  let reference = try String(contentsOf: directory.appending(path: "sample.txt"), encoding: .utf8)
  let outcome = await runSelfCheck(
    executable: SpeechInstallation.standard.executable,
    model: SpeechInstallation.standard.modelFile, audio: directory.appending(path: "sample.wav"),
    reference: reference, timeout: .seconds(120), log: temporaryLog())
  #expect(outcome == .passed)
}

private let bundledSampleDirectory = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources/SelfCheck")

@Test func appendLogDoesNotFollowSymbolicLink() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SelfCheckTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appending(path: "target.txt")
  try Data("keep".utf8).write(to: target)
  let link = directory.appending(path: "selfcheck.log")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

  appendLog("x", to: link)

  #expect(try readLog(target) == "keep", "リンク先に書かない")
}
