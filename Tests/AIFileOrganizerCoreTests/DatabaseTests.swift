import Testing

@testable import AIFileOrganizerCore

@Suite struct DatabaseTests {
  @Test func createsExactlyTheV2EntityTables() throws {
    let database = try AppDatabase.inMemory()
    for table in [
      "workspaces", "sessions", "item_snapshots", "proposals", "folder_proposals", "plans",
      "operations", "decision_records",
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
}
