import Testing

@testable import AIFileOrganizerCore

@Suite struct ConceptLabelTests {
  @Test func naturalTeachingPhraseBecomesConceptName() {
    #expect(ConceptLabelParser.name(from: "这些是 COMP2012 的课程讲义。") == "COMP2012 的课程讲义")
    #expect(ConceptLabelParser.name(from: "这些文件是银行账单") == "银行账单")
    #expect(ConceptLabelParser.name(from: "钢琴谱") == "钢琴谱")
  }
}
