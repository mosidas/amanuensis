import Foundation
import Testing

@testable import Amanuensis

/// 一時ディレクトリに `body` を本文とする実行できる `speech` を作る。
private func fakeSpeech(_ body: String) throws -> (executable: URL, directory: URL) {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SelfCheck-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appending(path: "speech")
  try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return (executable, directory)
}

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
  let result = try await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "今日は良い天気です。",
    timeout: .seconds(10), log: log)
  #expect(result == SelfCheckResult(transcript: "今日はいい天気です", cer: 1.0 / 9))
  let args = try String(contentsOf: directory.appending(path: "args"), encoding: .utf8)
  #expect(args == "asr\n/tmp/model dir/model.gguf\n--format\ntext\n/tmp/sample.wav\n")
  let line = try readLog(log)
  #expect(line.contains(" selfcheck passed cer=0.1111 threshold=0.15 transcript=今日はいい天気です\n"))
}

@Test func selfCheckReportsExitStatus() async throws {
  let (executable, _) = try fakeSpeech("echo broken >&2; exit 3")
  let log = temporaryLog()
  await #expect(throws: SelfCheckError.exited(status: 3)) {
    try await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
      log: log)
  }
  let line = try readLog(log)
  #expect(line.contains(" selfcheck failed error.type=exited status=3 stderr=broken"))
}

@Test func selfCheckReportsLaunchFailure() async throws {
  let log = temporaryLog()
  await #expect(throws: SelfCheckError.launchFailed) {
    try await runSelfCheck(
      executable: URL(filePath: "/nonexistent/speech"), model: model, audio: audio,
      reference: "x", timeout: .seconds(10), log: log)
  }
  #expect(try readLog(log).contains(" selfcheck failed error.type=launch_failed"))
}

@Test func selfCheckTimesOutAndTerminates() async throws {
  // `exec sleep` だと引数からスクリプトのパスが消えて探せないため、子を持たない待ちの繰り返しにする。
  let (executable, directory) = try fakeSpeech("while :; do :; done")
  let started = ContinuousClock.now
  let log = temporaryLog()
  await #expect(throws: SelfCheckError.timedOut) {
    try await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x",
      timeout: .milliseconds(500), log: log)
  }
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
  let result = try await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "今日は良い天気です。",
    timeout: .seconds(10), log: log)
  #expect(result == SelfCheckResult(transcript: "まったく違う", cer: 1))
  let line = try readLog(log)
  #expect(
    line.contains(
      " selfcheck failed error.type=cer_over_threshold cer=1.0000 threshold=0.15 transcript=まったく違う\n"
    ))
}

@Test func selfCheckLogMasksHomeAndKeepsOneLine() async throws {
  let (executable, _) = try fakeSpeech(#"printf '%s\n%s\n' "$HOME/x" second >&2; exit 1"#)
  let log = temporaryLog()
  await #expect(throws: SelfCheckError.exited(status: 1)) {
    try await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10),
      log: log)
  }
  let contents = try readLog(log)
  #expect(contents.split(separator: "\n").count == 1, "1 回の確認で 1 行")
  #expect(contents.contains(#"stderr=~/x\nsecond\n"#))
  #expect(!contents.contains(NSHomeDirectory()), "ホームのパスを出さない")
}

@Test func selfCheckLogAppends() async throws {
  let (executable, _) = try fakeSpeech("echo broken >&2; exit 3")
  let log = temporaryLog()
  for _ in 0..<2 {
    _ = try? await runSelfCheck(
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
  let result = try await runSelfCheck(
    executable: SpeechInstallation.standard.executable,
    model: SpeechInstallation.standard.modelFile, audio: directory.appending(path: "sample.wav"),
    reference: reference, timeout: .seconds(120), log: temporaryLog())
  #expect(result.cer <= selfCheckCERThreshold)
}

private let bundledSampleDirectory = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources/SelfCheck")
