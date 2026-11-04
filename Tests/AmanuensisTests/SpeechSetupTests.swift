import CryptoKit
import Foundation
import Testing

@testable import Amanuensis

private let model = Data(repeating: 0x61, count: 300_000)
// head -c 300000 /dev/zero | tr '\0' a | shasum -a 256
private let modelSHA256 = "12e1b9b179b29a4f7e5889b185d7ac71bff0ad1f49a7b391d0911b737a0f5381"

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

@MainActor
private struct Harness {
  let runtimeURL = LocalFileURLProtocol.makeURL()
  let modelURL = LocalFileURLProtocol.makeURL()
  let installation: SpeechInstallation
  let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalFileURLProtocol.self]
    return URLSession(configuration: configuration)
  }()

  init(
    runtimeBody: Data = runtime, modelSHA256: String = modelSHA256,
    modelStub: LocalFileURLProtocol.Stub = .init(body: model)
  ) {
    var installation = SpeechInstallation(
      directory: FileManager.default.temporaryDirectory.appending(
        path: "SpeechSetupTests-\(UUID().uuidString)"))
    installation.runtime = RemoteFile(
      url: runtimeURL, byteCount: Int64(runtimeBody.count), sha256: sha256(runtimeBody),
      fileName: "runtime.zip")
    installation.model = RemoteFile(
      url: modelURL, byteCount: Int64(model.count), sha256: modelSHA256, fileName: "model.gguf")
    self.installation = installation
    LocalFileURLProtocol.set(.init(body: runtimeBody), for: runtimeURL)
    LocalFileURLProtocol.set(modelStub, for: modelURL)
  }

  func makeSetup(available: Int64 = 1 << 40) -> SpeechSetup {
    SpeechSetup(installation: installation, session: session, availableCapacity: { _ in available })
  }

  func requestCount(_ url: URL) -> Int { LocalFileURLProtocol.receivedRanges(for: url).count }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@MainActor
@Test func installsRuntimeAndModel() async throws {
  let harness = Harness()
  let setup = harness.makeSetup()
  #expect(setup.state == .notInstalled)

  await setup.download()

  let installation = harness.installation
  #expect(setup.state == .installed)
  #expect(installation.isInstalled)
  #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
  #expect(getxattr(installation.executable.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
  #expect(errno == ENOATTR, "展開したランタイムに quarantine の属性が付かない")
  #expect(try Data(contentsOf: installation.modelFile) == model)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: installation.directory.path).sorted()
      == ["model.gguf", "runtime"], "zip と .part と展開の一時ディレクトリが残らない")
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
          + installation.model.byteCount,
        available: 1000))
  #expect(harness.requestCount(harness.runtimeURL) == 0)
  #expect(harness.requestCount(harness.modelURL) == 0)
}

@MainActor
@Test func sendsRequestsWhenSpaceIsSufficient() async {
  let harness = Harness()
  let installation = harness.installation
  let required =
    installation.runtime.byteCount + installation.runtimeExtractedByteCount
    + installation.model.byteCount
  let setup = harness.makeSetup(available: required)

  await setup.download()

  #expect(setup.state == .installed)
  #expect(harness.requestCount(harness.runtimeURL) == 1)
  #expect(harness.requestCount(harness.modelURL) == 1)
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
          + installation.model.byteCount - 100_000,
        available: 1), "受けた分は必要量から引く")

  let setup = harness.makeSetup()
  await setup.download()
  #expect(setup.state == .installed)
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
  #expect(setup.state == .installed)
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

  #expect(setup.state == .installed)
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
  #expect(setup.state == .installed)

  try FileManager.default.removeItem(at: harness.installation.modelFile)
  setup.refresh()

  #expect(setup.state == .notInstalled)
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMANUENSIS_E2E"] == "1"))
func realDownloadInstallsRuntimeAndModel() async {
  let setup = SpeechSetup()
  await setup.download()

  let installation = SpeechInstallation.standard
  #expect(setup.state == .installed)
  #expect(installation.isInstalled)
  #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
  #expect(getxattr(installation.executable.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
  #expect(errno == ENOATTR)
}
