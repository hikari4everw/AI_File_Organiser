import Foundation

public struct HistoryEntry: Sendable {
  public var plan: OrganizationPlan
  public var receipt: ExecutionReceipt?

  public init(plan: OrganizationPlan, receipt: ExecutionReceipt?) {
    self.plan = plan
    self.receipt = receipt
  }
}

public struct HistoryStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func entries(workspaceID: UUID) throws -> [HistoryEntry] {
    try database.plans(workspaceID: workspaceID).map {
      HistoryEntry(plan: $0, receipt: try database.receipt(planID: $0.id))
    }
  }
}
