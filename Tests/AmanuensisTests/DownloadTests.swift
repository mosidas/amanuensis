import Foundation
import Testing
import os

@testable import Amanuensis

private let fixture = Data(repeating: 0x61, count: 300_000)
// head -c 300000 /dev/zero | tr '\0' a | shasum -a 256
private let fixtureSHA256 = "12e1b9b179b29a4f7e5889b185d7ac71bff0ad1f49a7b391d0911b737a0f5381"

private struct Harness {
  let url = LocalFileURLProtocol.makeURL()
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "DownloadTests-\(UUID().uuidString)")
  let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalFileURLProtocol.self]
    return URLSession(configuration: configuration)
  }()
  let progress = OSAllocatedUnfairLock(initialState: [Int64]())

  var destination: URL { directory.appending(path: "fixture.bin") }
  var part: URL { directory.appending(path: "fixture.bin.part") }

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func run(_ stub: LocalFileURLProtocol.Stub, sha256: String = fixtureSHA256)
    async throws(DownloadError)
  {
    LocalFileURLProtocol.set(stub, for: url)
    let file = RemoteFile(
      url: url, byteCount: Int64(fixture.count), sha256: sha256, fileName: "fixture.bin")
    try await download(file, to: destination, session: session) { [progress] bytes in
      progress.withLock { $0.append(bytes) }
    }
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func size(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
  }
}

@Test func downloadsWholeFile() async throws {
  let harness = try Harness()
  try await harness.run(.init(body: fixture))
  #expect(try Data(contentsOf: harness.destination) == fixture)
  #expect(!harness.exists(harness.part), "照合に通ったら .part は残らない")
  #expect(harness.progress.withLock { $0.last } == 300_000)
}

@Test func resumesFromPartAfterConnectionLost() async throws {
  let harness = try Harness()
  await #expect(throws: DownloadError.network(.networkConnectionLost)) {
    try await harness.run(.init(body: fixture, cutAfter: 100_000))
  }
  #expect(try harness.size(harness.part) == 100_000, "切れるまでに受けた分が .part に残る")
  #expect(!harness.exists(harness.destination))

  try await harness.run(.init(body: fixture))
  #expect(LocalFileURLProtocol.receivedRanges(for: harness.url).last == "bytes=100000-")
  #expect(try Data(contentsOf: harness.destination) == fixture)
  #expect(harness.progress.withLock { $0.last } == 300_000)
}

@Test func restartsWhenServerIgnoresRange() async throws {
  let harness = try Harness()
  await #expect(throws: DownloadError.network(.networkConnectionLost)) {
    try await harness.run(.init(body: fixture, cutAfter: 100_000))
  }
  try await harness.run(.init(body: fixture, ignoreRange: true))
  #expect(LocalFileURLProtocol.receivedRanges(for: harness.url).last == "bytes=100000-")
  #expect(try Data(contentsOf: harness.destination) == fixture, "200 なら重複せず最初から取り直す")
}

@Test func rejectsChecksumMismatch() async throws {
  let harness = try Harness()
  await #expect(throws: DownloadError.checksumMismatch) {
    try await harness.run(.init(body: fixture), sha256: String(repeating: "0", count: 64))
  }
  #expect(!harness.exists(harness.destination))
  #expect(!harness.exists(harness.part))
}

@Test func reportsNoConnection() async throws {
  let harness = try Harness()
  await #expect(throws: DownloadError.network(.notConnectedToInternet)) {
    try await harness.run(.init(body: fixture, failImmediately: true))
  }
  #expect(!harness.exists(harness.destination))
}

@Test func abortsWhenBodyExceedsByteCount() async throws {
  let harness = try Harness()
  await #expect(throws: DownloadError.unexpectedResponse(status: 200)) {
    try await harness.run(.init(body: fixture, extraBytes: 1))
  }
  #expect(!harness.exists(harness.part))
  #expect(!harness.exists(harness.destination))
}
