import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct CatalogAcceptanceTests {
  @Test func fiftyHeldOutSyntheticNamesMeetRoutingAndReviewThresholds() {
    let doujin = DestinationProfile(relativePath: "bunga", displayName: "bunga")
    let pdf = DestinationProfile(relativePath: "PDF", displayName: "PDF", keywords: ["pdf"])
    let catalog = CatalogAnalysisResult(profiles: [
      CatalogProfile(relativePath: "bunga", workNames: [
        "[青空工房 (まめ)] 旧作 [DL版]",
        "[月影亭 (あき)] 別の作品 [中国翻訳]",
        "[雨の庭 (ゆき)] 再録 [DL版]",
      ], nameFrequencies: [:], totalWorks: 3, contentAnalyzedWorks: 0,
        userPurpose: "", referenceWorkPaths: []),
      CatalogProfile(relativePath: "PDF", workNames: [
        "annual-report.pdf", "meeting-notes.pdf", "contract.pdf",
      ], nameFrequencies: [:], totalWorks: 3, contentAnalyzedWorks: 0,
        userPurpose: "", referenceWorkPaths: []),
    ], workAnalyses: [], reusedWorkCount: 0, revision: "holdout")
    let classifier = DeterministicClassifier()
    let session = UUID()
    let doujinNames = (1...30).map { number in
      "[サークル\(number) (作者\(number))] 新作\(number) "
        + (number.isMultiple(of: 2) ? "[DL版]" : "[中国翻訳]")
    }
    let confusableNames = (1...10).map { "report-\($0).pdf" }
      + (1...5).map { "[Project \($0) (Alice)] budget [PDF].pdf" }
      + (1...5).map { "unlabeled-\($0).bin" }
    var correctTop = 0
    var readyDoujin = 0
    var wrongReady = 0
    var wrongConfusableTop = 0
    for (index, name) in doujinNames.enumerated() {
      let item = ItemSnapshot(sessionID: session, path: "/tmp/holdout-\(index)", name: name,
        kind: index < 10 ? .file : .directory,
        contentType: index < 10 ? "com.adobe.pdf" : nil,
        fileExtension: index < 10 ? "pdf" : "")
      let context = classifier.context(for: item)
      let ranked = classifier.rank(context, destinations: [pdf, doujin], catalog: catalog)
      let proposal = classifier.proposal(sessionID: session, item: context, candidates: ranked)
      if ranked.first?.destinationID == doujin.id { correctTop += 1 }
      if proposal?.destinationID == doujin.id && proposal?.reviewDecision == .ready {
        readyDoujin += 1
      }
      if proposal?.reviewDecision == .ready && proposal?.destinationID != doujin.id {
        wrongReady += 1
      }
    }
    for (index, name) in confusableNames.enumerated() {
      let isPDF = index < 15
      let item = ItemSnapshot(sessionID: session, path: "/tmp/confusable-\(index)", name: name,
        kind: .file, contentType: isPDF ? "com.adobe.pdf" : nil,
        fileExtension: isPDF ? "pdf" : "bin")
      let context = classifier.context(for: item)
      let ranked = classifier.rank(context, destinations: [pdf, doujin], catalog: catalog)
      let proposal = classifier.proposal(sessionID: session, item: context, candidates: ranked)
      if isPDF && ranked.first?.destinationID != pdf.id { wrongConfusableTop += 1 }
      if proposal?.reviewDecision == .ready && proposal?.destinationID == doujin.id {
        wrongReady += 1
      }
    }
    #expect(correctTop >= 29)
    #expect(readyDoujin >= 24)
    #expect(wrongReady == 0)
    #expect(wrongConfusableTop == 0)
  }
}
