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

private struct TimeOutOfRange: Error {}
private struct NotUTF8: Error {}

/// whisper-cli の JSON を語の列にする。UTF-8 でないバイト列・デコードできない JSON・`transcription` の無い JSON・
/// 時刻が `0 <= from <= to <= (duration + 1) * 1000` ミリ秒でない語は投げる。語の時刻が無ければその段落の時刻を使う。
/// 特殊トークンと `text` が空の語は捨て、`text` の制御文字と U+2028・U+2029 は除く。
func whisperTokens(_ output: Data, duration: TimeInterval) throws -> [RecognizedToken] {
  // JSONDecoder は読み飛ばす項目の不正なバイトを見ないので、全体を先に確かめる。
  guard String(validating: output, as: UTF8.self) != nil else { throw NotUTF8() }
  let segments = try JSONDecoder().decode(WhisperOutput.self, from: output).transcription
  // + 1 秒: speakerSegments と同じ余裕。
  let limit = (duration + 1) * 1000
  var tokens: [RecognizedToken] = []
  for segment in segments {
    for token in segment.tokens where token.id < firstSpecialTokenID {
      let time = token.offsets ?? segment.offsets
      guard 0 <= time.from, time.from <= time.to, Double(time.to) <= limit else {
        throw TimeOutOfRange()
      }
      let text = lineSafe(token.text)
      if !text.isEmpty {
        tokens.append(
          RecognizedToken(
            start: Double(time.from) / 1000, end: Double(time.to) / 1000, text: text))
      }
    }
  }
  return tokens
}
