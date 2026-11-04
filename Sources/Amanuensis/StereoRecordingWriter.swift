// AVFAudio は AVAudioPCMBuffer を Sendable と宣言しないが、変換器は入力の block を convert の中で同期して呼ぶ。
@preconcurrency import AVFoundation
import os

enum RecordingSource {
  case microphone, systemAudio

  /// 書き手のファイルでの音源の位置。左がマイク、右がシステム音声。
  fileprivate var channel: Int {
    switch self {
    case .microphone: 0
    case .systemAudio: 1
    }
  }
}

/// 2 つの音源を時刻で揃え、左にマイク・右にシステム音声を置いた 48 kHz・16 bit・2 ch の CAF に書く。
/// 書き出しは届いた音声の量で決まり、書き終えていない区間が 5 秒に達するたびに書く。
/// 呼び出し元は 1 つの直列の実行文脈からだけ呼ぶ。`finish()` の後に届いたバッファーは捨てて `droppedFrames` に数える。
final class StereoRecordingWriter {
  private static let rate = 48_000.0
  private static let monoFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
  // 5 秒: AC 7(強制終了で失うのは 1 分以内)を満たしつつ、kill -9 で失う音声を最大 6 秒にする。
  private static let flushThreshold = Int(5 * rate)
  // 1 秒: 遅れて届く音源を待つ幅。
  private static let lateSourceMargin = Int(1 * rate)
  // 0.05 秒: 時刻の揺れとして許し、隙間も重なりも作らずに続けて置く幅(クリック防止)。
  // shortcut: PTS の差で 0.05 秒ずつ寄せる, 長い会議でずれが聞こえたら音源ごとの時計の補正に引き上げる
  private static let jitterTolerance = Int(0.05 * rate)

  // shortcut: 非圧縮(約 691 MB/時), 保存先の容量が問題になったら後続で AAC に変換する
  // AVAudioFile は書いた音声をプロセス内に最大 4,096 フレーム(約 85 ms)抱える(実測)。強制終了ではその分も失う。
  private let file: AVAudioFile
  private var origin: TimeInterval?
  private var written = 0
  /// 音源ごとの、書き出し済みの位置 `written` より後の音声。添字は `RecordingSource.channel`。
  private var pending: [[Float]] = [[], []]
  private var converters: [AVAudioConverter?] = [nil, nil]
  private(set) var droppedFrames = 0

  init(url: URL) throws {
    file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Self.rate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false)
  }

  func append(_ buffer: AVAudioPCMBuffer, from source: RecordingSource, at time: TimeInterval)
    throws
  {
    guard file.isOpen else {
      droppedFrames += Int(buffer.frameLength)
      return
    }
    let samples = try monoSamples(buffer, from: source)
    let origin = self.origin ?? time
    self.origin = origin
    let position = Int(((time - origin) * Self.rate).rounded())
    let channel = source.channel
    let end = written + pending[channel].count
    if position > end + Self.jitterTolerance {
      pending[channel].append(contentsOf: repeatElement(0, count: position - end))
      pending[channel].append(contentsOf: samples)
    } else if position < end - Self.jitterTolerance {
      let overlap = min(end - position, samples.count)
      droppedFrames += overlap
      pending[channel].append(contentsOf: samples[overlap...])
    } else {
      pending[channel].append(contentsOf: samples)
    }

    let unwritten = max(pending[0].count, pending[1].count)
    if unwritten >= Self.flushThreshold {
      try write(frames: unwritten - Self.lateSourceMargin)
    }
  }

  /// 残りを両方の音源の末尾の大きい方まで書いて閉じ、書いた秒数を返す。閉じた後は書かずに同じ秒数を返す。
  func finish() throws -> TimeInterval {
    if file.isOpen {
      defer { file.close() }
      try write(frames: max(pending[0].count, pending[1].count))
    }
    return Double(written) / Self.rate
  }

  private func write(frames: Int) throws {
    guard frames > 0 else { return }
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in pending.indices {
      let destination = UnsafeMutableBufferPointer(
        start: buffer.floatChannelData![channel], count: frames)
      let copied = min(pending[channel].count, frames)
      _ = destination.update(fromContentsOf: pending[channel][..<copied])
      destination[copied...].update(repeating: 0)
    }
    try file.write(from: buffer)
    written += frames
    for channel in pending.indices {
      pending[channel].removeFirst(min(pending[channel].count, frames))
    }
  }

  private func monoSamples(_ buffer: AVAudioPCMBuffer, from source: RecordingSource) throws
    -> [Float]
  {
    let mono = buffer.format == Self.monoFormat ? buffer : try convert(buffer, from: source)
    return Array(
      UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
  }

  // マイクの形式は機種で変わるため、48 kHz・モノラル・Float32 以外は音源ごとの変換器で揃える。
  private func convert(_ buffer: AVAudioPCMBuffer, from source: RecordingSource) throws
    -> AVAudioPCMBuffer
  {
    let converter: AVAudioConverter
    if let current = converters[source.channel], current.inputFormat == buffer.format {
      converter = current
    } else {
      guard let created = AVAudioConverter(from: buffer.format, to: Self.monoFormat) else {
        throw NSError(
          domain: NSOSStatusErrorDomain, code: Int(kAudioConverterErr_FormatNotSupported))
      }
      created.downmix = true
      converters[source.channel] = created
      converter = created
    }
    let capacity =
      AVAudioFrameCount(
        (Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate).rounded(.up)) + 1
    let output = AVAudioPCMBuffer(pcmFormat: Self.monoFormat, frameCapacity: capacity)!
    let consumed = OSAllocatedUnfairLock(initialState: false)
    var error: NSError?
    _ = converter.convert(to: output, error: &error) { _, inputStatus in
      let first = consumed.withLock { consumed in
        defer { consumed = true }
        return !consumed
      }
      inputStatus.pointee = first ? .haveData : .noDataNow
      return first ? buffer : nil
    }
    if let error { throw error }
    return output
  }
}
