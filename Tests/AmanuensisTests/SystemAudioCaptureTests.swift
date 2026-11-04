import AVFoundation
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
  var description = AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: 9, mBytesPerPacket: 8,
    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
    mReserved: 0)
  let format = try #require(AVAudioFormat(streamDescription: &description))
  let frames: [Float] = (0..<960).map { $0.isMultiple(of: 2) ? 0.5 : -0.5 }
  let buffer = try #require(
    withBufferList([(2, bytes(frames))]) { pcmBuffer($0, format: format) })
  #expect(buffer.frameLength == 480)
  let copied = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
  let samples = UnsafeBufferPointer(
    start: copied.mData!.assumingMemoryBound(to: Float.self), count: 960)
  #expect(Array(samples) == frames)
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
