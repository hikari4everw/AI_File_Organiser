import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct HistoryTests {
  @Test func listsLatestPlansForWorkspaceWithReceipts() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "volume",
      libraryVolumeID: "volume"
    )
    try database.saveWorkspace(workspace)
    let session = OrganizationSession(workspaceID: workspace.id)
    try database.saveSession(session)
    let plan = OrganizationPlan(sessionID: session.id, operations: [])
    try database.savePlan(plan)
    let receipt = ExecutionReceipt(planID: plan.id, results: [])
    try database.saveReceipt(receipt)

    let entries = try HistoryStore(database: database).entries(workspaceID: workspace.id)

    #expect(entries.count == 1)
    #expect(entries[0].plan.id == plan.id)
    #expect(entries[0].receipt?.id == receipt.id)
  }
}
