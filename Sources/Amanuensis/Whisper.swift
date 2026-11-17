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

/// whisper-cli の JSON を語の列にする。UTF-8 でないバイト列・デコードできない JSON・`transcription` の無い JSON・
/// 時刻が `0 <= from <= to <= (duration + 30) * 1000` ミリ秒でない語は投げる。語の時刻が無ければその段落の時刻を使う。
/// 語の時刻は録音の長さに収める。特殊トークンと `text` が空の語は捨て、`text` の制御文字と U+2028・U+2029 は除く。
func whisperTokens(_ output: Data, duration: TimeInterval) throws(WhisperOutputError)
  -> [RecognizedToken]
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
  var tokens: [RecognizedToken] = []
  for segment in segments {
    for token in segment.tokens where token.id < firstSpecialTokenID {
      let time = token.offsets ?? segment.offsets
      guard 0 <= time.from, time.from <= time.to, Double(time.to) <= limit else {
        throw .timeOutOfRange
      }
      let text = lineSafe(token.text)
      if !text.isEmpty {
        tokens.append(
          RecognizedToken(
            start: min(Double(time.from) / 1000, duration),
            end: min(Double(time.to) / 1000, duration), text: text))
      }
    }
  }
  return tokens
}
