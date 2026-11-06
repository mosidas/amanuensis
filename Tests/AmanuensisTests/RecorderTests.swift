import AVFoundation
import Foundation
import Testing

@testable import Amanuensis

/// 偽の取り込みの書き手。`CaptureSession.stop` から MainActor へ渡って閉じる。
@MainActor final class FakeWriter {
  let writer: StereoRecordingWriter

  init(url: URL) throws {
    writer = try StereoRecordingWriter(url: url)
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    buffer.floatChannelData![0].update(repeating: 0.25, count: 480)
    for step in 0..<100 {
      try writer.append(buffer, from: .microphone, at: Double(step) / 100)
      try writer.append(buffer, from: .systemAudio, at: Double(step) / 100)
    }
  }

  func finish() throws -> TimeInterval { try writer.finish() }
}

/// 偽の取り込みの開始のしかた。
private enum StartBehavior {
  case succeed, fail, failUnknown
  case succeedAfter(Duration)
  case waitForRelease
  case interruptBeforeReturn
  case stopFails
}

/// 一時ディレクトリの保存先、専用の UserDefaults の suite、偽の取り込み、報告と保存の記録。
@MainActor private final class Harness {
  let suiteName = "RecorderTests-\(UUID().uuidString)"
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "RecorderTests-\(UUID().uuidString)")
  var root: URL { directory.appending(path: "root", directoryHint: .isDirectory) }
  var missing: [Permission] = []
  var behavior = StartBehavior.succeed
  private(set) var reports: [RecordingProblem] = []
  private(set) var saved: [URL] = []
  private(set) var captureCalls = 0
  private(set) var stopCalls = 0
  private(set) var onInterrupt: (@Sendable (RecordingProblem) -> Void)?
  private var release: CheckedContinuation<Void, Never>?

  init() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func recorder(folderRoot: URL? = nil, startTimeout: Duration = .seconds(10)) throws -> Recorder {
    let folder = RecordingFolder(
      defaults: try #require(UserDefaults(suiteName: suiteName)),
      standardRoot: directory.appending(path: "standard"))
    folder.setRoot(folderRoot ?? root)
    return Recorder(
      folder: folder, missingPermissions: { [missing] in missing },
      startCapture: { [unowned self] in try await startCapture(file: $0, onInterrupt: $1) },
      report: { [unowned self] in reports.append($0) },
      saved: { [unowned self] in saved.append($0) }, startTimeout: startTimeout)
  }

  func releaseStart() {
    release?.resume()
    release = nil
  }

  func meetingFolders() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
  }

  func remove() {
    UserDefaults().removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  private func startCapture(
    file: URL, onInterrupt: @escaping @Sendable (RecordingProblem) -> Void
  ) async throws -> CaptureSession {
    captureCalls += 1
    self.onInterrupt = onInterrupt
    let writer = try FakeWriter(url: file)
    switch behavior {
    case .succeed: break
    case .fail: throw RecordingProblem.captureFailed(.noInputDevice)
    case .failUnknown: throw CocoaError(.fileWriteUnknown)
    case .succeedAfter(let delay): try await Task.sleep(for: delay)
    case .waitForRelease: await withCheckedContinuation { release = $0 }
    case .interruptBeforeReturn: onInterrupt(.interrupted)
    case .stopFails: break
    }
    let stopFails = if case .stopFails = behavior { true } else { false }
    return CaptureSession(stop: { [unowned self] in
      await countStop()
      let duration = try await writer.finish()
      if stopFails { throw RecordingProblem.saveFailed }
      return duration
    })
  }

  private func countStop() { stopCalls += 1 }
}

/// `pmset -g assertions` のうち、このプロセスが録音のために出したスリープ抑止の行。
private func recordingAssertions() throws -> [String] {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/pmset")
  process.arguments = ["-g", "assertions"]
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter {
    $0.contains("pid \(getpid())(") && $0.contains("amanuensis is recording")
  }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<300 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

@Suite(.serialized) @MainActor struct RecorderTests {
  @Test func refusesWhenPermissionIsMissing() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.missing = [.microphone]
    let recorder = try harness.recorder()

    await recorder.start()

    #expect(harness.reports == [.missingPermissions([.microphone])])
    #expect(harness.captureCalls == 0, "権限が足りなければ取り込みを始めない")
    #expect(try harness.meetingFolders().isEmpty, "会議フォルダーを作らない")
    #expect(recorder.state == .idle)
  }

  @Test func startsCaptureWhenPermissionsAreGranted() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder()

    await recorder.start()
    await recorder.stop()

    #expect(harness.captureCalls == 1)
    #expect(harness.reports.isEmpty)
  }

  @Test func refusesWhenFolderIsMissing() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder(folderRoot: harness.directory.appending(path: "missing"))

    await recorder.start()

    #expect(harness.reports == [.folderMissing])
    #expect(harness.captureCalls == 0)
    #expect(recorder.state == .idle)
  }

  @Test func startAndStopKeepsStereoFileAndReleasesSleepAssertion() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder()

    await recorder.start()

    guard case .recording(let recording) = recorder.state else {
      Issue.record("録音中になる: \(recorder.state)")
      return
    }
    let file = recording.folder.appending(path: "recording.caf")
    #expect(exists(file))
    #expect(try recordingAssertions().count == 1, "録音中はスリープを抑止する")

    await recorder.stop()

    #expect(recorder.state == .idle)
    #expect(harness.stopCalls == 1)
    #expect(try recordingAssertions().isEmpty, "停止したらスリープの抑止を解く")
    let audio = try AVAudioFile(forReading: file)
    #expect(audio.fileFormat.channelCount == 2)
    #expect(audio.length > 0)
    #expect(harness.reports.isEmpty)
    #expect(harness.saved == [recording.folder], "保存した会議フォルダーを 1 回知らせる")
  }

  @Test func discardRemovesMeetingFolder() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder()
    await recorder.start()
    guard case .recording(let recording) = recorder.state else {
      Issue.record("録音中になる: \(recorder.state)")
      return
    }

    await recorder.discard()

    #expect(!exists(recording.folder))
    #expect(harness.stopCalls == 1, "破棄の前に取り込みを止める")
    #expect(try recordingAssertions().isEmpty)
    #expect(recorder.state == .idle)
    #expect(harness.reports.isEmpty)
    #expect(harness.saved.isEmpty, "破棄した録音は知らせない")
  }

  @Test func captureFailureRemovesMeetingFolder() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .fail
    let recorder = try harness.recorder()

    await recorder.start()

    #expect(harness.reports == [.captureFailed(.noInputDevice)])
    #expect(try harness.meetingFolders().isEmpty)
    #expect(try recordingAssertions().isEmpty)
    #expect(recorder.state == .idle)
  }

  @Test func captureErrorWithoutKindReportsStartFailed() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .failUnknown
    let recorder = try harness.recorder()

    await recorder.start()

    #expect(harness.reports == [.captureFailed(.failed(step: "start", type: "capture_failed"))])
    #expect(try harness.meetingFolders().isEmpty)
    #expect(recorder.state == .idle)
  }

  @Test func captureTimeoutFailsAndStopsLateSession() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .succeedAfter(.milliseconds(600))
    let recorder = try harness.recorder(startTimeout: .milliseconds(200))

    await recorder.start()

    #expect(harness.reports == [.captureFailed(.failed(step: "start", type: "timeout"))])
    #expect(try harness.meetingFolders().isEmpty)
    #expect(try recordingAssertions().isEmpty)
    #expect(recorder.state == .idle)
    try await waitUntil { harness.stopCalls == 1 }
    #expect(harness.stopCalls == 1, "遅れて始まった取り込みを止める")
    #expect(harness.reports == [.captureFailed(.failed(step: "start", type: "timeout"))])
  }

  @Test func interruptionKeepsFileAndReturnsToIdle() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder()
    await recorder.start()
    guard case .recording(let recording) = recorder.state else {
      Issue.record("録音中になる: \(recorder.state)")
      return
    }

    harness.onInterrupt?(.interrupted)
    try await waitUntil { recorder.state == .idle }

    #expect(recorder.state == .idle)
    #expect(harness.reports == [.interrupted])
    #expect(exists(recording.folder.appending(path: "recording.caf")), "途中までの音声を残す")
    #expect(try recordingAssertions().isEmpty)
    #expect(harness.saved == [recording.folder], "途中で止まった録音も知らせる")
  }

  @Test func startWhileStartingDoesNothing() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .waitForRelease
    let recorder = try harness.recorder()
    let first = Task { await recorder.start() }
    try await waitUntil { harness.captureCalls == 1 }
    #expect(recorder.state == .starting)

    await recorder.start()

    #expect(harness.captureCalls == 1, "準備中の開始は取り込みを増やさない")
    harness.releaseStart()
    await first.value
    if case .recording = recorder.state {} else { Issue.record("録音中になる: \(recorder.state)") }
    await recorder.stop()
    #expect(harness.reports.isEmpty)
  }

  @Test func interruptionWhileStartingReturnsToIdleAndKeepsFile() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .interruptBeforeReturn
    let recorder = try harness.recorder()

    await recorder.start()
    try await waitUntil { !harness.reports.isEmpty }

    #expect(harness.reports == [.interrupted])
    #expect(recorder.state == .idle, "止まった取り込みで録音中にならない")
    #expect(try recordingAssertions().isEmpty)
    let folders = try harness.meetingFolders()
    #expect(folders.count == 1)
    #expect(folders.allSatisfy { exists($0.appending(path: "recording.caf")) }, "途中までの音声を残す")
  }

  @Test func stopFailureReportsSaveFailedAndReturnsToIdle() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    harness.behavior = .stopFails
    let recorder = try harness.recorder()
    await recorder.start()

    await recorder.stop()

    #expect(harness.reports == [.saveFailed])
    #expect(recorder.state == .idle)
    #expect(try recordingAssertions().isEmpty)
    #expect(harness.saved.isEmpty, "保存できなかった録音は知らせない")
  }

  @Test func discardFailureReportsDiscardFailedAndReturnsToIdle() async throws {
    let harness = try Harness()
    defer { harness.remove() }
    let recorder = try harness.recorder()
    await recorder.start()
    guard case .recording(let recording) = recorder.state else {
      Issue.record("録音中になる: \(recorder.state)")
      return
    }
    let locked = recording.folder.appending(path: "locked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try Data().write(to: locked.appending(path: "file"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    await recorder.discard()

    #expect(harness.reports == [.discardFailed])
    #expect(recorder.state == .idle)
    #expect(try recordingAssertions().isEmpty)
  }
}
