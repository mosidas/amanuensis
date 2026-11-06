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

/// speech の標準出力を語の列にする。`file` が `chunks` のどれでもない行・デコードできない行・`tokens` の無い行は投げる。
/// `text` が空の語は捨てる。区間の最初の語は次の語の始まりの時刻にする。
func recognizedTokens(_ stdout: Data, chunks: [AudioChunk]) throws -> [RecognizedToken] {
  let offsets = Dictionary(uniqueKeysWithValues: chunks.map { ($0.file.path, $0.offset) })
  let decoder = JSONDecoder()
  var tokens: [RecognizedToken] = []
  for line in stdout.split(separator: UInt8(ascii: "\n")) {
    let output = try decoder.decode(SpeechOutputLine.self, from: Data(line))
    guard let offset = offsets[output.file] else { throw UnexpectedFile() }
    // speech は区間の最初の語を、音声の始まりにかかわらず start=0 で出す(実測: 2.95 秒から話し始める区間で
    // `(0, 0.32, "これは"), (3.6, 3.76, "ア")`)。普通は空の text だが、無音で始まる区間では実在の語が来る。
    var raw = output.tokens
    if raw.count > 1 {
      raw[0] = .init(start: raw[1].start, end: raw[1].start, text: raw[0].text)
    }
    tokens += raw.filter { !$0.text.isEmpty }.map {
      RecognizedToken(start: $0.start + offset, end: $0.end + offset, text: $0.text)
    }
  }
  return tokens
}

/// 前の語の終わりから次の語の始まりまでが 1.5 秒以上なら段落を分け、段落の本文は語を連結する。
func paragraphs(_ tokens: [RecognizedToken]) -> [TranscriptParagraph] {
  // shortcut: 語の間隔 1.5 秒で段落を分ける(観測: 文の間は最大 0.32 秒、フィクスチャの回の間 3.12 秒), 実際の会議で段落が長すぎる・細かすぎる報告があれば決め直す
  var result: [TranscriptParagraph] = []
  var previousEnd: TimeInterval?
  for token in tokens {
    if let end = previousEnd, token.start - end < 1.5, let last = result.popLast() {
      result.append(TranscriptParagraph(start: last.start, text: last.text + token.text))
    } else {
      result.append(TranscriptParagraph(start: token.start, text: token.text))
    }
    previousEnd = token.end
  }
  return result
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
      ? ["発話はありませんでした。"] : paragraphs.map { "[\(clock($0.start))] \($0.text)" }
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
