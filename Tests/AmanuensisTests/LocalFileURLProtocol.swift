import Foundation
import os

/// URL ごとに登録した本文を返すスタブ。`Range: bytes=<n>-` に 206 で応える。
final class LocalFileURLProtocol: URLProtocol {
  struct Stub: Sendable {
    var body: Data
    /// 本文のこの位置まで送ったら接続が切れたことにする。
    var cutAfter: Int?
    /// Range を無視して常に 200 で全体を返す。
    var ignoreRange = false
    /// 応答を返さずに接続なしで失敗する。
    var failImmediately = false
    /// 本文の末尾に足す余分な長さ。
    var extraBytes = 0
  }

  private struct State: Sendable {
    var stubs: [URL: Stub] = [:]
    var ranges: [URL: [String?]] = [:]
  }

  // swift-testing はテストを並行で実行する。登録簿はテストごとに一意な URL で引く。
  private static let state = OSAllocatedUnfairLock(initialState: State())

  static func makeURL() -> URL {
    URL(string: "https://stub.invalid/\(UUID().uuidString)/fixture.bin")!
  }

  static func set(_ stub: Stub, for url: URL) {
    state.withLock { $0.stubs[url] = stub }
  }

  /// 受け取った Range ヘッダー(無ければ nil)を要求の順に返す。
  static func receivedRanges(for url: URL) -> [String?] {
    state.withLock { $0.ranges[url] ?? [] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let range = request.value(forHTTPHeaderField: "Range")
    let stub = Self.state.withLock { state in
      state.ranges[url, default: []].append(range)
      return state.stubs[url]!
    }
    if stub.failImmediately {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let body = stub.body + Data(repeating: 0x61, count: stub.extraBytes)
    let start =
      stub.ignoreRange
      ? 0
      : range.flatMap { Int($0.dropFirst("bytes=".count).prefix { $0 != "-" }) } ?? 0
    var headers = ["Content-Length": String(body.count - start)]
    if start > 0 {
      headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
    }
    let response = HTTPURLResponse(
      url: url, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1",
      headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let end = min(body.count, stub.cutAfter ?? body.count)
    var position = start
    while position < end {
      let next = min(end, position + 65_536)
      client?.urlProtocol(self, didLoad: body.subdata(in: position..<next))
      position = next
    }
    if end < body.count {
      // URLSession は失敗を受けた時点でデリゲートへ渡していない本文を捨てる。送った分を届けてから切る。
      perform(#selector(loseConnection), with: nil, afterDelay: 0.2)
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  @objc private func loseConnection() {
    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
  }

  override func stopLoading() {}
}
