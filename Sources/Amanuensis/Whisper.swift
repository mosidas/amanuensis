import Foundation

/// `whisper-cli -ojf` の JSON のうち使う部分。時刻は録音の先頭からのミリ秒。
private struct WhisperOutput: Decodable {
  struct Offsets: Decodable {
    let from: Int
    let to: Int
  }
  struct Token: Decodable {
    let text: String
    /// whisper-cli は語の時刻が取れたときだけ書く(examples/cli/cli.cpp の output_json)。
    let offsets: Offsets?
    let id: Int
  }
  struct Segment: Decodable {
    let offsets: Offsets
    let tokens: [Token]
  }
  let transcription: [Segment]
}

// 50257: 多言語の語彙の <|endoftext|>。これ以降の id は `[_BEG_]`・`[_TT_n]` などの特殊トークンで、本文ではない。
private let firstSpecialTokenID = 50257

/// whisper-cli の出力を使えなかった理由。raw value はログの `reason`。
enum WhisperOutputError: String, Error {
  /// `-ojf` の JSON ファイルが無い・読めない。
  case missingJSON = "missing_json"
  case notUTF8 = "not_utf8"
  /// JSON でない・`transcription` が無いなど、想定の形にデコードできない。
  case undecodableJSON = "undecodable_json"
  case timeOutOfRange = "time_out_of_range"
}

/// whisper-cli の段落(`transcription` の 1 要素)。
struct WhisperLine: Equatable {
  /// 段落の時刻(秒)。録音の長さに収めない。
  let start: TimeInterval
  let end: TimeInterval
  /// 時刻を録音の長さに収めた語。1 個以上。
  let tokens: [RecognizedToken]
}

/// whisper-cli の JSON を段落の列にする。UTF-8 でないバイト列・デコードできない JSON・`transcription` の無い JSON・
/// 時刻が `0 <= from <= to <= (duration + 30) * 1000` ミリ秒でない段落か語は投げる。語の時刻が無ければその段落の時刻を使う。
/// 語の時刻は録音の長さに収める。特殊トークンと `text` が空の語は捨て、`text` の制御文字と U+2028・U+2029 は除く。
/// 語の残らない段落は返さない。
func whisperLines(_ output: Data, duration: TimeInterval) throws(WhisperOutputError)
  -> [WhisperLine]
{
  // JSONDecoder は読み飛ばす項目の不正なバイトを見ないので、全体を先に確かめる。
  guard String(validating: output, as: UTF8.self) != nil else { throw .notUTF8 }
  let segments: [WhisperOutput.Segment]
  do {
    segments = try JSONDecoder().decode(WhisperOutput.self, from: output).transcription
  } catch {
    throw .undecodableJSON
  }
  // whisper.cpp は 30 秒の窓で進み、最後の窓の段落と語の時刻は窓の終わりまで伸びうる(末尾の無音に出す幻聴の段落など)。
  // 窓は録音の中で始まるので、時刻は録音の長さ + 30 秒を超えない。
  let limit = (duration + 30) * 1000
  func inRange(_ time: WhisperOutput.Offsets) -> Bool {
    0 <= time.from && time.from <= time.to && Double(time.to) <= limit
  }
  var lines: [WhisperLine] = []
  for segment in segments {
    guard inRange(segment.offsets) else { throw .timeOutOfRange }
    var tokens: [RecognizedToken] = []
    for token in segment.tokens where token.id < firstSpecialTokenID {
      let time = token.offsets ?? segment.offsets
      guard inRange(time) else { throw .timeOutOfRange }
      let text = lineSafe(token.text)
      if !text.isEmpty {
        tokens.append(
          RecognizedToken(
            start: min(Double(time.from) / 1000, duration),
            end: min(Double(time.to) / 1000, duration), text: text))
      }
    }
    if !tokens.isEmpty {
      lines.append(
        WhisperLine(
          start: Double(segment.offsets.from) / 1000, end: Double(segment.offsets.to) / 1000,
          tokens: tokens))
    }
  }
  return lines
}

/// 幻聴と判定した、隣り合う段落の区間。
struct Hallucination: Equatable {
  /// 段落の列の添字。
  let lines: Range<Int>
  /// 先頭の段落の始まりから末尾の段落の終わりまで(秒)。録音の長さに収めない。
  let start: TimeInterval
  let end: TimeInterval
}

// shortcut: 観測した 2 語だけ, 新しい幻聴の語を観測したら一覧に足す
private let knownHallucinations = ["ご視聴ありがとうございました", "おだしょー"]
private let sentenceEnds: Set<Character> = ["。", "．", ".", "！", "!", "？", "?"]
private let ignoredInComparison = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

/// 既知の幻聴の語を含む段落と、同じ文が 3 回以上続けて並ぶ段落を幻聴とし、隣り合う幻聴の段落をまとめた区間を先頭から返す。
/// 語と文は空白と約物を除いて比べる。文は「。．.！!？?」と段落の境界で分け、約物だけの文は数えない。
func hallucinations(in lines: [WhisperLine]) -> [Hallucination] {
  let texts = lines.map { $0.tokens.map(\.text).joined() }
  var found = texts.map { text in knownHallucinations.contains { comparable(text).contains($0) } }
  let sentences = texts.enumerated().flatMap { line, text in
    text.split(whereSeparator: sentenceEnds.contains).map { (line: line, text: comparable($0)) }
      .filter { !$0.text.isEmpty }
  }
  // shortcut: 3 回以上, 実際の会議で誤検出か検出漏れの報告があれば決め直す
  var runStart = 0
  for index in sentences.indices
  where index + 1 == sentences.count || sentences[index + 1].text != sentences[index].text {
    if index - runStart + 1 >= 3 {
      for sentence in sentences[runStart...index] { found[sentence.line] = true }
    }
    runStart = index + 1
  }
  var ranges: [Range<Int>] = []
  for index in found.indices where found[index] {
    if let last = ranges.last, last.upperBound == index {
      ranges[ranges.count - 1] = last.lowerBound..<index + 1
    } else {
      ranges.append(index..<index + 1)
    }
  }
  return ranges.map {
    Hallucination(lines: $0, start: lines[$0.lowerBound].start, end: lines[$0.upperBound - 1].end)
  }
}

private func comparable(_ text: some StringProtocol) -> String {
  String(String.UnicodeScalarView(text.unicodeScalars.filter { !ignoredInComparison.contains($0) }))
}

/// `lines` の語を順に並べ、`hallucinations` の区間の段落の語の代わりに、中点が区間の `[start, end]` に入る `haas` の語を並べる。
/// `hallucinations` は `hallucinations(in: lines)` の返した区間、`haas` は時刻の順の語。
func replacing(
  _ hallucinations: [Hallucination], in lines: [WhisperLine], with haas: [RecognizedToken]
) -> [RecognizedToken] {
  var tokens: [RecognizedToken] = []
  var next = lines.startIndex
  for hallucination in hallucinations {
    tokens += lines[next..<hallucination.lines.lowerBound].flatMap(\.tokens)
    // shortcut: 中点で採る, 重複の報告があれば隣の段落の時刻を除く
    tokens += haas.filter {
      let midpoint = ($0.start + $0.end) / 2
      return hallucination.start <= midpoint && midpoint <= hallucination.end
    }
    next = hallucination.lines.upperBound
  }
  return tokens + lines[next...].flatMap(\.tokens)
}
