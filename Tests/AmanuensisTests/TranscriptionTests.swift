import AVFoundation
import Foundation
import Testing

@testable import Amanuensis

private func token(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> RecognizedToken {
  RecognizedToken(start: start, end: end, text: text)
}

@Test func paragraphsSplitAtGapsOfOnePointFiveSecondsOrMore() {
  let tokens = [
    token(1.0, 1.5, "これは"), token(1.82, 2.0, "一つ目"),  // 間隔 0.32 秒
    token(3.49, 4.0, "です"),  // 間隔 1.49 秒
    token(5.5, 6.0, "二つ目"),  // 間隔 1.5 秒
    token(9.12, 9.5, "三つ目"), token(9.5, 9.8, "です"),  // 間隔 3.12 秒
  ]
  #expect(
    paragraphs(tokens) == [
      TranscriptParagraph(start: 1.0, text: "これは一つ目です"),
      TranscriptParagraph(start: 5.5, text: "二つ目"),
      TranscriptParagraph(start: 9.12, text: "三つ目です"),
    ])
  #expect(paragraphs([]) == [])
}

private let chunks = [
  AudioChunk(file: URL(filePath: "/tmp/t/chunk-0001.wav"), offset: 0),
  AudioChunk(file: URL(filePath: "/tmp/t/chunk-0002.wav"), offset: 50.05),
]

@Test func recognizedTokensAddChunkOffsetAndDropEmptyText() throws {
  let stdout = Data(
    """
    {"file":"/tmp/t/chunk-0001.wav","text":"あ","tokens":[{"start":0,"end":0.24,"text":""},{"start":0.88,"end":1.2,"text":"あ"}]}
    {"file":"/tmp/t/chunk-0002.wav","text":"い","tokens":[{"start":1.5,"end":2.0,"text":"い"}]}

    """.utf8)
  #expect(
    try recognizedTokens(stdout, chunks: chunks) == [
      token(0.88, 1.2, "あ"), token(51.55, 52.05, "い"),
    ])
}

@Test func firstWordOfChunkStartingInSilenceTakesTimeOfNextWord() throws {
  let stdout = Data(
    """
    {"file":"/tmp/t/chunk-0001.wav","text":"あ","tokens":[{"start":0,"end":0.24,"text":""},{"start":49.7,"end":50.0,"text":"あ"}]}
    {"file":"/tmp/t/chunk-0002.wav","text":"これはア","tokens":[{"start":0,"end":0.32,"text":"これは"},{"start":3.6,"end":3.76,"text":"ア"}]}

    """.utf8)
  let tokens = try recognizedTokens(stdout, chunks: chunks)
  #expect(
    tokens == [
      token(49.7, 50.0, "あ"), token(50.05 + 3.6, 50.05 + 3.6, "これは"),
      token(50.05 + 3.6, 50.05 + 3.76, "ア"),
    ])
  #expect(
    paragraphs(tokens) == [
      TranscriptParagraph(start: 49.7, text: "あ"),
      TranscriptParagraph(start: 50.05 + 3.6, text: "これはア"),
    ], "区間の頭の語は前の区間の段落に付かない")
}

private let secondChunkLine = #"{"file":"/tmp/t/chunk-0002.wav","tokens":[]}"#

@Test(
  arguments: [
    #"{"file":"/tmp/t/other.wav","tokens":[]}"#,
    #"{"file":"/tmp/t/chunk-0001.wav"}"#,
    "not json",
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[{"start":1e300,"end":1e300,"text":"あ"}]}"#,
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[{"start":-5,"end":0.2,"text":"あ"}]}"#,
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[{"start":2.0,"end":1.0,"text":"あ"}]}"#,
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[{"start":0,"end":0.2,"text":""},{"start":1e300,"end":1e300,"text":"あ"}]}"#,
  ].map { $0 + "\n" + secondChunkLine } + [
    "",
    secondChunkLine,
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[]}"# + "\n" + secondChunkLine + "\n"
      + secondChunkLine,
  ])
func recognizedTokensRejectUnexpectedOutput(line: String) {
  #expect(throws: (any Error).self) { try recognizedTokens(Data(line.utf8), chunks: chunks) }
}

@Test func controlCharactersInWordsDoNotAddParagraphsOrLines() throws {
  let stdout = Data(
    #"{"file":"/tmp/t/chunk-0001.wav","tokens":[{"start":1,"end":1.2,"text":"前\n\n[00:00:00] 偽の段落\r\u001b[31m赤\u2028後\u2029終"}]}"#
      .utf8)
  let transcript = Transcript(
    meetingName: "2026-11-06_100000", duration: 2, model: "m",
    paragraphs: paragraphs(try recognizedTokens(stdout, chunks: [chunks[0]])))
  #expect(
    transcript.markdown.split(separator: "\n").filter { $0.hasPrefix("[") } == [
      "[00:00:01] 前[00:00:00] 偽の段落[31m赤後終"
    ])
}

private func temporaryDirectory(_ name: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "TranscriptionTests-\(UUID().uuidString)/\(name)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// 左を 0、右を `right(秒)` にした 16 kHz・16 bit・2 ch の CAF を `seconds` 秒ぶん書く。
private func writeStereoCAF(
  to url: URL, seconds: Double, right: (Double) -> Float
) throws {
  let rate = 16_000.0
  let file = try AVAudioFile(
    forWriting: url,
    settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ],
    commonFormat: .pcmFormatFloat32, interleaved: false)
  let total = Int(seconds * rate)
  let block = Int(rate)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)))
  var position = 0
  while position < total {
    let count = min(block, total - position)
    buffer.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
      buffer.floatChannelData![0][i] = 0
      buffer.floatChannelData![1][i] = right(Double(position + i) / rate)
    }
    try file.write(from: buffer)
    position += count
  }
  file.close()
}

private func sine(_ t: Double) -> Float { Float(0.5 * sin(2 * .pi * 440 * t)) }

private func samples(of url: URL) throws -> (values: [Float], rate: Double, channels: Int) {
  let file = try AVAudioFile(forReading: url)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
  var values: [Float] = []
  while file.framePosition < file.length {
    try file.read(into: buffer)
    values += UnsafeBufferPointer(
      start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
  }
  return (
    values, file.fileFormat.sampleRate, Int(file.fileFormat.channelCount)
  )
}

@Test func monoChunksCutInSilenceAndAverageChannels() throws {
  let directory = try temporaryDirectory("chunks")
  let audio = directory.appending(path: "recording.caf")
  let silent = [44.5...45.5, 99.5...100.5]
  try writeStereoCAF(to: audio, seconds: 130) { t in
    silent.contains { $0.contains(t) } ? 0 : sine(t)
  }

  let (chunks, duration) = try writeMonoChunks(of: audio, to: directory)

  #expect(abs(duration - 130) < 0.001)
  #expect(chunks.count == 3)
  var expectedOffset = 0.0
  for (index, chunk) in chunks.enumerated() {
    #expect(chunk.file.lastPathComponent == String(format: "chunk-%04d.wav", index + 1))
    #expect(abs(chunk.offset - expectedOffset) < 0.001, "区間の先頭は前の区間の終わり")
    let (values, rate, channels) = try samples(of: chunk.file)
    #expect(rate == 16_000)
    #expect(channels == 1)
    #expect(Double(values.count) / rate <= 60, "区間は 60 秒以下")
    let peak = values.map(abs).max() ?? 0
    #expect(abs(peak - 0.25) < 0.001, "左右の平均で右の振幅 0.5 の半分")
    expectedOffset += Double(values.count) / rate
  }
  #expect(abs(expectedOffset - duration) < 0.001, "区間の長さの和が録音の長さ")
  for (chunk, range) in zip(chunks.dropFirst(), silent) {
    #expect(range.contains(chunk.offset), "切れ目 \(chunk.offset) が無音の中")
  }
}

@Test func emptyRecordingHasNoChunks() throws {
  let directory = try temporaryDirectory("empty")
  let audio = directory.appending(path: "recording.caf")
  try writeStereoCAF(to: audio, seconds: 0) { _ in 0 }

  let (chunks, duration) = try writeMonoChunks(of: audio, to: directory)

  #expect(chunks.isEmpty)
  #expect(duration == 0)
}

/// `rate` Hz・16 bit・mono の CAF に無音を 400 フレーム書く。
private func writeSilentCAF(rate: Double, to url: URL) throws {
  var format = AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
    mBitsPerChannel: 16, mReserved: 0)
  var file: AudioFileID?
  try #require(
    AudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, .eraseFile, &file) == noErr)
  let handle = try #require(file)
  defer { AudioFileClose(handle) }
  let frames = [Int16](repeating: 0, count: 400)
  var bytes = UInt32(frames.count * 2)
  try frames.withUnsafeBytes { raw in
    try #require(AudioFileWriteBytes(handle, false, 0, &bytes, raw.baseAddress!) == noErr)
  }
}

// 5 Hz は 10 Hz 未満で 0.1 秒の枠が 0 フレームになる。3 MHz は AVAudioFile が開けるが読むと NSException で異常終了する(点検の実測)。
@Test(arguments: [5.0, 3_000_000])
func sampleRateOutsideSpeechRangeIsAudioUnreadable(rate: Double) throws {
  let directory = try temporaryDirectory("rate-\(Int(rate))")
  let audio = directory.appending(path: "recording.caf")
  try writeSilentCAF(rate: rate, to: audio)

  #expect(throws: TranscriptionFailure.audioUnreadable) {
    try writeMonoChunks(of: audio, to: directory)
  }
}

/// `body` を別のスレッドで動かし、`seconds` 秒以内に戻ればその値、戻らなければ nil。
/// 戻らない実装でテストが止まらないようにする。
/// 協調スレッドがセマフォ待ちで塞がっても動き出すように、GCD のプールでなく専用のスレッドで動かす。
func returnsWithin<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
  let done = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: T?
  Thread.detachNewThread {
    result = body()
    done.signal()
  }
  return done.wait(timeout: .now() + seconds) == .success ? result : nil
}

@Test(arguments: ["fifo", "link"])
func recordingThatIsNotPlainFileIsAudioUnreadableWithoutWaiting(kind: String) throws {
  let directory = try temporaryDirectory("2026-11-06_101500")
  let audio = directory.appending(path: "recording.caf")
  if kind == "fifo" {
    try #require(mkfifo(audio.path, 0o644) == 0)
  } else {
    let elsewhere = try temporaryDirectory("elsewhere").appending(path: "recording.caf")
    try writeSilentCAF(rate: 16_000, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: elsewhere)
  }

  let result = returnsWithin(seconds: 5) { () -> Result<Int, TranscriptionFailure> in
    do throws(TranscriptionFailure) {
      return .success(try writeMonoChunks(of: audio, to: directory).chunks.count)
    } catch {
      return .failure(error)
    }
  }

  #expect(result == .failure(.audioUnreadable), "5 秒以内に .audioUnreadable で戻る")
}

/// `.wav` の引数ごとに、区間の 1 秒と 4 秒から始まる語 2 つ(間隔 2.5 秒で別の段落)を出す。
private let twoWordsPerChunk = #"""
  for a in "$@"; do
    case "$a" in *.wav)
      printf '{"file":"%s","text":"","tokens":[{"start":0,"end":0.24,"text":""},{"start":1.0,"end":1.5,"text":"こんにちは"},{"start":4.0,"end":4.5,"text":"さようなら"}]}\n' "$a";;
    esac
  done
  """#

/// `2026-11-06_101500/recording.caf` に 70 秒の録音(50 秒の付近だけ無音)を書いた会議フォルダー。
private func meetingFolder() throws -> URL {
  let meeting = try temporaryDirectory("2026-11-06_101500")
  try writeStereoCAF(to: meeting.appending(path: "recording.caf"), seconds: 70) { t in
    (50.0...50.2).contains(t) ? 0 : sine(t)
  }
  return meeting
}

private func arguments(_ installation: SpeechInstallation) throws -> [String] {
  try String(contentsOf: installation.runtimeDirectory.appending(path: "args"), encoding: .utf8)
    .split(separator: "\n").map(String.init)
}

@Test func transcribeWritesTranscriptWithHeaderAndOffsetTimes() async throws {
  let meeting = try meetingFolder()
  let recording = try Data(contentsOf: meeting.appending(path: "recording.caf"))
  let installation = try fakeInstallation(twoWordsPerChunk)

  try await transcribe(meeting: meeting, installation: installation)

  let transcript = try String(
    contentsOf: meeting.appending(path: "transcript.md"), encoding: .utf8)
  #expect(
    transcript == """
      # 会議の文字起こし

      - 日時: 2026-11-06 10:15:00
      - 録音の長さ: 00:01:10
      - モデル: Haas-616M-ja-v1.0-Q8_0.gguf

      [00:00:01] こんにちは

      [00:00:04] さようなら

      [00:00:51] こんにちは

      [00:00:54] さようなら

      """)
  let args = try arguments(installation)
  #expect(
    Array(args.prefix(5)) == [
      "asr", installation.modelFile.path, "--timestamps", "--format", "json",
    ])
  let chunkPaths = args.dropFirst(5)
  #expect(chunkPaths.count == 2)
  #expect(chunkPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "一時の区間を消す")
  #expect(
    try Data(contentsOf: meeting.appending(path: "recording.caf")) == recording, "録音は変えない")
}

@Test func transcribeOfSilentSpeechSaysNoUtterance() async throws {
  let meeting = try meetingFolder()
  let installation = try fakeInstallation(
    #"for a in "$@"; do case "$a" in *.wav) printf '{"file":"%s","tokens":[]}\n' "$a";; esac; done"#
  )

  try await transcribe(meeting: meeting, installation: installation)

  let transcript = try String(
    contentsOf: meeting.appending(path: "transcript.md"), encoding: .utf8)
  #expect(transcript.hasSuffix("- モデル: Haas-616M-ja-v1.0-Q8_0.gguf\n\n発話はありませんでした。\n"))
}

private func transcriptionFailure(
  meeting: URL, installation: SpeechInstallation
) async -> TranscriptionFailure? {
  do {
    try await transcribe(meeting: meeting, installation: installation)
    return nil
  } catch {
    return error
  }
}

private func log(of meeting: URL) throws -> String {
  try String(contentsOf: meeting.appending(path: "transcription.log"), encoding: .utf8)
}

@Test func speechExitFailureIsLoggedAndKeepsRecording() async throws {
  let meeting = try meetingFolder()
  let recording = try Data(contentsOf: meeting.appending(path: "recording.caf"))
  let installation = try fakeInstallation("echo broken >&2; exit 3")

  #expect(
    await transcriptionFailure(meeting: meeting, installation: installation) == .recognitionFailed)

  #expect(try Data(contentsOf: meeting.appending(path: "recording.caf")) == recording)
  #expect(!FileManager.default.fileExists(atPath: meeting.appending(path: "transcript.md").path))
  let lines = try log(of: meeting).split(separator: "\n")
  #expect(lines.count == 1)
  #expect(
    lines.first?.hasSuffix(" transcription failed error.type=exited status=3 stderr=broken\\n")
      == true)
  let chunkPaths = try arguments(installation).dropFirst(5)
  #expect(!chunkPaths.isEmpty)
  #expect(chunkPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "失敗でも一時の区間を消す")
}

@Test func speechStderrInLogHasNoHomePath() async throws {
  let meeting = try meetingFolder()
  let installation = try fakeInstallation(#"echo "$HOME/x" >&2; exit 1"#)

  #expect(
    await transcriptionFailure(meeting: meeting, installation: installation) == .recognitionFailed)

  let contents = try log(of: meeting)
  #expect(contents.contains("stderr=~/x"))
  #expect(!contents.contains(NSHomeDirectory()), "ホームのパスを出さない")
}

@Test func nonJSONOutputIsRecognitionFailure() async throws {
  let meeting = try meetingFolder()
  let installation = try fakeInstallation("echo 'not json'")

  #expect(
    await transcriptionFailure(meeting: meeting, installation: installation) == .recognitionFailed)

  #expect(try log(of: meeting).contains(" transcription failed error.type=unparsable_output"))
  #expect(!FileManager.default.fileExists(atPath: meeting.appending(path: "transcript.md").path))
}

@Test func missingRecordingIsAudioUnreadable() async throws {
  let meeting = try temporaryDirectory("2026-11-06_101500")
  let installation = try fakeInstallation(twoWordsPerChunk)

  #expect(
    await transcriptionFailure(meeting: meeting, installation: installation) == .audioUnreadable)
  #expect(!FileManager.default.fileExists(atPath: meeting.appending(path: "transcript.md").path))
}

@Test func unwritableMeetingFolderIsSaveFailed() async throws {
  let meeting = try meetingFolder()
  let installation = try fakeInstallation(twoWordsPerChunk)
  try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: meeting.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
    try? FileManager.default.removeItem(at: meeting)
  }

  #expect(await transcriptionFailure(meeting: meeting, installation: installation) == .saveFailed)
  #expect(!FileManager.default.fileExists(atPath: meeting.appending(path: "transcript.md").path))
}

private let fixtures = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
private let sampleText = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "Resources/SelfCheck/sample.txt")

/// フィクスチャを右チャンネル(左は 0)に置いた録音を本物の speech で文字起こしし、段落の時刻(秒)と本文を返す。
private func transcribeFixture(_ name: String) async throws -> (
  header: [Substring], paragraphs: [(seconds: Int, text: String)]
) {
  let (values, rate, _) = try samples(of: fixtures.appending(path: name))
  let meeting = try temporaryDirectory("2026-11-06_101500")
  try writeStereoCAF(
    to: meeting.appending(path: "recording.caf"), seconds: Double(values.count) / rate
  ) {
    values[min(Int(($0 * rate).rounded()), values.count - 1)]
  }

  try await transcribe(meeting: meeting, installation: .standard)

  let transcript = try String(
    contentsOf: meeting.appending(path: "transcript.md"), encoding: .utf8)
  print("transcript \(name) \(meeting.path)\n\(transcript)")
  let lines = transcript.split(separator: "\n")
  let paragraphs = lines.compactMap { line -> (Int, String)? in
    guard let match = String(line).wholeMatch(of: /\[(\d{2}):(\d{2}):(\d{2})\] (.+)/) else {
      return nil
    }
    return (Int(match.1)! * 3600 + Int(match.2)! * 60 + Int(match.3)!, String(match.4))
  }
  return (Array(lines.prefix(4)), paragraphs)
}

private let e2eEnabled =
  ProcessInfo.processInfo.environment["AMANUENSIS_E2E"] == "1"
  && SpeechInstallation.standard.isInstalled

@Test(.enabled(if: e2eEnabled), arguments: ["transcription-3x.wav", "transcription-3x-quiet.wav"])
func transcribeFixtureWithBundledModel(name: String) async throws {
  let reference = try String(contentsOf: sampleText, encoding: .utf8)

  let (header, paragraphs) = try await transcribeFixture(name)

  #expect(
    header == [
      "# 会議の文字起こし", "- 日時: 2026-11-06 10:15:00", "- 録音の長さ: 00:01:15",
      "- モデル: Haas-616M-ja-v1.0-Q8_0.gguf",
    ])
  #expect(paragraphs.count == 3, "回ごとに 1 段落")
  for (paragraph, start) in zip(paragraphs, [1.0, 26.6, 52.2]) {
    let cer = characterErrorRate(paragraph.text, reference: reference)
    print("cer \(name) [\(paragraph.seconds)] \(String(format: "%.4f", cer))")
    #expect(cer <= selfCheckMaxCER, "段落 \(paragraph.seconds) 秒の CER \(cer)")
    #expect(paragraph.text.hasPrefix("これは"), "段落 \(paragraph.seconds) 秒が回の冒頭で始まる")
    #expect(
      abs(Double(paragraph.seconds) - start) <= 2, "段落の時刻 \(paragraph.seconds) が回の開始 \(start) の付近")
  }
}
