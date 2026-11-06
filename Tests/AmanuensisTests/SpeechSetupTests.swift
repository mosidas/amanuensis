import CryptoKit
import Foundation
import Testing

@testable import Amanuensis

private let model = Data(repeating: 0x61, count: 300_000)
// head -c 300000 /dev/zero | tr '\0' a | shasum -a 256
private let modelSHA256 = "12e1b9b179b29a4f7e5889b185d7ac71bff0ad1f49a7b391d0911b737a0f5381"
private let diarizationModel = Data(repeating: 0x64, count: 200_000)
// head -c 200000 /dev/zero | tr '\0' d | shasum -a 256
private let diarizationSHA256 = "1773e3d88f1c07379d2b92ba62930c3a90559ba0a265c793385a3971a71b75ac"

/// `#!/bin/sh` の 1 行の実行ファイル `speech` を 1 つ持つ zip。
private let runtime: Data = {
  let fileManager = FileManager.default
  let work = fileManager.temporaryDirectory.appending(
    path: "SpeechSetupRuntime-\(UUID().uuidString)")
  let source = work.appending(path: "source")
  let zip = work.appending(path: "runtime.zip")
  try! fileManager.createDirectory(at: source, withIntermediateDirectories: true)
  let executable = source.appending(path: "speech")
  try! Data("#!/bin/sh\n".utf8).write(to: executable)
  try! fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/ditto")
  process.arguments = ["-c", "-k", source.path, zip.path]
  try! process.run()
  process.waitUntilExit()
  precondition(process.terminationStatus == 0, "ditto でランタイムの zip を作れる")
  return try! Data(contentsOf: zip)
}()

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 動作確認の代わり。呼ばれた回数を数え、`holds` のあいだは `release()` まで戻らない。
@MainActor
private final class StubCheck {
  var outcome = SelfCheckOutcome.passed
  var calls = 0
  var holds = false
  private var held: CheckedContinuation<Void, Never>?
  var isHolding: Bool { held != nil }

  func run(_: SpeechInstallation) async -> SelfCheckOutcome {
    if holds && held != nil {
      Issue.record("確認中に動作確認がもう一度呼ばれた")
      return outcome
    }
    calls += 1
    if holds { await withCheckedContinuation { held = $0 } }
    return outcome
  }

  func release() {
    holds = false
    held?.resume()
    held = nil
  }
}

/// `condition` が真になるまで 10ms ごとに確かめる。5 秒で諦める。
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() {
    try #require(ContinuousClock.now < deadline, "5 秒以内に条件を満たす")
    try await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor
private struct Harness {
  let runtimeURL = LocalFileURLProtocol.makeURL()
  let modelURL = LocalFileURLProtocol.makeURL()
  let diarizationURL = LocalFileURLProtocol.makeURL()
  let installation: SpeechInstallation
  let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalFileURLProtocol.self]
    return URLSession(configuration: configuration)
  }()

  init(
    runtimeBody: Data = runtime, modelSHA256: String = modelSHA256,
    modelStub: LocalFileURLProtocol.Stub = .init(body: model),
    diarizationSHA256: String = diarizationSHA256
  ) {
    var installation = SpeechInstallation(
      directory: FileManager.default.temporaryDirectory.appending(
        path: "SpeechSetupTests-\(UUID().uuidString)"))
    installation.runtime = RemoteFile(
      url: runtimeURL, byteCount: Int64(runtimeBody.count), sha256: sha256(runtimeBody),
      fileName: "runtime.zip")
    installation.model = RemoteFile(
      url: modelURL, byteCount: Int64(model.count), sha256: modelSHA256, fileName: "model.gguf")
    installation.diarizationModel = RemoteFile(
      url: diarizationURL, byteCount: Int64(diarizationModel.count), sha256: diarizationSHA256,
      fileName: "diarization.gguf")
    self.installation = installation
    LocalFileURLProtocol.set(.init(body: runtimeBody), for: runtimeURL)
    LocalFileURLProtocol.set(modelStub, for: modelURL)
    LocalFileURLProtocol.set(.init(body: diarizationModel), for: diarizationURL)
  }

  func makeSetup(
    available: Int64 = 1 << 40,
    selfCheck: @escaping (SpeechInstallation) async -> SelfCheckOutcome = { _ in .passed }
  ) -> SpeechSetup {
    SpeechSetup(
      installation: installation, session: session, availableCapacity: { _ in available },
      selfCheck: selfCheck)
  }

  func requestCount(_ url: URL) -> Int { LocalFileURLProtocol.receivedRanges(for: url).count }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
@Test func installsRuntimeAndModel() async throws {
  let harness = Harness()
  let stub = StubCheck()
  let setup = harness.makeSetup(selfCheck: stub.run)
  #expect(setup.state == .notInstalled)

  await setup.download()

  let installation = harness.installation
  #expect(setup.state == .checked(.passed))
  #expect(stub.calls == 1, "ダウンロードの後に操作なしで動作確認する")
  #expect(installation.isInstalled)
  #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
  #expect(getxattr(installation.executable.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
  #expect(errno == ENOATTR, "展開したランタイムに quarantine の属性が付かない")
  #expect(try Data(contentsOf: installation.modelFile) == model)
  #expect(try Data(contentsOf: installation.diarizationModelFile) == diarizationModel)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: installation.directory.path).sorted()
      == ["diarization.gguf", "model.gguf", "runtime"], "zip と .part と展開の一時ディレクトリが残らない")
}

@MainActor
@Test func refusesWithoutSendingRequestsWhenSpaceIsInsufficient() async {
  let harness = Harness()
  let setup = harness.makeSetup(available: 1000)

  await setup.download()

  let installation = harness.installation
  #expect(
    setup.state
      == .insufficientSpace(
        required: installation.runtime.byteCount + installation.runtimeExtractedByteCount
          + installation.model.byteCount + installation.diarizationModel.byteCount,
        available: 1000))
  #expect(harness.requestCount(harness.runtimeURL) == 0)
  #expect(harness.requestCount(harness.modelURL) == 0)
  #expect(harness.requestCount(harness.diarizationURL) == 0)
}

@MainActor
@Test func sendsRequestsWhenSpaceIsSufficient() async {
  let harness = Harness()
  let installation = harness.installation
  let required =
    installation.runtime.byteCount + installation.runtimeExtractedByteCount
    + installation.model.byteCount + installation.diarizationModel.byteCount
  let setup = harness.makeSetup(available: required)

  await setup.download()

  #expect(setup.state == .checked(.passed))
  #expect(harness.requestCount(harness.runtimeURL) == 1)
  #expect(harness.requestCount(harness.modelURL) == 1)
  #expect(harness.requestCount(harness.diarizationURL) == 1)
}

@MainActor
@Test func resumesModelFromPartAfterRestart() async throws {
  let harness = Harness()
  let installation = harness.installation
  try FileManager.default.createDirectory(
    at: installation.directory, withIntermediateDirectories: true)
  try model.prefix(100_000).write(
    to: installation.directory.appending(path: "model.gguf.part"))

  let refused = harness.makeSetup(available: 1)
  await refused.download()
  #expect(
    refused.state
      == .insufficientSpace(
        required: installation.runtime.byteCount + installation.runtimeExtractedByteCount
          + installation.model.byteCount + installation.diarizationModel.byteCount - 100_000,
        available: 1), "受けた分は必要量から引く")

  let setup = harness.makeSetup()
  await setup.download()
  #expect(setup.state == .checked(.passed))
  #expect(LocalFileURLProtocol.receivedRanges(for: harness.modelURL) == ["bytes=100000-"])
  #expect(try Data(contentsOf: installation.modelFile) == model)
}

@MainActor
@Test func recoversFromNoConnectionOnRetry() async throws {
  let harness = Harness(modelStub: .init(body: model, failImmediately: true))
  let setup = harness.makeSetup()

  await setup.download()
  #expect(setup.state == .failed(.network))

  LocalFileURLProtocol.set(.init(body: model), for: harness.modelURL)
  await setup.download()
  #expect(setup.state == .checked(.passed))
  #expect(try Data(contentsOf: harness.installation.modelFile) == model)
}

@MainActor
@Test func failsAndKeepsNoFileOnChecksumMismatch() async {
  let harness = Harness(modelSHA256: String(repeating: "0", count: 64))
  let setup = harness.makeSetup()

  await setup.download()

  let installation = harness.installation
  #expect(setup.state == .failed(.checksumMismatch))
  #expect(!harness.exists(installation.modelFile))
  #expect(!harness.exists(installation.directory.appending(path: "model.gguf.part")))
}

@MainActor
@Test func downloadsOnlyDiarizationModelWhenTranscriptionIsInstalled() async throws {
  let harness = Harness()
  let installation = harness.installation
  await harness.makeSetup().download()
  try FileManager.default.removeItem(at: installation.diarizationModelFile)
  let stub = StubCheck()
  let setup = harness.makeSetup(selfCheck: stub.run)

  setup.refresh()
  #expect(setup.state == .diarizationModelMissing, "音声認識は取得済みで話者分離のモデルだけが無い")
  #expect(installation.isInstalled, "文字起こしは話者分離のモデルの有無に左右されない")

  await setup.download()

  #expect(setup.state == .checked(.passed))
  #expect(harness.requestCount(harness.runtimeURL) == 1, "ランタイムを取り直さない")
  #expect(harness.requestCount(harness.modelURL) == 1, "Haas を取り直さない")
  #expect(harness.requestCount(harness.diarizationURL) == 2)
  #expect(try Data(contentsOf: installation.diarizationModelFile) == diarizationModel)
  #expect(stub.calls == 1)
}

@MainActor
@Test func refusesDiarizationModelWhenSpaceIsInsufficient() async throws {
  let harness = Harness()
  let installation = harness.installation
  await harness.makeSetup().download()
  try FileManager.default.removeItem(at: installation.diarizationModelFile)
  let setup = harness.makeSetup(available: 1000)

  await setup.download()

  #expect(
    setup.state
      == .insufficientSpace(required: installation.diarizationModel.byteCount, available: 1000))
  #expect(harness.requestCount(harness.diarizationURL) == 1, "要求を送らない")
}

@MainActor
@Test func diarizationModelChecksumMismatchKeepsNoFile() async {
  let harness = Harness(diarizationSHA256: String(repeating: "0", count: 64))
  let setup = harness.makeSetup()

  await setup.download()

  let installation = harness.installation
  #expect(setup.state == .failed(.checksumMismatch))
  #expect(!harness.exists(installation.diarizationModelFile))
  #expect(!harness.exists(installation.directory.appending(path: "diarization.gguf.part")))
}

@MainActor
@Test func failsAndCleansUpWhenRuntimeIsNotAZip() async throws {
  let harness = Harness(runtimeBody: Data("not a zip".utf8))
  let setup = harness.makeSetup()

  await setup.download()

  let installation = harness.installation
  #expect(setup.state == .failed(.extraction))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: installation.directory.path).isEmpty,
    "zip と展開の一時ディレクトリが残らない")
  #expect(harness.requestCount(harness.modelURL) == 0, "ランタイムが無ければモデルを取らない")
}

@MainActor
@Test func sendsOneRequestPerFileWhenPressedTwice() async {
  let harness = Harness()
  let setup = harness.makeSetup()

  async let first: Void = setup.download()
  async let second: Void = setup.download()
  _ = await (first, second)

  #expect(setup.state == .checked(.passed))
  #expect(harness.requestCount(harness.runtimeURL) == 1)
  #expect(harness.requestCount(harness.modelURL) == 1)
}

@MainActor
@Test func keepsFailureWhenRefreshedAfterFailedDownload() async {
  let harness = Harness(modelStub: .init(body: model, failImmediately: true))
  let setup = harness.makeSetup()
  await setup.download()
  #expect(setup.state == .failed(.network))

  setup.refresh()

  #expect(setup.state == .failed(.network), "設定を開き直しても失敗の表示が残る")
}

@MainActor
@Test func reportsNotInstalledAfterUserDeletesModel() async throws {
  let harness = Harness()
  let setup = harness.makeSetup()
  await setup.download()
  #expect(setup.state == .checked(.passed))

  try FileManager.default.removeItem(at: harness.installation.modelFile)
  setup.refresh()

  #expect(setup.state == .notInstalled)
}

@MainActor
@Test func downloadRunsRealSelfCheckAndFailsOnEmptyTranscript() async throws {
  let harness = Harness()
  // Harness のランタイムの `speech` は何も出さずに 0 で終わる。
  let setup = harness.makeSetup { installation in
    await runSelfCheck(
      executable: installation.executable, model: installation.modelFile,
      audio: URL(filePath: "/dev/null"), reference: "あ", timeout: .seconds(10),
      log: installation.selfCheckLog)
  }

  await setup.download()

  #expect(setup.state == .checked(.failed))
  let log = try String(contentsOf: harness.installation.selfCheckLog, encoding: .utf8)
  #expect(log.contains("selfcheck failed error.type=cer_over_threshold cer=1.0000"))
}

@MainActor
@Test func reinstallRemovesRuntimeAndModelThenDownloadsAgain() async throws {
  let harness = Harness()
  let stub = StubCheck()
  stub.outcome = .failed
  let setup = harness.makeSetup(selfCheck: stub.run)
  await setup.download()
  #expect(setup.state == .checked(.failed))
  try Data("broken".utf8).write(to: harness.installation.modelFile)

  stub.outcome = .passed
  await setup.reinstall()

  #expect(setup.state == .checked(.passed))
  #expect(harness.requestCount(harness.runtimeURL) == 2, "ランタイムを取り直す")
  #expect(harness.requestCount(harness.modelURL) == 2, "モデルを取り直す")
  #expect(try Data(contentsOf: harness.installation.modelFile) == model)
  #expect(stub.calls == 2)
}

@MainActor
@Test func reinstallStopsWithoutRequestsWhenRemovalFails() async throws {
  let harness = Harness()
  let stub = StubCheck()
  stub.outcome = .failed
  let setup = harness.makeSetup(selfCheck: stub.run)
  await setup.download()
  let directory = harness.installation.directory.path
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
  }

  await setup.reinstall()

  #expect(setup.state == .failed(.removal))
  #expect(harness.requestCount(harness.runtimeURL) == 1, "消せなければ取り直さない")
  #expect(harness.requestCount(harness.modelURL) == 1, "消せなければ取り直さない")
  #expect(stub.calls == 1)
}

@MainActor
@Test func checkRetriesOnlySelfCheck() async {
  let harness = Harness()
  let stub = StubCheck()
  stub.outcome = .timedOut
  let setup = harness.makeSetup(selfCheck: stub.run)
  await setup.download()
  #expect(setup.state == .checked(.timedOut))

  stub.outcome = .passed
  await setup.check()

  #expect(setup.state == .checked(.passed))
  #expect(stub.calls == 2)
  #expect(harness.requestCount(harness.runtimeURL) == 1, "動作確認だけをやり直す")
  #expect(harness.requestCount(harness.modelURL) == 1, "動作確認だけをやり直す")
}

@MainActor
@Test func startsSelfCheckWhenInstalledAtLaunch() async throws {
  let harness = Harness()
  await harness.makeSetup().download()
  let stub = StubCheck()

  let setup = harness.makeSetup(selfCheck: stub.run)

  #expect(setup.state == .checking, "起動後に取得済みなら確認中から始める")
  try await waitUntil { setup.state == .checked(.passed) }
  #expect(stub.calls == 1)
}

@MainActor
@Test func ignoresDownloadWhileChecking() async throws {
  let harness = Harness()
  let stub = StubCheck()
  stub.holds = true
  let setup = harness.makeSetup(selfCheck: stub.run)
  let first = Task { await setup.download() }
  try await waitUntil { stub.isHolding }
  #expect(setup.state == .checking)

  await setup.download()
  await setup.check()
  await setup.reinstall()
  #expect(setup.state == .checking, "確認中の操作は何もしない")

  stub.release()
  await first.value
  #expect(setup.state == .checked(.passed))
  #expect(stub.calls == 1, "2 回押しても動作確認は 1 回")
  #expect(harness.requestCount(harness.runtimeURL) == 1)
  #expect(harness.requestCount(harness.modelURL) == 1)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_E2E"] == "1"))
func realDownloadInstallsRuntimeAndModel() async {
  let setup = SpeechSetup(selfCheck: { _ in .passed })
  await setup.download()

  let installation = SpeechInstallation.standard
  #expect(setup.state == .checked(.passed))
  #expect(installation.isInstalled)
  #expect(installation.hasDiarizationModel)
  #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
  #expect(getxattr(installation.executable.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
  #expect(errno == ENOATTR)
}
