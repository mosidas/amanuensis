import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "setup")

/// 音声認識のランタイムとモデルの置き場所と取得先。
struct SpeechInstallation: Sendable {
  let directory: URL
  var runtime = RemoteFile.speechRuntime
  /// `unzip -l` が示す `runtime` の展開後の合計。
  var runtimeExtractedByteCount: Int64 = 21_074_311
  var model = RemoteFile.haasModel

  var runtimeDirectory: URL { directory.appending(path: "runtime") }
  var executable: URL { runtimeDirectory.appending(path: "speech") }
  var modelFile: URL { directory.appending(path: model.fileName) }
  var isInstalled: Bool { exists(executable) && exists(modelFile) }

  static let standard = SpeechInstallation(
    directory: URL.applicationSupportDirectory.appending(path: "amanuensis"))
}

enum SetupState: Equatable {
  case notInstalled
  case downloading(receivedBytes: Int64, totalBytes: Int64)
  case verifying
  case installed
  case insufficientSpace(required: Int64, available: Int64)
  case failed(SetupFailure)
}

enum SetupFailure: Error, Equatable {
  case network, server, checksumMismatch, fileSystem, extraction
}

extension URLSession {
  static let speechDownloads: URLSession = {
    let configuration = URLSessionConfiguration.default
    // shortcut: 無通信 60 秒で打ち切る(実測なしの仮の値), 遅い回線で誤って切れる報告があれば実測から決め直す
    configuration.timeoutIntervalForRequest = 60
    // shortcut: 1 時間は 656 MB を 1.5 Mbps で取り切る長さ, それより遅い回線の利用者が出たら延ばす
    configuration.timeoutIntervalForResource = 3600
    return URLSession(configuration: configuration)
  }()
}

/// ランタイムとモデルの取得の状態を持つ。状態の持ち主はこの型だけである。
@MainActor @Observable final class SpeechSetup {
  private(set) var state = SetupState.notInstalled
  private(set) var selfCheck = SelfCheckState.idle
  let installation: SpeechInstallation
  private let session: URLSession
  private let availableCapacity: (URL) throws -> Int64

  init(
    installation: SpeechInstallation = .standard, session: URLSession = .speechDownloads,
    availableCapacity: @escaping (URL) throws -> Int64 = volumeAvailableCapacity
  ) {
    self.installation = installation
    self.session = session
    self.availableCapacity = availableCapacity
    refresh()
  }

  /// 未取得か取得済みのときだけディスクの中身から状態を導き直す。取得の途中と失敗の表示は変えない。
  func refresh() {
    switch state {
    case .notInstalled, .installed:
      state = installation.isInstalled ? .installed : .notInstalled
    case .downloading, .verifying, .insufficientSpace, .failed: return
    }
  }

  /// 足りないファイルを取得して展開する。取得の途中に呼ばれたら何もしない。
  func download() async {
    switch state {
    case .downloading, .verifying: return
    default: break
    }
    selfCheck = .idle
    let needsRuntime = !exists(installation.executable)
    let needsModel = !exists(installation.modelFile)
    let pending = [
      needsRuntime ? installation.runtime : nil,
      needsModel ? installation.model : nil,
    ]
    .compactMap { $0 }
    let available: Int64
    do {
      try FileManager.default.createDirectory(
        at: installation.directory, withIntermediateDirectories: true)
    } catch {
      logger.error(
        "setup failed step=create_directory error.type=file_system app.error.origin=system")
      state = .failed(.fileSystem)
      return
    }
    do {
      available = try availableCapacity(installation.directory)
    } catch {
      logger.error("setup failed step=capacity error.type=file_system app.error.origin=system")
      state = .failed(.fileSystem)
      return
    }
    let required =
      pending.reduce(0) { $0 + max(0, $1.byteCount - partLength(of: $1)) }
      + (needsRuntime ? installation.runtimeExtractedByteCount : 0)
    guard required <= available else {
      logger.error(
        "setup refused error.type=insufficient_space app.error.origin=client required=\(required, privacy: .public) available=\(available, privacy: .public)"
      )
      state = .insufficientSpace(required: required, available: available)
      return
    }
    logger.info(
      "setup started required=\(required, privacy: .public) available=\(available, privacy: .public)"
    )

    let total = pending.reduce(0) { $0 + $1.byteCount }
    state = .downloading(receivedBytes: 0, totalBytes: total)
    do throws(SetupFailure) {
      var done: Int64 = 0
      if needsRuntime {
        try await fetch(installation.runtime, before: done, of: total)
        try await installRuntime()
        done += installation.runtime.byteCount
      }
      if needsModel {
        try await fetch(installation.model, before: done, of: total)
      }
    } catch {
      state = .failed(error)
      return
    }
    logger.info("setup installed")
    state = .installed
  }

  /// 同梱の音声で動作確認する。動作確認の途中に呼ばれたら何もしない。
  func runSelfCheck() async {
    guard selfCheck != .running else { return }
    selfCheck = .running
    selfCheck = await runBundledSelfCheck(installation)
  }

  private func destination(of file: RemoteFile) -> URL {
    installation.directory.appending(path: file.fileName)
  }

  private func partLength(of file: RemoteFile) -> Int64 {
    let part = installation.directory.appending(path: file.fileName + ".part")
    return Int64((try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0)
  }

  /// `file` を取得し、受けた量を `before` に足して `total` に対する進み具合として流す。
  private func fetch(_ file: RemoteFile, before done: Int64, of total: Int64)
    async throws(SetupFailure)
  {
    let (updates, continuation) = AsyncStream.makeStream(
      of: Int64.self, bufferingPolicy: .bufferingNewest(1))
    let destination = destination(of: file)
    let session = session
    let transfer = Task { () async -> Result<Void, DownloadError> in
      defer { continuation.finish() }
      do throws(DownloadError) {
        try await Amanuensis.download(file, to: destination, session: session) {
          continuation.yield($0)
        }
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    for await received in updates {
      let receivedBytes = done + received
      state =
        receivedBytes == total
        ? .verifying : .downloading(receivedBytes: receivedBytes, totalBytes: total)
    }
    do throws(DownloadError) {
      try await transfer.value.get()
    } catch {
      throw SetupFailure(error)
    }
  }

  /// 取得済みの zip を一時ディレクトリへ展開して `runtime` へ置き、zip を消す。
  private func installRuntime() async throws(SetupFailure) {
    let fileManager = FileManager.default
    let zip = destination(of: installation.runtime)
    let temporary = installation.directory.appending(path: "runtime.tmp")
    // 前の実行が展開の途中で止まった残りは古いので消す。
    try? fileManager.removeItem(at: temporary)
    let status = await extract(zip, to: temporary)
    guard status == 0 else {
      logger.error(
        "extraction failed status=\(status.map(String.init) ?? "not_launched", privacy: .public)")
      try? fileManager.removeItem(at: temporary)
      try? fileManager.removeItem(at: zip)
      throw .extraction
    }
    do {
      // 実行ファイルの無い `runtime` は壊れているので置き換える。
      try? fileManager.removeItem(at: installation.runtimeDirectory)
      try fileManager.moveItem(at: temporary, to: installation.runtimeDirectory)
      try fileManager.removeItem(at: zip)
    } catch {
      logger.error(
        "setup failed step=install_runtime error.type=file_system app.error.origin=system")
      throw .fileSystem
    }
  }
}

extension SetupFailure {
  init(_ error: DownloadError) {
    switch error {
    case .network: self = .network
    case .unexpectedResponse: self = .server
    case .checksumMismatch: self = .checksumMismatch
    case .fileSystem: self = .fileSystem
    }
  }
}

/// `ditto -x -k` の終了コード。起動できなければ nil。
private func extract(_ zip: URL, to directory: URL) async -> Int32? {
  await withCheckedContinuation { continuation in
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, directory.path]
    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      continuation.resume(returning: nil)
    }
  }
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

private func volumeAvailableCapacity(_ directory: URL) throws -> Int64 {
  guard
    let capacity = try directory.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ]).volumeAvailableCapacityForImportantUsage
  else { throw CocoaError(.fileReadUnknown) }
  return capacity
}

// main.swift のトップレベルはテストバンドルで実行されないため、遅延初期化されるここに置く。
@MainActor let speechSetup = SpeechSetup()
