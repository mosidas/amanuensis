@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

private let logger = Logger(subsystem: "io.github.mosidas.amanuensis", category: "capture")

/// 録音に足りない権限を `Permission.allCases` の順で返す。値は保存せず、呼ぶたびに今の状態から判定する。
/// マイクが未確認なら確認を出して答えを待つ。画面収録が無ければシステムの確認を 1 回求め、不足として返す。
func checkRecordingPermissions() async -> [Permission] {
  var missing: [Permission] = []
  switch AVCaptureDevice.authorizationStatus(for: .audio) {
  case .authorized: break
  case .notDetermined:
    if await !AVCaptureDevice.requestAccess(for: .audio) { missing.append(.microphone) }
  default: missing.append(.microphone)
  }
  // 画面収録の許可はプロセスを開き直すまで反映されないため、ここで求めても今回は不足として返す。
  if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    missing.append(.screenAndSystemAudio)
  }
  return missing
}

/// マイクとシステム音声を 1 本の `SCStream` で取り込み、`file` へ書く。
@MainActor func startSystemAudioCapture(
  file: URL, onInterrupt: @escaping @Sendable (RecordingProblem) -> Void
) async throws -> CaptureSession {
  let writer = try StereoRecordingWriter(url: file)
  let content = try await SCShareableContent.current
  guard let display = content.displays.first else { throw RecordingProblem.captureFailed }
  let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
  let configuration = SCStreamConfiguration()
  configuration.capturesAudio = true
  configuration.sampleRate = 48_000
  configuration.channelCount = 1
  configuration.excludesCurrentProcessAudio = true
  configuration.captureMicrophone = true
  // 映像は使わない。ScreenCaptureKit は映像を止められないため、最小の大きさと頻度にする。
  configuration.width = 2
  configuration.height = 2
  configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

  let output = CaptureOutput(writer: writer, onInterrupt: onInterrupt)
  let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
  try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
  try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
  try await stream.startCapture()
  return CaptureSession { @MainActor in
    try await stream.stopCapture()
    return try await output.finish()
  }
}

/// 取り込んだ音声を writer へ渡し、取り込みが止まったら 1 回だけ `onInterrupt` を呼ぶ。
/// `writer`・`invalidBuffers`・`ended`・`loggedStart` は `queue`(sampleHandlerQueue)の上でだけ触る。
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "io.github.mosidas.amanuensis.capture")
  private let writer: StereoRecordingWriter
  private let onInterrupt: @Sendable (RecordingProblem) -> Void
  private var invalidBuffers = 0
  private var ended = false
  private var loggedStart = false

  init(writer: StereoRecordingWriter, onInterrupt: @escaping @Sendable (RecordingProblem) -> Void) {
    self.writer = writer
    self.onInterrupt = onInterrupt
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    let source: RecordingSource
    switch type {
    case .audio: source = .systemAudio
    case .microphone: source = .microphone
    default: return
    }
    let time = sampleBuffer.presentationTimeStamp
    guard time.isNumeric, let buffer = Self.pcmBuffer(sampleBuffer) else {
      invalidBuffers += 1
      return
    }
    if source == .microphone, !loggedStart {
      loggedStart = true
      logger.info(
        "capture started microphone=\(Int(buffer.format.sampleRate), privacy: .public)/\(buffer.format.channelCount, privacy: .public)"
      )
    }
    do {
      try writer.append(buffer, from: source, at: time.seconds)
    } catch {
      guard !ended else { return }
      logger.error("capture failed step=write error.type=file_system app.error.origin=system")
      end(.writeFailed)
      stream.stopCapture { _ in }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    let code = (error as NSError).code
    queue.async { [self] in
      guard !ended else { return }
      logger.error(
        "capture interrupted error.type=\(code, privacy: .public) app.error.origin=system")
      end(.interrupted)
    }
  }

  /// writer を閉じて秒数を返す。
  func finish() async throws -> TimeInterval {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        let result = Result { try writer.finish() }
        logger.info(
          "capture stopped duration_s=\((try? result.get()) ?? 0, format: .fixed(precision: 1), privacy: .public) dropped_frames=\(self.writer.droppedFrames, privacy: .public) invalid_buffers=\(self.invalidBuffers, privacy: .public)"
        )
        continuation.resume(with: result)
      }
    }
  }

  private func end(_ problem: RecordingProblem) {
    ended = true
    _ = try? writer.finish()
    onInterrupt(problem)
  }

  /// 取り込みの音声を、形式を保ったまま `AVAudioPCMBuffer` へ写す。写せなければ nil を返す。
  private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      let format = AVAudioFormat(streamDescription: streamDescription),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples))
    else { return nil }
    buffer.frameLength = buffer.frameCapacity
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples),
      into: buffer.mutableAudioBufferList)
    return status == noErr ? buffer : nil
  }
}
