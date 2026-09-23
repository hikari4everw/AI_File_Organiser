import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct CreatorCatalogTests {
  @Test func parsesCircleCreatorTitleAndEditionTags() {
    let name = "［おじたん屋さん（まめおじたん）］ 作品名 ［中国翻訳］ ［DL版］"
    let parsed = WorkNameParser().parse(name)

    #expect(parsed.originalName == name)
    #expect(parsed.circleName?.precomposedStringWithCanonicalMapping == "おじたん屋さん")
    #expect(parsed.authorNames.first?.precomposedStringWithCanonicalMapping == "まめおじたん")
    #expect(parsed.title == "作品名")
    #expect(parsed.tags == ["中国翻訳", "DL版"])
  }

  @Test func confirmedBilingualAliasResolvesSameCreatorAcrossLaunches() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let catalog = CreatorCatalog(database: database)
    let creator = try catalog.create(
      workspaceID: workspaceID, japaneseName: "まめおじたん",
      englishName: nil, circleName: "おじたん屋さん")
    try catalog.confirmAlias(
      "Mame Ojitan", for: creator.id, sourceURL: "https://example.org/creator/mame")
    try catalog.bindDestination(
      "bunga/[おじたん屋さん] まめおじたん", for: creator.id, categoryPath: "bunga")

    let reopened = CreatorCatalog(database: database)
    let parsed = WorkNameParser().parse("[Circle (Mame Ojitan)] New Work")
    guard case .confirmed(let found) = try reopened.resolve(parsed, workspaceID: workspaceID) else {
      Issue.record("确认的英文别名应指向同一个作者")
      return
    }
    #expect(found.id == creator.id)
    #expect(found.aliasSources["Mame Ojitan"] == "https://example.org/creator/mame")
    #expect(found.preferredDestinations["bunga"] == "bunga/[おじたん屋さん] まめおじたん")
  }

  @Test func sameCircleDoesNotMergeDifferentAuthors() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let catalog = CreatorCatalog(database: database)
    let first = try catalog.create(
      workspaceID: workspaceID, japaneseName: "作者甲", englishName: nil,
      circleName: "同社团")
    let second = try catalog.create(
      workspaceID: workspaceID, japaneseName: "作者乙", englishName: nil,
      circleName: "同社团")

    guard case .confirmed(let resolved) = try catalog.resolve(
      WorkNameParser().parse("[同社团 (作者乙)] 新作品"), workspaceID: workspaceID)
    else {
      Issue.record("作者乙应能单独识别")
      return
    }
    #expect(resolved.id == second.id)
    #expect(resolved.id != first.id)
  }

  @Test func multipleAuthorsRemainAmbiguousAndEnglishNameIsNotInvented() throws {
    let catalog = CreatorCatalog(database: try .inMemory())
    let workspaceID = UUID()
    let creator = try catalog.create(
      workspaceID: workspaceID, japaneseName: "作者甲", englishName: nil, circleName: "社团")
    #expect(creator.proposedDirectoryName == "[社团] 作者甲")
    let result = try catalog.resolve(
      WorkNameParser().parse("[社团 (作者甲 & 作者乙)] 合集"), workspaceID: workspaceID)
    #expect(result == .ambiguous)
    let slash = WorkNameParser().parse("[社团 (作者甲 / 作者乙)] 合集")
    #expect(slash.hasMultipleAuthors)
    #expect(try catalog.resolve(slash, workspaceID: workspaceID) == .ambiguous)
  }

  @Test func confirmedEnglishAliasAppearsInProposedFolderName() throws {
    let database = try AppDatabase.inMemory()
    let catalog = CreatorCatalog(database: database)
    let creator = try catalog.create(workspaceID: UUID(), japaneseName: "まめおじたん",
      englishName: nil, circleName: "おじたん屋さん")
    try catalog.confirmAlias("Mame Ojitan", for: creator.id,
      sourceURL: "https://example.test/author")
    let saved = try database.creatorIdentity(id: creator.id)
    let updated = try #require(saved)
    #expect(updated.proposedDirectoryName == "[おじたん屋さん] まめおじたん (Mame Ojitan)")
  }
}
