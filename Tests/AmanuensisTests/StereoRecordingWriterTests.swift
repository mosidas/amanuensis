import AVFoundation
import Testing

@testable import Amanuensis

private let rate = 48_000.0
private let lowerBoundWhileRecording = AVAudioFramePosition((20 - 6.1) * rate)

private struct Recorded {
  let file: AVAudioFile
  let left: [Float]
  let right: [Float]

  init(_ url: URL) throws {
    file = try AVAudioFile(forReading: url)
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1))))
    try file.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    let count = Int(buffer.frameLength)
    left = Array(UnsafeBufferPointer(start: channels[0], count: count))
    right =
      file.processingFormat.channelCount > 1
      ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : []
  }
}

private func withTemporaryFile(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "StereoRecordingWriterTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory.appending(path: "recording.caf"))
}

private func constant(_ value: Float, sampleRate: Double = rate, channels: AVAudioChannelCount = 1)
  throws -> AVAudioPCMBuffer
{
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
      interleaved: false))
  let frames = AVAudioFrameCount(sampleRate / 100)
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
  buffer.frameLength = frames
  for channel in 0..<Int(channels) {
    buffer.floatChannelData![channel].update(repeating: value, count: Int(frames))
  }
  return buffer
}

private func feed(
  _ writer: StereoRecordingWriter, _ source: RecordingSource, _ buffer: AVAudioPCMBuffer,
  from start: Double = 0, seconds: Double
) throws {
  for step in Int(start * 100)..<Int((start + seconds) * 100) {
    try writer.append(buffer, from: source, at: Double(step) / 100)
  }
}

private func mean(_ samples: ArraySlice<Float>) -> Float {
  samples.reduce(0, +) / Float(samples.count)
}

@Test func writesMicrophoneLeftAndSystemAudioRight() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    let microphone = try constant(0.5)
    let systemAudio = try constant(-0.5)
    for step in 0..<300 {
      try writer.append(microphone, from: .microphone, at: Double(step) / 100)
      try writer.append(systemAudio, from: .systemAudio, at: Double(step) / 100)
    }
    let seconds = try writer.finish()

    let recorded = try Recorded(url)
    #expect(recorded.file.fileFormat.channelCount == 2)
    #expect(recorded.file.fileFormat.sampleRate == 48_000)
    #expect(abs(recorded.file.length - 144_000) <= 1)
    #expect(abs(seconds - 3) <= 1 / rate)
    #expect(abs(mean(recorded.left[...]) - 0.5) < 0.001, "左はマイク")
    #expect(abs(mean(recorded.right[...]) + 0.5) < 0.001, "右はシステム音声")
    let settings = recorded.file.fileFormat.settings
    #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
    #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
  }
}

@Test func convertsMicrophoneFormat() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    try feed(writer, .microphone, constant(0.5, sampleRate: 44_100, channels: 2), seconds: 3)
    _ = try writer.finish()

    let recorded = try Recorded(url)
    #expect(abs(recorded.file.length - 144_000) <= 100)
    #expect(
      abs(mean(recorded.left[Int(0.5 * rate)..<Int(2.5 * rate)]) - 0.5) < 0.01,
      "44.1 kHz・ステレオのマイクも左に同じ大きさで入る")
  }
}

@Test func fillsSilenceBeforeLateSource() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    let microphone = try constant(0.5)
    let systemAudio = try constant(-0.5)
    for step in 0..<300 {
      try writer.append(microphone, from: .microphone, at: Double(step) / 100)
      if step >= 200 {
        try writer.append(systemAudio, from: .systemAudio, at: Double(step) / 100)
      }
    }
    _ = try writer.finish()

    let recorded = try Recorded(url)
    let silence = recorded.right[..<Int(1.9 * rate)]
    let sound = recorded.right[Int(2.1 * rate)...]
    #expect(silence.allSatisfy { $0 == 0 }, "システム音声が届く前の右は無音")
    #expect(!sound.isEmpty)
    #expect(sound.allSatisfy { abs($0 + 0.5) < 0.001 }, "届いた後の右はシステム音声")
  }
}

@Test func writesWhileRecording() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    let microphone = try constant(0.5)
    let systemAudio = try constant(-0.5)
    var maxLag = 0.0
    for step in 0..<2000 {
      for (source, buffer) in [
        (RecordingSource.microphone, microphone), (.systemAudio, systemAudio),
      ] {
        try writer.append(buffer, from: source, at: Double(step) / 100)
        let fed = Double(step + 1) / 100
        let onDisk = Double(try AVAudioFile(forReading: url).length) / rate
        #expect(onDisk <= fed)
        maxLag = max(maxLag, fed - onDisk)
      }
    }
    #expect(maxLag <= 6.1, "強制終了で失う音声は渡したどの時点でも 6.1 秒以内")
  }
}

@Test func systemAudioSilentStillAdvances() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    try feed(writer, .microphone, constant(0.5), seconds: 20)

    try withExtendedLifetime(writer) {
      let recorded = try Recorded(url)
      #expect(recorded.file.length >= lowerBoundWhileRecording, "システム音声が無くても書き進む")
      #expect(recorded.right.allSatisfy { $0 == 0 }, "システム音声が無い右は無音")
    }
  }
}

@Test func alignsOverlapsAndGapsByTime() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    let tick = try constant(0.5)
    let longer = try #require(AVAudioPCMBuffer(pcmFormat: tick.format, frameCapacity: 9_600))
    longer.frameLength = 9_600
    longer.floatChannelData![0].update(repeating: 0.5, count: 9_600)
    try feed(writer, .microphone, tick, seconds: 1)
    try writer.append(longer, from: .microphone, at: 0.9)
    #expect(writer.droppedFrames == 4_800, "0.1 秒の重なりは捨てる")
    try writer.append(tick, from: .microphone, at: 1.1)
    try writer.append(tick, from: .microphone, at: 1.15)
    try writer.append(tick, from: .microphone, at: 1.28)
    _ = try writer.finish()

    let recorded = try Recorded(url)
    #expect(writer.droppedFrames == 4_800)
    #expect(recorded.file.length == AVAudioFramePosition(1.29 * rate), "重なりで位置がずれない")
    #expect(
      recorded.left[..<Int(1.12 * rate)].allSatisfy { abs($0 - 0.5) < 0.001 },
      "0.04 秒の隙間は続けて置く")
    #expect(
      recorded.left[Int(1.12 * rate)..<Int(1.28 * rate)].allSatisfy { $0 == 0 },
      "0.16 秒の隙間は無音で埋める")
    #expect(recorded.left[Int(1.28 * rate)...].allSatisfy { abs($0 - 0.5) < 0.001 })
  }
}

@Test func ignoresBuffersAfterFinish() throws {
  try withTemporaryFile { url in
    let writer = try StereoRecordingWriter(url: url)
    try feed(writer, .microphone, constant(0.5), seconds: 1)
    let seconds = try writer.finish()
    try writer.append(constant(0.5), from: .microphone, at: 1)

    #expect(writer.droppedFrames == 480, "閉じた後のバッファーは捨てて数える")
    #expect(try writer.finish() == seconds, "閉じた後の finish は同じ秒数を返す")
    #expect(try AVAudioFile(forReading: url).length == AVAudioFramePosition(rate))
  }
}
