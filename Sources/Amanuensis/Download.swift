import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "download")

enum DownloadError: Error, Equatable {
  case network(URLError.Code)
  case unexpectedResponse(status: Int)
  case checksumMismatch
  case fileSystem
}

/// `file` を取得し、sha256 が合えば `destination` へ移す。
///
/// 受けた分は `destination` と同じ場所の `<fileName>.part` に追記し、失敗しても残す。
/// 次の呼び出しは `.part` の続きから Range で取る。`destination` にファイルがあることが照合済みの印になる。
/// 自動の再試行はしない。
func download(
  _ file: RemoteFile, to destination: URL, session: URLSession,
  onProgress: @Sendable (Int64) -> Void
) async throws(DownloadError) {
  do {
    try await fetchAndVerify(file, to: destination, session: session, onProgress: onProgress)
  } catch {
    logger.error(
      "download failed file=\(file.fileName, privacy: .public) error.type=\(error.logType, privacy: .public) app.error.origin=system app.error.transient=\(error.isTransient, privacy: .public)"
    )
    throw error
  }
  logger.info(
    "download verified file=\(file.fileName, privacy: .public) bytes=\(file.byteCount, privacy: .public)"
  )
}

extension DownloadError {
  fileprivate var logType: String {
    switch self {
    case .network: "network"
    case .unexpectedResponse: "unexpected_response"
    case .checksumMismatch: "checksum_mismatch"
    case .fileSystem: "file_system"
    }
  }

  fileprivate var isTransient: Bool {
    if case .network = self { true } else { false }
  }
}

private func fetchAndVerify(
  _ file: RemoteFile, to destination: URL, session: URLSession,
  onProgress: @Sendable (Int64) -> Void
) async throws(DownloadError) {
  let fileManager = FileManager.default
  let directory = destination.deletingLastPathComponent()
  let part = directory.appending(path: file.fileName + ".part")
  try fileSystem {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var offset = Int64(
    (try? fileManager.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0)
  if offset > file.byteCount {
    try fileSystem { try fileManager.removeItem(at: part) }
    offset = 0
  }
  if offset < file.byteCount {
    try await fetch(file, from: offset, into: part, session: session, onProgress: onProgress)
  }

  guard try fileSystem({ try sha256(of: part) }) == file.sha256 else {
    try? fileManager.removeItem(at: part)
    throw .checksumMismatch
  }
  try fileSystem {
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: part)
    } else {
      try fileManager.moveItem(at: part, to: destination)
    }
  }
}

/// `.part` を `offset` の続きから埋める。戻ったとき `.part` は `file.byteCount` 以下の長さで、受信を最後まで終えている。
private func fetch(
  _ file: RemoteFile, from offset: Int64, into part: URL, session: URLSession,
  onProgress: @Sendable (Int64) -> Void
) async throws(DownloadError) {
  var request = URLRequest(url: file.url)
  if offset > 0 {
    request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
  }
  if offset == 0 {
    guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
      throw .fileSystem
    }
  }
  let handle = try fileSystem { try FileHandle(forWritingTo: part) }
  defer { try? handle.close() }
  logger.info(
    "download started file=\(file.fileName, privacy: .public) offset=\(offset, privacy: .public)")

  let events = AsyncStream<TaskEvent> { continuation in
    let task = session.dataTask(with: request)
    task.delegate = TaskEventRelay(continuation: continuation)
    continuation.onTermination = { _ in task.cancel() }
    task.resume()
  }
  var received = offset
  var status = 0
  for await event in events {
    switch event {
    case .response(let code, let contentRange):
      status = code
      switch code {
      case 206:
        guard contentRangeStart(contentRange) == offset else {
          try? FileManager.default.removeItem(at: part)
          throw .unexpectedResponse(status: code)
        }
        _ = try fileSystem { try handle.seekToEnd() }
      case 200:
        if offset > 0 {
          logger.info("download restarted file=\(file.fileName, privacy: .public)")
        }
        try fileSystem { try handle.truncate(atOffset: 0) }
        received = 0
      default:
        throw .unexpectedResponse(status: code)
      }
    case .data(let data):
      received += Int64(data.count)
      guard received <= file.byteCount else {
        try? handle.close()
        try? FileManager.default.removeItem(at: part)
        throw .unexpectedResponse(status: status)
      }
      try fileSystem { try handle.write(contentsOf: data) }
      onProgress(received)
    case .completed(nil):
      return
    case .completed(let code?):
      throw .network(code)
    }
  }
  // 呼び出し側のタスクが取り消されると、完了を受けずにストリームが終わる。
  throw .network(.cancelled)
}

/// `bytes <start>-<end>/<total>` の start。
private func contentRangeStart(_ value: String?) -> Int64? {
  guard let value, value.hasPrefix("bytes ") else { return nil }
  return Int64(value.dropFirst("bytes ".count).prefix { $0 != "-" })
}

private func sha256(of url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = SHA256()
  while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
    hasher.update(data: chunk)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func fileSystem<T>(_ body: () throws -> T) throws(DownloadError) -> T {
  do {
    return try body()
  } catch {
    throw .fileSystem
  }
}

private enum TaskEvent: Sendable {
  case response(status: Int, contentRange: String?)
  case data(Data)
  case completed(URLError.Code?)
}

/// データタスクのデリゲートの呼び出しを、受けた順に `AsyncStream` へ流す。
private final class TaskEventRelay: NSObject, URLSessionDataDelegate, Sendable {
  let continuation: AsyncStream<TaskEvent>.Continuation

  init(continuation: AsyncStream<TaskEvent>.Continuation) {
    self.continuation = continuation
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let http = response as? HTTPURLResponse
    continuation.yield(
      .response(
        status: http?.statusCode ?? 0,
        contentRange: http?.value(forHTTPHeaderField: "Content-Range")))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    continuation.yield(.completed(error.map { ($0 as? URLError)?.code ?? .unknown }))
    continuation.finish()
  }
}
