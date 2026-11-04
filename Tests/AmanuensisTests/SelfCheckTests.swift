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
  let result = try await runSelfCheck(
    executable: executable, model: model, audio: audio, reference: "今日は良い天気です。",
    timeout: .seconds(10))
  #expect(result == SelfCheckResult(transcript: "今日はいい天気です", cer: 1.0 / 9))
  let args = try String(contentsOf: directory.appending(path: "args"), encoding: .utf8)
  #expect(args == "asr\n/tmp/model dir/model.gguf\n--format\ntext\n/tmp/sample.wav\n")
}

@Test func selfCheckReportsExitStatus() async throws {
  let (executable, _) = try fakeSpeech("echo broken >&2; exit 3")
  await #expect(throws: SelfCheckError.exited(status: 3)) {
    try await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x", timeout: .seconds(10))
  }
}

@Test func selfCheckReportsLaunchFailure() async throws {
  await #expect(throws: SelfCheckError.launchFailed) {
    try await runSelfCheck(
      executable: URL(filePath: "/nonexistent/speech"), model: model, audio: audio,
      reference: "x", timeout: .seconds(10))
  }
}

@Test func selfCheckTimesOutAndTerminates() async throws {
  // `exec sleep` だと引数からスクリプトのパスが消えて探せないため、子を持たない待ちの繰り返しにする。
  let (executable, directory) = try fakeSpeech("while :; do :; done")
  let started = ContinuousClock.now
  await #expect(throws: SelfCheckError.timedOut) {
    try await runSelfCheck(
      executable: executable, model: model, audio: audio, reference: "x",
      timeout: .milliseconds(500))
  }
  #expect(ContinuousClock.now - started < .seconds(5), "タイムアウトで待たずに戻る")
  let pgrep = Process()
  pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
  pgrep.arguments = ["-f", directory.path]
  pgrep.standardOutput = FileHandle.nullDevice
  try pgrep.run()
  pgrep.waitUntilExit()
  #expect(pgrep.terminationStatus == 1, "プロセスが残らない")
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
    reference: reference, timeout: .seconds(120))
  #expect(result.cer <= selfCheckCERThreshold)
}

private let bundledSampleDirectory = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources/SelfCheck")
