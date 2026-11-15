import AVFoundation
import CoreAudio
import OSLog
import Testing

@testable import Amanuensis

/// `buffers` の各要素を 1 本のバッファーにした AudioBufferList を作り、`body` に渡す。
private func withBufferList<Result>(
  _ buffers: [(channels: UInt32, bytes: [UInt8])],
  _ body: (UnsafePointer<AudioBufferList>) throws -> Result
) rethrows -> Result {
  let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
  defer {
    for buffer in list { buffer.mData?.deallocate() }
    free(list.unsafeMutablePointer)
  }
  for (index, buffer) in buffers.enumerated() {
    let data = UnsafeMutableRawPointer.allocate(
      byteCount: max(buffer.bytes.count, 1), alignment: 16)
    data.copyMemory(from: buffer.bytes, byteCount: buffer.bytes.count)
    list[index] = AudioBuffer(
      mNumberChannels: buffer.channels, mDataByteSize: UInt32(buffer.bytes.count), mData: data)
  }
  return try body(UnsafePointer(list.unsafePointer))
}

private func bytes(_ samples: [Float]) -> [UInt8] {
  samples.withUnsafeBytes { Array($0) }
}

private func monoFormat() throws -> AVAudioFormat {
  try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
}

/// HAL が渡す形の 48 kHz・Float32 の ASBD。
private func floatDescription(channels: UInt32, planar: Bool) -> AudioStreamBasicDescription {
  let bytesPerFrame: UInt32 = planar ? 4 : 4 * channels
  return AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: planar ? 9 | kAudioFormatFlagIsNonInterleaved : 9,
    mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

@Test func monoFloatBufferIsCopied() throws {
  let format = try monoFormat()
  let buffer = try #require(
    withBufferList([(1, bytes(Array(repeating: 0.25, count: 480)))]) {
      pcmBuffer($0, format: format)
    })
  #expect(buffer.frameLength == 480)
  let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 480)
  #expect(samples.allSatisfy { $0 == 0.25 })
}

@Test func interleavedStereoKeepsChannels() throws {
  let format = try #require(inputFormat(from: floatDescription(channels: 2, planar: false)))
  let frames: [Float] = (0..<960).map { $0.isMultiple(of: 2) ? 0.5 : -0.5 }
  let buffer = try #require(
    withBufferList([(2, bytes(frames))]) { pcmBuffer($0, format: format) })
  #expect(buffer.frameLength == 480)
  let copied = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
  let samples = UnsafeBufferPointer(
    start: copied.mData!.assumingMemoryBound(to: Float.self), count: 960)
  #expect(Array(samples) == frames)
}

@Test(arguments: [false, true]) func eightChannelFormatIsCreated(planar: Bool) throws {
  let format = try #require(inputFormat(from: floatDescription(channels: 8, planar: planar)))
  #expect(format.channelCount == 8)
  #expect(format.sampleRate == 48_000)
  #expect(format.isInterleaved == !planar)
}

@Test func threeChannelPacked24BitIsRejected() {
  let description = AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 9, mFramesPerPacket: 1, mBytesPerFrame: 9,
    mChannelsPerFrame: 3, mBitsPerChannel: 24, mReserved: 0)
  #expect(inputFormat(from: description) == nil)
}

@Test(arguments: [(UInt32(1), false), (UInt32(2), false), (UInt32(2), true)])
func upToTwoChannelsKeepPlainFormat(channels: UInt32, planar: Bool) throws {
  var description = floatDescription(channels: channels, planar: planar)
  let plain = try #require(AVAudioFormat(streamDescription: &description))
  #expect(inputFormat(from: description) == plain)
}

@Test(arguments: [false, true]) func firstOfEightChannelsIsWrittenLeft(planar: Bool) throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SystemAudioCaptureTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "recording.caf")
  let format = try #require(inputFormat(from: floatDescription(channels: 8, planar: planar)))
  let interleaved: [Float] = (0..<480 * 8).map { $0.isMultiple(of: 8) ? 0.5 : -0.5 }
  let channels: [[Float]] =
    [Array(repeating: 0.5, count: 480)]
    + Array(repeating: Array(repeating: -0.5, count: 480), count: 7)
  let buffers: [(channels: UInt32, bytes: [UInt8])] =
    planar ? channels.map { (1, bytes($0)) } : [(8, bytes(interleaved))] as [(UInt32, [UInt8])]
  let writer = try StereoRecordingWriter(url: url)
  for step in 0..<100 {
    let buffer = try #require(withBufferList(buffers) { pcmBuffer($0, format: format) })
    try writer.append(buffer, from: .microphone, at: Double(step) / 100)
  }
  #expect(try writer.finish() == 1)

  let file = try AVAudioFile(forReading: url)
  let read = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
  try file.read(into: read)
  let left = UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength))
  #expect(left.count == 48_000)
  #expect(left.allSatisfy { abs($0 - 0.5) < 0.001 }, "左チャンネルはマイクの先頭チャンネルだけ")
}

@Test func extraBuffersAreIgnored() throws {
  let format = try monoFormat()
  let buffer = try #require(
    withBufferList([
      (1, bytes(Array(repeating: 0.25, count: 480))),
      (1, bytes(Array(repeating: 0.75, count: 480))),
    ]) { pcmBuffer($0, format: format) })
  #expect(buffer.frameLength == 480)
  let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 480)
  #expect(samples.allSatisfy { $0 == 0.25 })
}

@Test func malformedBuffersAreRejected() throws {
  let mono = try monoFormat()
  let partialFrame = withBufferList([(1, Array(repeating: 0, count: 7))]) {
    pcmBuffer($0, format: mono)
  }
  #expect(partialFrame == nil, "1 フレームで割り切れない大きさは捨てる")

  let stereo = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
  let missingChannel = withBufferList([(1, bytes(Array(repeating: 0.25, count: 480)))]) {
    pcmBuffer($0, format: stereo)
  }
  #expect(missingChannel == nil, "チャンネルの数よりバッファーが少なければ捨てる")

  let unevenChannels = withBufferList([
    (1, bytes(Array(repeating: 0.25, count: 480))), (1, bytes(Array(repeating: 0.25, count: 240))),
  ]) { pcmBuffer($0, format: stereo) }
  #expect(unevenChannels == nil, "チャンネルごとのフレーム数が食い違えば捨てる")
}

@Test func copiedSystemAudioIsWrittenToRightChannel() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "SystemAudioCaptureTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "recording.caf")
  let format = try monoFormat()
  let writer = try StereoRecordingWriter(url: url)
  for step in 0..<100 {
    let buffer = try #require(
      withBufferList([(1, bytes(Array(repeating: 0.25, count: 480)))]) {
        pcmBuffer($0, format: format)
      })
    try writer.append(buffer, from: .systemAudio, at: Double(step) / 100)
  }
  #expect(try writer.finish() == 1)

  let file = try AVAudioFile(forReading: url)
  let read = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
  try file.read(into: read)
  let right = UnsafeBufferPointer(start: read.floatChannelData![1], count: Int(read.frameLength))
  #expect(right.count == 48_000)
  #expect(right.allSatisfy { abs($0 - 0.25) < 0.001 })
}

@Suite(.serialized) struct StopFailureLogTests {
  /// アプリの集約デバイスの接頭辞は付けない。
  private func makeAggregateDevice() throws -> AudioObjectID {
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "amanuensis-tests",
      kAudioAggregateDeviceUIDKey: "io.github.mosidas.amanuensis.tests." + UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: true,
    ]
    var device = AudioObjectID(kAudioObjectUnknown)
    try #require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr)
    return device
  }

  private func currentThread() -> UInt64 {
    var thread: UInt64 = 0
    pthread_threadid_np(nil, &thread)
    return thread
  }

  private let marks = Logger(subsystem: "io.github.mosidas.amanuensis.tests", category: "mark")

  private func mark() -> String {
    let mark = UUID().uuidString
    marks.notice("\(mark, privacy: .public)")
    return mark
  }

  /// `mark` より後に `thread` が出した capture のログ。並行する他のスイートのログを混ぜないためスレッドで絞る。
  // position(date:) は指定より前の項目も返し、項目の時刻は Date.now より 1 ms ほど前に出る(実測)ため、時刻でなく印で区切る。
  private func captureLogs(after mark: String, thread: UInt64) throws -> [OSLogEntryLog] {
    let entries = try OSLogStore(scope: .currentProcessIdentifier).getEntries(
      matching: NSPredicate(format: "subsystem BEGINSWITH %@", "io.github.mosidas.amanuensis")
    )
    .compactMap { $0 as? OSLogEntryLog }
    .filter { $0.threadIdentifier == thread }
    let marked = try #require(entries.lastIndex { $0.composedMessage == mark }, "印のログを読める")
    return entries[(marked + 1)...].filter {
      $0.subsystem == "io.github.mosidas.amanuensis" && $0.category == "capture"
    }
  }

  private func messages(_ entries: some Sequence<OSLogEntryLog>, at level: OSLogEntryLog.Level)
    -> [String]
  {
    entries.filter { $0.level == level }.map(\.composedMessage)
  }

  @Test func closingVanishedDeviceIsNotLoggedAsError() throws {
    let thread = currentThread()
    let device = try makeAggregateDevice()
    let queue = DispatchQueue(label: "io.github.mosidas.amanuensis.tests.stop-failure")
    var proc: AudioDeviceIOProcID?
    try #require(
      AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, _, _, _, _ in } == noErr)
    let ioProc = try #require(proc)
    var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in }
    try #require(AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr)
    try #require(AudioHardwareDestroyAggregateDevice(device) == noErr)
    func gone() -> Bool {
      var alive: UInt32 = 1
      return read(device, kAudioDevicePropertyDeviceIsAlive, into: &alive) != noErr || alive == 0
    }
    let deadline = Date.now + 2
    while !gone(), Date.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try #require(gone(), "集約デバイスを壊したら 2 秒以内に消える")

    let marked = mark()
    let removed = AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
    stopCheck(removed, "destroy", device: device)
    let stopped = AudioDeviceStop(device, ioProc)
    stopCheck(stopped, "stop_device", device: device)
    let destroyed = AudioDeviceDestroyIOProcID(device, ioProc)
    stopCheck(destroyed, "destroy", device: device)

    let entries = try captureLogs(after: marked, thread: thread)
    #expect(messages(entries, at: .error) == [], "消えたデバイスを閉じる失敗は error にしない")
    #expect(
      messages(entries, at: .notice) == [
        "capture lost device stop failed step=destroy error.type=\(removed)",
        "capture lost device stop failed step=stop_device error.type=\(stopped)",
        "capture lost device stop failed step=destroy error.type=\(destroyed)",
      ])
  }

  @Test func closingLiveDeviceFailureIsLoggedAsError() throws {
    let thread = currentThread()
    let device = try makeAggregateDevice()
    defer { _ = AudioHardwareDestroyAggregateDevice(device) }

    let marked = mark()
    stopCheck(kAudioHardwareIllegalOperationError, "stop_device", device: device)

    let entries = try captureLogs(after: marked, thread: thread)
    #expect(
      messages(entries, at: .error) == [
        "capture stop failed step=stop_device error.type=1852797029 app.error.origin=system"
      ])
    #expect(messages(entries, at: .notice) == [])
  }
}
