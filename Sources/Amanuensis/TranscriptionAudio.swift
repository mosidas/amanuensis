@preconcurrency import AVFoundation

/// 認識に渡す区間の WAVE と、その先頭の録音の先頭からの秒。
struct AudioChunk: Equatable {
  let file: URL
  let offset: TimeInterval
}

// 60 秒: 実測で speech は 90 秒までは文ごとの区間を保ち、120 秒から 1 区間に潰れ、20 分では Metal のメモリ不足で落ちた。
private let maxChunkSeconds = 60
// 40 秒: 切れ目を探す幅の始まり。区間の 40〜60 秒のうち最も静かな 0.1 秒の枠の中央で切る。
private let minChunkSeconds = 40

/// `audio` を全チャンネルの平均のモノラルにし、最長 60 秒の区間に分けて `directory` に
/// `chunk-0001.wav` からの連番で元の標本化周波数・16 bit の WAVE に書く。0 フレームの録音は区間 0 個。
/// 録音を読めなければ `.audioUnreadable`、区間を書けなければ `.saveFailed` を投げる。
func writeMonoChunks(of audio: URL, to directory: URL) throws(TranscriptionFailure) -> (
  chunks: [AudioChunk], duration: TimeInterval
) {
  // shortcut: 区間の WAVE を全部書いてから認識する(1 時間で約 345 MB の一時ファイル), 一時ファイルの容量が問題になったら区間ごとに認識へ渡す
  // 保存先の FIFO は AVAudioFile が書き手を待って戻らず、リンクは保存先の外を読む。
  guard RecordingFolder.isPlainFile(audio) else { throw .audioUnreadable }
  let input: AVAudioFile
  do {
    input = try AVAudioFile(forReading: audio)
  } catch {
    throw .audioUnreadable
  }
  let rate = input.processingFormat.sampleRate
  // 範囲外(NaN を含む)は細工したヘッダー。NaN は Int(rate) で、3 MHz は読み取りの NSException で異常終了する(実測)。
  guard (8_000...192_000).contains(rate) else { throw .audioUnreadable }
  let channels = Int(input.processingFormat.channelCount)
  let frame = Int(rate) / 10
  guard
    let buffer = AVAudioPCMBuffer(
      pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(rate))
  else { throw .audioUnreadable }
  let window = maxChunkSeconds * Int(rate)
  let searchStart = minChunkSeconds * Int(rate)

  var chunks: [AudioChunk] = []
  var written = 0
  var pending: [Float] = []

  func writeChunk(_ count: Int) throws(TranscriptionFailure) {
    let url = directory.appending(path: String(format: "chunk-%04d.wav", chunks.count + 1))
    do {
      try writeMonoWAVE(pending[..<count], rate: rate, to: url)
    } catch {
      throw .saveFailed
    }
    chunks.append(AudioChunk(file: url, offset: Double(written) / rate))
    written += count
    pending.removeFirst(count)
  }

  // read(into:) は 1 回で容量まで埋めるとは限らない(実測)。読めたフレーム数だけを使う。
  while input.framePosition < input.length {
    do {
      try input.read(into: buffer)
    } catch {
      throw .audioUnreadable
    }
    guard buffer.frameLength > 0, let data = buffer.floatChannelData else {
      throw .audioUnreadable
    }
    for i in 0..<Int(buffer.frameLength) {
      var sum: Float = 0
      for channel in 0..<channels { sum += data[channel][i] }
      pending.append(sum / Float(channels))
    }
    while pending.count > window {
      let quietest = stride(from: searchStart, through: window - frame, by: frame).min {
        energy(pending[$0..<$0 + frame]) < energy(pending[$1..<$1 + frame])
      }!
      try writeChunk(quietest + frame / 2)
    }
  }
  if !pending.isEmpty { try writeChunk(pending.count) }
  return (chunks, Double(written) / rate)
}

private func energy(_ samples: ArraySlice<Float>) -> Float {
  samples.reduce(0) { $0 + $1 * $1 }
}

/// `samples` を mono・16 bit の WAVE に書いて閉じる。speech が読む前に閉じておく。
private func writeMonoWAVE(_ samples: ArraySlice<Float>, rate: Double, to url: URL) throws {
  let file = try AVAudioFile(
    forWriting: url,
    settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ],
    commonFormat: .pcmFormatFloat32, interleaved: false)
  defer { file.close() }
  guard
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
  else { throw CocoaError(.fileWriteUnknown) }
  buffer.frameLength = AVAudioFrameCount(samples.count)
  samples.withUnsafeBufferPointer {
    buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
  }
  try file.write(from: buffer)
}
