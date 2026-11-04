import Foundation

/// 文字誤り率(CER)。NFKC で正規化して空白と句読点を除いた文字列どうしの編集距離を、正解の文字数で割る。正解が空なら、仮説も空のとき 0、そうでないとき 1。
func characterErrorRate(_ hypothesis: String, reference: String) -> Double {
  let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
  func normalized(_ text: String) -> [Character] {
    let scalars = text.precomposedStringWithCompatibilityMapping.unicodeScalars
    return Array(String(String.UnicodeScalarView(scalars.filter { !ignored.contains($0) })))
  }
  let hypothesis = normalized(hypothesis)
  let reference = normalized(reference)
  if reference.isEmpty { return hypothesis.isEmpty ? 0 : 1 }
  var previous = Array(0...hypothesis.count)
  for (i, r) in reference.enumerated() {
    var current = [i + 1]
    for (j, h) in hypothesis.enumerated() {
      current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1)))
    }
    previous = current
  }
  return Double(previous[hypothesis.count]) / Double(reference.count)
}
