// 文字起こしのテストのフィクスチャ 2 つを、同梱の合成音声 Resources/SelfCheck/sample.wav から作る。
// 「無音 1 秒・音声・無音 3 秒・音声・無音 3 秒・音声・無音 1 秒」につなぎ、-quiet は 2 回目だけを -30 dB にする。
// 2 回目だけを別の合成音声(Reed)にした話者分離のフィクスチャも作る。誰の声でもなく再生成できる。
// リポジトリの直下で `swift scripts/make-transcription-fixtures.swift` を実行して作り直す。
import AVFoundation

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sample = root.appending(path: "Resources/SelfCheck/sample.wav")
let fixtures = root.appending(path: "Tests/Fixtures")

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("make-transcription-fixtures: \(message)\n".utf8))
  exit(1)
}

/// 16 bit・mono の WAVE の標本と標本化周波数。
func readVoice(_ url: URL) -> (samples: [Int16], rate: Double) {
  guard
    let input = try? AVAudioFile(
      forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
    input.processingFormat.channelCount == 1,
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)
  else { fail("16 bit・mono の WAVE として読めない: \(url.path)") }
  // read(into:) は 1 回で容量まで埋めるとは限らない(実測: 361,567 フレームの容量に 360,448 だけ入った)。
  var samples: [Int16] = []
  while input.framePosition < input.length {
    guard (try? input.read(into: buffer)) != nil, buffer.frameLength > 0 else {
      fail("読めない: \(url.path)")
    }
    samples += UnsafeBufferPointer(
      start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
  }
  return (samples, input.processingFormat.sampleRate)
}

func run(_ executable: String, _ arguments: [String]) {
  let process = Process()
  process.executableURL = URL(filePath: executable)
  process.arguments = arguments
  do {
    try process.run()
  } catch {
    fail("起動できない: \(executable)")
  }
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    fail("\(executable) が終了コード \(process.terminationStatus) で終わった")
  }
}

let (voice, rate) = readVoice(sample)
// make-selfcheck-sample.sh と同じ原稿・速さ・変換で、Kyoko の代わりに Reed の声を作る。
let temporary = FileManager.default.temporaryDirectory.appending(
  path: "make-transcription-fixtures-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let reedAIFF = temporary.appending(path: "reed.aiff")
let reedWAVE = temporary.appending(path: "reed.wav")
run(
  "/usr/bin/say",
  ["-v", "Reed", "-r", "150", "-f", root.appending(path: "Resources/SelfCheck/sample.txt").path,
   "-o", reedAIFF.path])
run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", reedAIFF.path, reedWAVE.path])
let reed = readVoice(reedWAVE)
guard reed.rate == rate else { fail("Reed の標本化周波数 \(reed.rate) が \(rate) と違う") }

func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * rate)) }

func write(_ samples: [Int16], to name: String) {
  let url = fixtures.appending(path: name)
  guard
    let file = try? AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      ],
      commonFormat: .pcmFormatInt16, interleaved: true),
    let out = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
  else { fail("WAVE を書けない: \(url.path)") }
  out.frameLength = AVAudioFrameCount(samples.count)
  samples.withUnsafeBufferPointer {
    out.int16ChannelData![0].update(from: $0.baseAddress!, count: $0.count)
  }
  guard (try? file.write(from: out)) != nil else { fail("WAVE を書けない: \(url.path)") }
  file.close()
  print(
    "make-transcription-fixtures: \(url.path) \(String(format: "%.2f", Double(samples.count) / rate)) s"
  )
}

let gain = pow(10, -30.0 / 20)
let quiet = voice.map { Int16((Double($0) * gain).rounded()) }
try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
write(
  silence(1) + voice + silence(3) + voice + silence(3) + voice + silence(1),
  to: "transcription-3x.wav")
write(
  silence(1) + voice + silence(3) + quiet + silence(3) + voice + silence(1),
  to: "transcription-3x-quiet.wav")
write(
  silence(1) + voice + silence(3) + reed.samples + silence(3) + voice + silence(1),
  to: "transcription-3x-two-voices.wav")
