import Foundation
import Testing

@testable import AIFileOrganizerApp
@testable import AIFileOrganizerCore

@Suite @MainActor struct AppModelTests {
  @Test func saveReevaluatesRawExampleAgainstCurrentDraft() {
    let model = AppModel()
    model.workspace = Workspace(
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "test-volume",
      libraryVolumeID: "test-volume")
    model.namingRules = []
    model.lastError = nil
    let draft = NamingRuleDraft(
      originalText: "删除 draft_ 前缀",
      condition: RuleCondition(filenameKeywords: ["draft_"]),
      operations: [.removeLiteralPrefix("draft_")])

    model.saveNamingRuleDraft(
      draft,
      exampleOriginalName: "report.pdf",
      exampleExpectedName: nil)

    #expect(model.namingRules.isEmpty)
    #expect(model.lastError?.contains("没有变化") == true)
  }

  @Test func executionIsBlockedWhileTeachingConcept() {
    let model = AppModel()
    model.workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "test-volume", libraryVolumeID: "test-volume")
    model.proposals = [ClassificationProposal(
      sessionID: UUID(), itemID: UUID(), action: .move,
      destinationID: UUID(), source: .user, reviewDecision: .ready,
      reason: "old concept route")]
    #expect(model.canExecute)

    model.isTeachingConcept = true

    #expect(!model.canExecute)
  }

  @Test func uiTestingDatabaseLivesInTemporaryDirectory() {
    let url = AppModel.uiTestingDatabaseURL
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.pathExtension == "sqlite")
  }
}
