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
    try database.plans(workspaceID: workspaceID).map { plan in
      HistoryEntry(
        plan: plan,
        receipt: try reconcile(
          plan: plan,
          stored: database.receipt(planID: plan.id),
          workspaceID: workspaceID
        )
      )
    }
  }

  private func reconcile(
    plan: OrganizationPlan,
    stored: ExecutionReceipt?,
    workspaceID: UUID
  ) throws -> ExecutionReceipt? {
    var states = try database.operationStates(planID: plan.id)
    var changed = false
    for operation in plan.operations {
      guard let state = states[operation.id] else { continue }
      switch (state, operation.kind) {
      case (.running, .move):
        let sourceExists = operation.sourcePath.map(FileManager.default.fileExists(atPath:)) ?? false
        let destination = URL(fileURLWithPath: operation.destinationPath)
        if !sourceExists, operation.preSnapshot?.matches(destination) == true {
          let sample = learningSample(
            operation: operation, workspaceID: workspaceID, sessionID: plan.sessionID)
          try database.finishOperation(operation.id, state: .completed, learningSample: sample)
          states[operation.id] = .completed
        } else {
          try database.updateOperation(
            operation.id, state: .blocked, error: "崩溃恢复时无法确认移动结果")
          states[operation.id] = .blocked
        }
        changed = true
      case (.running, .createDirectory):
        let destination = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
        let staging = DirectoryOwnership.stagingURL(for: operation)
        if DirectoryOwnership.isOwned(destination, by: operation) {
          try database.finishOperation(operation.id, state: .completed)
          states[operation.id] = .completed
        } else if !FileManager.default.fileExists(atPath: destination.path),
          DirectoryOwnership.isOwned(staging, by: operation)
        {
          do {
            try FileManager.default.moveItem(at: staging, to: destination)
            try database.finishOperation(operation.id, state: .completed)
            states[operation.id] = .completed
          } catch {
            try database.updateOperation(
              operation.id, state: .blocked,
              error: "恢复目录创建时目标状态已变化：\(error.localizedDescription)")
            states[operation.id] = .blocked
          }
        } else {
          if DirectoryOwnership.isOwned(staging, by: operation) {
            try? FileManager.default.removeItem(at: staging)
          }
          try database.updateOperation(
            operation.id, state: .blocked, error: "无法确认目录是否由应用创建")
          states[operation.id] = .blocked
        }
        changed = true
      case (.undoing, .move):
        guard let sourcePath = operation.sourcePath else {
          let result = OperationResult(
            operationID: operation.id, state: .blocked, error: "撤销缺少原始位置")
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undoBlocked
          changed = true
          continue
        }
        let source = URL(fileURLWithPath: sourcePath)
        let destination = URL(fileURLWithPath: operation.destinationPath)
        if operation.preSnapshot?.matches(source) == true,
          !FileManager.default.fileExists(atPath: destination.path)
        {
          let result = OperationResult(operationID: operation.id, state: .undone)
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undone
        } else if !FileManager.default.fileExists(atPath: source.path),
          operation.preSnapshot?.matches(destination) == true
        {
          try database.updateOperation(operation.id, state: .completed)
          states[operation.id] = .completed
        } else {
          let result = OperationResult(
            operationID: operation.id, state: .blocked, error: "崩溃恢复时无法确认撤销结果")
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undoBlocked
        }
        changed = true
      case (.undoing, .createDirectory):
        let destination = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
        if DirectoryOwnership.isOwned(destination, by: operation) {
          try database.updateOperation(operation.id, state: .completed)
          states[operation.id] = .completed
        } else if FileManager.default.fileExists(atPath: operation.destinationPath) {
          let result = OperationResult(
            operationID: operation.id, state: .blocked, error: "无法验证目录由本应用创建")
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undoBlocked
        } else {
          let result = OperationResult(operationID: operation.id, state: .undone)
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undone
        }
        changed = true
      case (.completed, .move):
        guard let sourcePath = operation.sourcePath else { continue }
        let source = URL(fileURLWithPath: sourcePath)
        if operation.preSnapshot?.matches(source) == true,
          !FileManager.default.fileExists(atPath: operation.destinationPath)
        {
          let result = OperationResult(operationID: operation.id, state: .undone)
          try database.finishUndoOperation(operation.id, result: result)
          states[operation.id] = .undone
          changed = true
        }
      default: break
      }
    }

    let storedStates = Dictionary(uniqueKeysWithValues: (stored?.results ?? []).map {
      ($0.operationID, $0.state)
    })
    let allOperationsTerminal = plan.operations.allSatisfy { operation in
      guard let state = states[operation.id] else { return false }
      return state != .pending && state != .running && state != .undoing
    }
    if let stored, stored.isFinal != allOperationsTerminal { changed = true }
    for (operationID, state) in states where state != .pending {
      let receiptState: OperationState = state == .undoBlocked ? .blocked : state
      if storedStates[operationID] != receiptState { changed = true }
    }

    guard stored != nil || states.values.contains(where: { $0 != .pending }) else { return nil }
    guard changed || stored == nil else { return stored }
    let prior = Dictionary(uniqueKeysWithValues: (stored?.results ?? []).map {
      ($0.operationID, $0)
    })
    let results = plan.operations.compactMap { operation -> OperationResult? in
      guard let state = states[operation.id], state != .pending else { return nil }
      let receiptState: OperationState = state == .undoBlocked ? .blocked : state
      if prior[operation.id]?.state == receiptState { return prior[operation.id] }
      return OperationResult(operationID: operation.id, state: receiptState)
    }
    let receipt = ExecutionReceipt(
      planID: plan.id,
      results: results,
      wasCancelled: stored?.wasCancelled == true || !allOperationsTerminal,
      isUndoReceipt: stored?.isUndoReceipt == true || states.values.contains(.undone)
        || states.values.contains(.undoBlocked),
      isFinal: allOperationsTerminal
    )
    try database.saveReceipt(receipt)
    return receipt
  }

  private func learningSample(
    operation: PlannedOperation,
    workspaceID: UUID,
    sessionID: UUID
  ) -> LearningSample? {
    guard let destinationID = operation.destinationID,
      let features = operation.decisionFeatures,
      let confirmation = operation.learningConfirmation
    else { return nil }
    return LearningSample(
      libraryID: workspaceID,
      sessionID: sessionID,
      operationID: operation.id,
      itemIdentity: operation.preSnapshot?.resourceIdentifier
        ?? operation.itemID?.uuidString
        ?? operation.sourcePath
        ?? operation.id.uuidString,
      destinationID: destinationID,
      features: features,
      confirmation: confirmation
    )
  }
}
