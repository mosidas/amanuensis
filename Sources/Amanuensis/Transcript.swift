import Foundation

/// 認識した語。秒は録音の先頭から(区間の先頭を足した後)。
struct RecognizedToken: Equatable {
  let start: TimeInterval
  let end: TimeInterval
  let text: String
}

struct TranscriptParagraph: Equatable {
  let start: TimeInterval
  let text: String
  /// 表示する話者の番号(1 から)。nil はラベル無し。
  var speaker: Int? = nil
}

/// `speech diarize` の話者の区間。秒は録音の先頭から、`speaker` は speech の番号のまま(ファイルごとに 0 から登場順)。
struct SpeakerSegment: Equatable, Decodable {
  let start: TimeInterval
  let end: TimeInterval
  let speaker: Int
}

/// `speech diarize --format json` がファイルごとに 1 行で出す JSON。
private struct DiarizeOutputLine: Decodable {
  let file: String
  let segments: [SpeakerSegment]
}

/// `speech asr --timestamps --format json` が区間ごとに 1 行で出す JSON のうち、使う部分。
private struct SpeechOutputLine: Decodable {
  struct Token: Decodable {
    let start: Double
    let end: Double
    let text: String
  }
  let file: String
  let tokens: [Token]
}

private struct UnexpectedFile: Error {}
private struct UnexpectedTime: Error {}

// 120 秒: 区間は最長 60 秒(`TranscriptionAudio.swift`)。区間の中の時刻がそれを大きく超えることは無いので倍の余裕を取る。
private let maxTokenSeconds: TimeInterval = 120

/// speech の標準出力を語の列にする。`file` が `chunks` のどれでもない行・同じ `file` の 2 行目・デコードできない行・
/// `tokens` の無い行・時刻が `0 <= start <= end <= 120` でない語のある行は投げる。行の無い区間があっても投げる。
/// `text` が空の語は捨て、`text` の制御文字と U+2028・U+2029 は除く。区間の最初の語は次の語の始まりの時刻にする。
func recognizedTokens(_ stdout: Data, chunks: [AudioChunk]) throws -> [RecognizedToken] {
  var pending = Dictionary(uniqueKeysWithValues: chunks.map { ($0.file.path, $0.offset) })
  let decoder = JSONDecoder()
  var tokens: [RecognizedToken] = []
  for line in stdout.split(separator: UInt8(ascii: "\n")) {
    let output = try decoder.decode(SpeechOutputLine.self, from: Data(line))
    guard let offset = pending.removeValue(forKey: output.file) else { throw UnexpectedFile() }
    // speech は区間の最初の語を、音声の始まりにかかわらず start=0 で出す(実測: 2.95 秒から話し始める区間で
    // `(0, 0.32, "これは"), (3.6, 3.76, "ア")`)。普通は空の text だが、無音で始まる区間では実在の語が来る。
    var raw = output.tokens
    guard raw.allSatisfy({ 0 <= $0.start && $0.start <= $0.end && $0.end <= maxTokenSeconds })
    else { throw UnexpectedTime() }
    if raw.count > 1 {
      raw[0] = .init(start: raw[1].start, end: raw[1].start, text: raw[0].text)
    }
    tokens += raw.map {
      RecognizedToken(start: $0.start + offset, end: $0.end + offset, text: lineSafe($0.text))
    }.filter { !$0.text.isEmpty }
  }
  guard pending.isEmpty else { throw UnexpectedFile() }
  return tokens
}

/// diarize の標準出力を区間の列にする。標準出力がちょうど 1 行で、その `file` が `file` のパスで、
/// どの区間も `0 <= start <= end <= duration + 1` のときだけ返し、それ以外は投げる。
func speakerSegments(_ stdout: Data, file: URL, duration: TimeInterval) throws -> [SpeakerSegment] {
  let lines = stdout.split(separator: UInt8(ascii: "\n"))
  guard lines.count == 1 else { throw UnexpectedFile() }
  let output = try JSONDecoder().decode(DiarizeOutputLine.self, from: Data(lines[0]))
  guard output.file == file.path else { throw UnexpectedFile() }
  // + 1 秒: 区間の時刻はモデルのフレームに丸めた値(実測で 0.01 秒刻み)で、末尾が録音の長さを超えうる分の余裕。
  // 試作の出力(78 秒・10 分・60 分)では超えた区間は無かった。
  guard
    output.segments.allSatisfy({ 0 <= $0.start && $0.start <= $0.end && $0.end <= duration + 1 })
  else { throw UnexpectedTime() }
  return output.segments
}

/// 段落を 1 行に保つため、改行・CR・ESC などの制御文字(Cc)と行・段落の区切り(U+2028・U+2029)を除く。
private func lineSafe(_ text: String) -> String {
  String(
    String.UnicodeScalarView(
      text.unicodeScalars.filter {
        $0.properties.generalCategory != .control && $0 != "\u{2028}" && $0 != "\u{2029}"
      }))
}

/// 前の語の終わりから次の語の始まりまでが 1.5 秒以上か、`speakers` で語の話者が替わったら段落を分け、
/// 段落の本文は語を連結する。`speakers` が nil か空なら話者で分けずラベルも付けない。
/// 段落の `speaker` は speech の番号を段落に登場した順に 1, 2, … と振り直した値。
func paragraphs(_ tokens: [RecognizedToken], speakers: [SpeakerSegment]? = nil)
  -> [TranscriptParagraph]
{
  // shortcut: 語の間隔 1.5 秒で段落を分ける(観測: 文の間は最大 0.32 秒、フィクスチャの回の間 3.12 秒), 実際の会議で段落が長すぎる・細かすぎる報告があれば決め直す
  let segments = speakers ?? []
  var numbers: [Int: Int] = [:]
  var result: [TranscriptParagraph] = []
  var previous: (end: TimeInterval, speaker: Int?)?
  for token in tokens {
    let speaker = segments.isEmpty ? nil : speaker(of: token, in: segments)
    if let previous, token.start - previous.end < 1.5, speaker == previous.speaker,
      let last = result.popLast()
    {
      result.append(
        TranscriptParagraph(start: last.start, text: last.text + token.text, speaker: last.speaker))
    } else {
      let number = speaker.map { id in
        if let number = numbers[id] { return number }
        numbers[id] = numbers.count + 1
        return numbers.count
      }
      result.append(TranscriptParagraph(start: token.start, text: token.text, speaker: number))
    }
    previous = (token.end, speaker)
  }
  return result
}

/// 語と重なる長さが最大の区間の話者(同じ長さなら先の区間)。どの区間とも重ならなければ語に最も近い区間の話者。
private func speaker(of token: RecognizedToken, in segments: [SpeakerSegment]) -> Int {
  // shortcut: 語の話者は重なり最大の区間で決める(重なる発話は片方に寄る), 実際の会議で相づちが別段落に割れすぎる報告があれば短い交代を前の段落に含める
  // 重ならない区間ではこの値は語との距離の負になるので、最大の区間は重ならないときに最も近い区間でもある。
  func overlap(_ segment: SpeakerSegment) -> TimeInterval {
    min(segment.end, token.end) - max(segment.start, token.start)
  }
  // min(by:) は等しい要素のうち先のものを返す。
  return segments.min { overlap($0) > overlap($1) }!.speaker
}

struct Transcript: Equatable {
  let meetingName: String
  let duration: TimeInterval
  let model: String
  let paragraphs: [TranscriptParagraph]

  /// `transcript.md` の本文。日時は会議フォルダーの名前から読み、読めなければ名前をそのまま書く。
  var markdown: String {
    let date = RecordingFolder.meetingDate(named: meetingName).map {
      Self.displayDate.string(from: $0)
    }
    let header = """
      # 会議の文字起こし

      - 日時: \(date ?? meetingName)
      - 録音の長さ: \(clock(duration))
      - モデル: \(model)


      """
    let body =
      paragraphs.isEmpty
      ? ["発話はありませんでした。"]
      : paragraphs.map { paragraph in
        let label = paragraph.speaker.map { "話者 \($0): " } ?? ""
        return "[\(clock(paragraph.start))] \(label)\(paragraph.text)"
      }
    return header + body.joined(separator: "\n\n") + "\n"
  }

  private static let displayDate = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()
}

/// 秒を切り捨てて `HH:MM:SS` にする。
private func clock(_ seconds: TimeInterval) -> String {
  let total = Int(seconds)
  return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}
