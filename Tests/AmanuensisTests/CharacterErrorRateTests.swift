import Testing

@testable import Amanuensis

@Test func cerIgnoresPunctuationAndSpaces() {
  #expect(characterErrorRate("明日 10時から会議を初めます", reference: "明日、10時から会議を始めます。") == 1.0 / 14)
}

@Test func cerCountsSubstitutionAndInsertion() {
  #expect(characterErrorRate("議事録を共有しました", reference: "議事録を共有します") == 2.0 / 9)
}

@Test func cerOfEmptyHypothesisIsOne() {
  #expect(characterErrorRate("", reference: "議事録を共有します") == 1.0)
}

@Test func cerOfEmptyReferenceIsZeroForEmptyHypothesis() {
  #expect(characterErrorRate("。 、", reference: "") == 0)
}

@Test func cerOfEmptyReferenceIsOneForNonEmptyHypothesis() {
  #expect(characterErrorRate("議事録", reference: "、。 \n") == 1.0)
}
