import Foundation
import Observation
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "recording")

/// 始まった取り込み。`stop` は書き終えて閉じたファイルの秒数を返す。
struct CaptureSession: Sendable {
  let stop: @Sendable () async throws -> TimeInterval
}

/// `file` へ取り込みを始める。録音中に取り込みが止まったら `onInterrupt` を呼ぶ。
typealias StartCapture =
  @MainActor (_ file: URL, _ onInterrupt: @escaping @Sendable (RecordingProblem) -> Void)
  async throws -> CaptureSession

struct Recording: Equatable {
  let startedAt: Date
  let folder: URL
  let trigger: RecordingTrigger
  fileprivate let session: CaptureSession
  fileprivate let activity: any NSObjectProtocol

  static func == (lhs: Recording, rhs: Recording) -> Bool {
    lhs.startedAt == rhs.startedAt && lhs.folder == rhs.folder && lhs.trigger == rhs.trigger
  }
}

enum RecorderState: Equatable {
  case idle, starting, finishing
  case recording(Recording)
}

/// 録音の状態を持つ。状態の持ち主はこの型だけである。失敗は経路ごとに 1 回だけ `report` へ渡す。
/// 停止か途中で止まって閉じた録音の会議フォルダーは 1 回だけ `saved` へ渡す。
@MainActor @Observable final class Recorder {
  private(set) var state = RecorderState.idle
  private let folder: RecordingFolder
  private let missingPermissions: () async -> [Permission]
  private let startCapture: StartCapture
  private let report: @MainActor (RecordingProblem) -> Void
  private let saved: @MainActor (URL) -> Void
  private let startTimeout: Duration
  /// 準備中の会議フォルダー。準備中に届いた中断を、この会議のものか見分ける。
  private var startingMeeting: URL?
  /// 準備中に届いた中断。開始が戻った直後に処理する。
  private var interruptedWhileStarting: RecordingProblem?

  init(
    folder: RecordingFolder, missingPermissions: @escaping () async -> [Permission],
    startCapture: @escaping StartCapture,
    report: @escaping @MainActor (RecordingProblem) -> Void,
    saved: @escaping @MainActor (URL) -> Void,
    // shortcut: 10 秒は実測 2 回(tap の作成 0.07 秒・開始 0.0002 秒、macOS 26.6)からの仮の値, capture started の start_ms を 20 回分集めたら p99.9 で決め直す
    startTimeout: Duration = .seconds(10)
  ) {
    self.folder = folder
    self.missingPermissions = missingPermissions
    self.startCapture = startCapture
    self.report = report
    self.saved = saved
    self.startTimeout = startTimeout
  }

  /// 待機中のときだけ録音を始める。`trigger` は誰が始めたかで、録音が持つ。
  func start(trigger: RecordingTrigger = .manual) async {
    guard state == .idle else { return }
    state = .starting
    let missing = await missingPermissions()
    guard missing.isEmpty else {
      logger.error(
        "recording refused error.type=permission_denied app.error.origin=client missing=\(missing.map(\.logName).joined(separator: ","), privacy: .public)"
      )
      refuse(.missingPermissions(missing))
      return
    }
    let startedAt = Date.now
    let meeting: URL
    do {
      meeting = try folder.makeMeetingFolder(at: startedAt)
    } catch {
      logger.error(
        "recording refused error.type=\(error.logName, privacy: .public) app.error.origin=client")
      refuse(error)
      return
    }
    startingMeeting = meeting
    defer {
      startingMeeting = nil
      interruptedWhileStarting = nil
    }
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "amanuensis is recording")
    let file = meeting.appending(path: "recording.caf")
    let onInterrupt: @Sendable (RecordingProblem) -> Void = { [weak self] problem in
      Task { @MainActor in self?.interrupt(meeting, problem) }
    }
    let session: CaptureSession
    do {
      session = try await captureWithTimeout(file, onInterrupt)
    } catch {
      let type = error is StartTimeout ? "timeout" : "capture_failed"
      logger.error(
        "recording failed step=start error.type=\(type, privacy: .public) app.error.origin=system")
      try? FileManager.default.removeItem(at: meeting)
      ProcessInfo.processInfo.endActivity(activity)
      refuse(error as? RecordingProblem ?? .captureFailed(.failed(step: "start", type: type)))
      return
    }
    if let problem = interruptedWhileStarting {
      logger.error(
        "recording failed step=record error.type=\(problem.logName, privacy: .public) app.error.origin=system folder.name=\(meeting.lastPathComponent, privacy: .public)"
      )
      do {
        _ = try await session.stop()
      } catch {
        logger.error(
          "recording failed step=stop error.type=save_failed app.error.origin=system folder.name=\(meeting.lastPathComponent, privacy: .public)"
        )
      }
      ProcessInfo.processInfo.endActivity(activity)
      refuse(problem)
      return
    }
    logger.info(
      "recording started trigger=\(trigger.logName, privacy: .public) folder.name=\(meeting.lastPathComponent, privacy: .public)"
    )
    state = .recording(
      Recording(
        startedAt: startedAt, folder: meeting, trigger: trigger, session: session,
        activity: activity))
  }

  /// 録音中のときだけ取り込みを止めてファイルを閉じる。
  func stop() async {
    guard case .recording(let recording) = state else { return }
    if await finish(recording) == nil { report(.saveFailed) } else { saved(recording.folder) }
  }

  /// 録音中のときだけ取り込みを止め、会議フォルダーを消す。
  func discard() async {
    guard case .recording(let recording) = state else { return }
    _ = await finish(recording)
    do {
      try FileManager.default.removeItem(at: recording.folder)
    } catch {
      logger.error(
        "recording failed step=discard error.type=file_system app.error.origin=system folder.name=\(recording.folder.lastPathComponent, privacy: .public)"
      )
      report(.discardFailed)
      return
    }
    logger.info(
      "recording discarded folder.name=\(recording.folder.lastPathComponent, privacy: .public)")
  }

  /// 取り込みを止めて待機中に戻す。閉じたファイルの秒数を返し、止められなければ nil を返す。
  private func finish(_ recording: Recording) async -> TimeInterval? {
    state = .finishing
    defer {
      ProcessInfo.processInfo.endActivity(recording.activity)
      state = .idle
    }
    do {
      let duration = try await recording.session.stop()
      logger.info(
        "recording stopped duration_s=\(duration, format: .fixed(precision: 1), privacy: .public) folder.name=\(recording.folder.lastPathComponent, privacy: .public)"
      )
      return duration
    } catch {
      logger.error(
        "recording failed step=stop error.type=save_failed app.error.origin=system folder.name=\(recording.folder.lastPathComponent, privacy: .public)"
      )
      return nil
    }
  }

  /// 外殻が取り込みが止まったと伝えたとき。止まった録音がまだ録音中のときだけ待機中へ戻す。
  /// 外殻は書いた分を閉じてから伝えるので、録音中だった会議フォルダーを `saved` へ渡す。
  /// 準備中なら覚えておき、開始が戻った直後に `start` が処理する。
  private func interrupt(_ meeting: URL, _ problem: RecordingProblem) {
    if state == .starting, startingMeeting == meeting {
      interruptedWhileStarting = problem
      return
    }
    guard case .recording(let recording) = state, recording.folder == meeting else { return }
    logger.error(
      "recording failed step=record error.type=\(problem.logName, privacy: .public) app.error.origin=system folder.name=\(meeting.lastPathComponent, privacy: .public)"
    )
    ProcessInfo.processInfo.endActivity(recording.activity)
    state = .idle
    report(problem)
    saved(meeting)
  }

  private func refuse(_ problem: RecordingProblem) {
    state = .idle
    report(problem)
  }

  /// `startTimeout` までに始まらなければ `StartTimeout` を投げる。遅れて始まった取り込みは止める。
  private func captureWithTimeout(
    _ file: URL, _ onInterrupt: @escaping @Sendable (RecordingProblem) -> Void
  ) async throws -> CaptureSession {
    let (first, continuation) = AsyncStream.makeStream(
      of: Result<CaptureSession, any Error>?.self)
    let startCapture = startCapture
    let capture = Task { () async -> Result<CaptureSession, any Error> in
      let result: Result<CaptureSession, any Error>
      do {
        result = .success(try await startCapture(file, onInterrupt))
      } catch {
        result = .failure(error)
      }
      continuation.yield(result)
      return result
    }
    let timeout = startTimeout
    let timer = Task {
      try await Task.sleep(for: timeout)
      continuation.yield(nil)
    }
    var outcome: Result<CaptureSession, any Error>?
    for await value in first {
      outcome = value
      break
    }
    timer.cancel()
    continuation.finish()
    guard let outcome else {
      Task {
        if case .success(let late) = await capture.value { _ = try? await late.stop() }
      }
      throw StartTimeout()
    }
    return try outcome.get()
  }
}

private struct StartTimeout: Error {}

extension Permission {
  var logName: String {
    switch self {
    case .microphone: "microphone"
    case .systemAudio: "system_audio"
    }
  }
}

extension RecordingTrigger {
  fileprivate var logName: String {
    switch self {
    case .manual: "manual"
    case .meeting: "meeting"
    }
  }
}

extension RecordingProblem {
  fileprivate var logName: String {
    switch self {
    case .missingPermissions: "permission_denied"
    case .folderMissing: "folder_missing"
    case .folderNotWritable: "folder_not_writable"
    case .captureFailed: "capture_failed"
    case .interrupted: "interrupted"
    case .writeFailed: "write_failed"
    case .saveFailed: "save_failed"
    case .discardFailed: "discard_failed"
    }
  }
}

// main.swift のトップレベルはテストバンドルで実行されないため、遅延初期化されるここに置く。
@MainActor let recorder = Recorder(
  folder: RecordingFolder(), missingPermissions: checkRecordingPermissions,
  startCapture: { file, onInterrupt in
    try await startSystemAudioCapture(
      file: file, microphone: MicrophoneSetting().choice, onInterrupt: onInterrupt)
  },
  report: MenuBar.present, saved: { transcriber.recordingSaved($0) })
