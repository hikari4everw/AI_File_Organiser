import Foundation
import Testing

@testable import AIFileOrganizerCore

@Suite struct DatabaseTests {
  @Test func createsExactlyTheV2EntityTables() throws {
    let database = try AppDatabase.inMemory()
    for table in [
      "workspaces", "sessions", "item_snapshots", "proposals", "folder_proposals", "plans",
      "operations", "decision_records", "libraries", "destinations", "organization_rules",
      "learning_events", "learning_samples", "rule_suggestions",
    ] {
      #expect(try database.rowCount(table) == 0)
    }
  }

  @Test func persistsWorkspaceAndSession() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume"
    )
    try database.saveWorkspace(workspace)
    #expect(try database.latestWorkspace()?.id == workspace.id)
    try database.saveSession(OrganizationSession(workspaceID: workspace.id))
    #expect(try database.rowCount("sessions") == 1)
  }

  @Test func deactivatingWorkspacePreservesItsHistory() throws {
    let database = try AppDatabase.inMemory()
    let workspace = Workspace(
      inboxPath: "/tmp/inbox", libraryPath: "/tmp/library",
      inboxVolumeID: "volume", libraryVolumeID: "volume")
    try database.saveWorkspace(workspace)
    try database.saveSession(OrganizationSession(workspaceID: workspace.id))
    try database.deactivateWorkspaces()
    #expect(try database.latestWorkspace() == nil)
    #expect(try database.rowCount("workspaces") == 1)
    #expect(try database.rowCount("sessions") == 1)
  }

  @Test func reloadsSavedPlanAndItsPartialReceipt() throws {
    let database = try AppDatabase.inMemory()
    let workspaceID = UUID()
    let workspace = Workspace(
      id: workspaceID,
      inboxPath: "/tmp/inbox",
      libraryPath: "/tmp/library",
      inboxVolumeID: "volume",
      libraryVolumeID: "volume"
    )
    let session = OrganizationSession(workspaceID: workspaceID)
    let operation = PlannedOperation(
      sequence: 0,
      kind: .move,
      sourcePath: "/tmp/inbox/a.txt",
      destinationPath: "/tmp/library/Docs/a.txt"
    )
    let plan = OrganizationPlan(sessionID: session.id, operations: [operation])
    let receipt = ExecutionReceipt(
      planID: plan.id,
      results: [OperationResult(operationID: operation.id, state: .completed)]
    )
    try database.saveWorkspace(workspace)
    try database.saveSession(session)
    try database.savePlan(plan)
    try database.saveReceipt(receipt)

    let storedPlan = try database.plan(id: plan.id)
    let loaded = try #require(storedPlan)
    #expect(loaded.id == plan.id)
    #expect(loaded.sessionID == plan.sessionID)
    #expect(loaded.operations == plan.operations)
    #expect(try database.plans(workspaceID: workspaceID).map(\.id) == [plan.id])
    let storedReceipt = try database.receipt(planID: plan.id)
    let loadedReceipt = try #require(storedReceipt)
    #expect(loadedReceipt.id == receipt.id)
    #expect(loadedReceipt.planID == receipt.planID)
    #expect(loadedReceipt.results == receipt.results)
  }
}
