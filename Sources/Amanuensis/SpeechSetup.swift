import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "setup")

/// 音声認識のランタイムとモデル、話者分離のモデルの置き場所と取得先。
struct SpeechInstallation: Sendable {
  let directory: URL
  var runtime = RemoteFile.speechRuntime
  /// `unzip -l` が示す `runtime` の展開後の合計。
  var runtimeExtractedByteCount: Int64 = 21_074_311
  var model = RemoteFile.haasModel
  var diarizationModel = RemoteFile.nemotronDiarization
  /// 本文を起こすエンジン。使う側が設定から `selecting(_:)` で写す。
  var engine = TranscriptionEngine.haas
  var whisperModel = RemoteFile.whisperLargeV3Turbo
  /// アプリに同梱する whisper-cli(scripts/bundle.sh が置く)。
  var whisperExecutable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/whisper-cli")

  var runtimeDirectory: URL { directory.appending(path: "runtime") }
  var executable: URL { runtimeDirectory.appending(path: "speech") }
  var modelFile: URL { directory.appending(path: model.fileName) }
  var selfCheckLog: URL { directory.appending(path: "selfcheck.log") }
  var diarizationModelFile: URL { directory.appending(path: diarizationModel.fileName) }
  var whisperModelFile: URL { directory.appending(path: whisperModel.fileName) }
  /// ランタイムと Haas が揃っている。動作確認はエンジンによらず Haas で行うので、どのエンジンでも要る。
  var hasHaas: Bool { exists(executable) && exists(modelFile) }
  var hasWhisperModel: Bool { exists(whisperModelFile) }
  /// 選んだエンジンで文字起こしするのに要るファイルが揃っている。話者分離のモデルは含めない。
  var isInstalled: Bool { hasHaas && (engine == .haas || hasWhisperModel) }
  var hasDiarizationModel: Bool { exists(diarizationModelFile) }
  /// 本文を起こすモデル。
  var recognitionModel: RemoteFile { engine == .whisper ? whisperModel : model }

  /// `engine` を選んだときに要るファイルの集合。
  func selecting(_ engine: TranscriptionEngine) -> SpeechInstallation {
    var selected = self
    selected.engine = engine
    return selected
  }

  static let standard = SpeechInstallation(
    directory: URL.applicationSupportDirectory.appending(path: "amanuensis"))
}

enum SetupState: Equatable {
  case notInstalled
  /// ランタイムと Haas はあり、話者分離のモデルだけが無い。
  case diarizationModelMissing
  /// ランタイムと Haas はあり、選んだエンジンの Whisper のモデルが無い。
  /// `downloadBytes` は Whisper のモデルと、無ければ話者分離のモデルの合計。
  case whisperModelMissing(downloadBytes: Int64)
  case downloading(receivedBytes: Int64, totalBytes: Int64)
  case verifying
  case checking
  case checked(SelfCheckOutcome)
  case insufficientSpace(required: Int64, available: Int64)
  case failed(SetupFailure)
}

enum SetupFailure: Error, Equatable {
  case network, server, checksumMismatch, fileSystem, extraction, removal
}

extension URLSession {
  static let speechDownloads: URLSession = {
    let configuration = URLSessionConfiguration.default
    // shortcut: 無通信 60 秒で打ち切る(実測なしの仮の値), 遅い回線で誤って切れる報告があれば実測から決め直す
    configuration.timeoutIntervalForRequest = 60
    // shortcut: 2 時間は最も大きい Whisper のモデル(874 MB)を 1.5 Mbps で取り切る 4,662 秒を超える長さ, それより遅い回線の利用者が出たら延ばす
    configuration.timeoutIntervalForResource = 7200
    return URLSession(configuration: configuration)
  }()
}

/// ランタイムとモデルの取得と動作確認の状態を持つ。状態の持ち主はこの型だけである。
@MainActor @Observable final class SpeechSetup {
  private(set) var state = SetupState.notInstalled
  private(set) var engine: TranscriptionEngine
  private let base: SpeechInstallation
  private let session: URLSession
  private let availableCapacity: (URL) throws -> Int64
  private let selfCheck: (SpeechInstallation) async -> SelfCheckOutcome
  private let setting: TranscriptionSetting

  /// 選んだエンジンに要るファイルの集合。
  var installation: SpeechInstallation { base.selecting(engine) }

  init(
    installation: SpeechInstallation = .standard, session: URLSession = .speechDownloads,
    availableCapacity: @escaping (URL) throws -> Int64 = volumeAvailableCapacity,
    selfCheck: @escaping (SpeechInstallation) async -> SelfCheckOutcome = runBundledSelfCheck,
    setting: TranscriptionSetting = TranscriptionSetting()
  ) {
    self.base = installation
    self.setting = setting
    self.engine = setting.engine
    self.session = session
    self.availableCapacity = availableCapacity
    self.selfCheck = selfCheck
    refresh()
  }

  /// 未取得か確認済みのときだけ、保存したエンジンとディスクの中身から状態を導き直す。取得と確認の途中と失敗の表示は変えない。
  /// 未取得からファイルが揃っていたら(起動後に初めて開いたとき)動作確認を始める。
  func refresh() {
    switch state {
    case .notInstalled, .diarizationModelMissing, .whisperModelMissing:
      engine = setting.engine
      if let missing {
        state = missing
      } else {
        state = .checking
        Task { await runCheck() }
      }
    case .checked:
      engine = setting.engine
      if let missing { state = missing }
    case .downloading, .verifying, .checking, .insufficientSpace, .failed: return
    }
  }

  /// 選んだエンジンに足りないファイルを示す状態。揃っていれば nil。
  private var missing: SetupState? {
    if !installation.hasHaas { return .notInstalled }
    if !installation.isInstalled {
      return .whisperModelMissing(
        downloadBytes: installation.whisperModel.byteCount
          + (installation.hasDiarizationModel ? 0 : installation.diarizationModel.byteCount))
    }
    if !installation.hasDiarizationModel { return .diarizationModelMissing }
    return nil
  }

  /// 足りないファイル(ランタイム・Haas・Whisper を選んでいれば Whisper のモデル・話者分離のモデル)を取得して展開し、
  /// 動作確認する。取得と確認の途中に呼ばれたら何もしない。
  func download() async {
    guard !isBusy else { return }
    let needsRuntime = !exists(installation.executable)
    let needsModel = !exists(installation.modelFile)
    let needsWhisperModel = installation.engine == .whisper && !installation.hasWhisperModel
    let needsDiarizationModel = !exists(installation.diarizationModelFile)
    let pending = [
      needsRuntime ? installation.runtime : nil,
      needsModel ? installation.model : nil,
      needsWhisperModel ? installation.whisperModel : nil,
      needsDiarizationModel ? installation.diarizationModel : nil,
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
      "setup started required=\(required, privacy: .public) available=\(available, privacy: .public) engine=\(self.engine.rawValue, privacy: .public)"
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
        done += installation.model.byteCount
      }
      if needsWhisperModel {
        try await fetch(installation.whisperModel, before: done, of: total)
        done += installation.whisperModel.byteCount
      }
      if needsDiarizationModel {
        try await fetch(installation.diarizationModel, before: done, of: total)
      }
    } catch {
      state = .failed(error)
      return
    }
    logger.info("setup installed")
    await runCheck()
  }

  /// 動作確認だけをやり直す。取得と確認の途中に呼ばれたら何もしない。
  func check() async {
    guard !isBusy else { return }
    await runCheck()
  }

  /// ランタイムとモデルを消してから取得し直す。取得と確認の途中に呼ばれたら何もしない。
  /// 消せなければ要求を送らずに止める。
  func reinstall() async {
    guard !isBusy else { return }
    logger.info("setup reinstall started")
    do {
      for url in [installation.runtimeDirectory, installation.modelFile] where exists(url) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      logger.error("setup failed step=remove error.type=file_system app.error.origin=system")
      state = .failed(.removal)
      return
    }
    await download()
  }

  /// 本文を起こすエンジンを保存し、そのエンジンに要るファイルから状態を導き直す(替える前の取得の失敗と容量不足の表示は残さない)。
  /// 取得と確認の途中に呼ばれたら何もしない。
  func select(_ engine: TranscriptionEngine) {
    guard !isBusy else { return }
    setting.setEngine(engine)
    logger.info("setup engine selected engine=\(engine.rawValue, privacy: .public)")
    switch state {
    case .failed, .insufficientSpace: state = .notInstalled
    case .notInstalled, .diarizationModelMissing, .whisperModelMissing, .downloading, .verifying,
      .checking, .checked:
      break
    }
    refresh()
  }

  var isBusy: Bool {
    switch state {
    case .downloading, .verifying, .checking: true
    case .notInstalled, .diarizationModelMissing, .whisperModelMissing, .checked,
      .insufficientSpace, .failed:
      false
    }
  }

  private func runCheck() async {
    state = .checking
    logger.info("selfcheck started")
    state = .checked(await selfCheck(installation))
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
