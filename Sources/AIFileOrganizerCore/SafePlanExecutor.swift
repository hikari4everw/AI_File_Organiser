import Foundation

public final class SafePlanExecutor: PlanExecutor, @unchecked Sendable {
  private let workspace: Workspace
  private let database: AppDatabase
  private let fileManager: FileManager
  private let cancellation = ExecutorCancellation()

  public init(workspace: Workspace, database: AppDatabase, fileManager: FileManager = .default) {
    self.workspace = workspace
    self.database = database
    self.fileManager = fileManager
  }

  public func cancel() { cancellation.cancel() }

  public func preflight(
    _ plan: OrganizationPlan,
    progress: @escaping OrganizationProgressHandler
  ) async -> PreflightReport {
    var issues: [PreflightIssue] = []
    let inbox = URL(fileURLWithPath: workspace.inboxPath, isDirectory: true)
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let plannedDirectories = Set(
      plan.operations.filter { $0.kind == .createDirectory }.map(\.destinationPath))
    let persistedStates = (try? database.operationStates(planID: plan.id)) ?? [:]
    var destinations: Set<String> = []

    await progress(
      OrganizationProgress(
        phase: .preflighting,
        total: plan.operations.count,
        isCancellable: false
      ))
    for (index, operation) in plan.operations.enumerated() {
      if index > 0 {
        await progress(
          OrganizationProgress(
            phase: .preflighting,
            completed: index,
            total: plan.operations.count,
            isCancellable: false
          ))
      }
      let destination = URL(fileURLWithPath: operation.destinationPath)
      let destinationIsAllowed = operation.kind == .rename
        ? PathSafety.isDirectChild(destination, of: inbox)
        : PathSafety.contains(library, destination)
      guard destinationIsAllowed else {
        let message = operation.kind == .rename ? "改名目标必须位于收件箱直接子项" : "目标超出资料库：\(destination.path)"
        issues.append(.init(operationID: operation.id, message: message))
        continue
      }
      if !destinations.insert(PathSafety.normalizedCollisionKey(destination)).inserted {
        issues.append(
          .init(operationID: operation.id, message: "计划内存在重复目标：\(destination.lastPathComponent)"))
      }
      switch operation.kind {
      case .createDirectory:
        let isOwned = DirectoryOwnership.isOwned(
          destination, by: operation, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path), !isOwned {
          issues.append(
            .init(operationID: operation.id, message: "建议目录已经存在：\(destination.lastPathComponent)"))
        }
        if destination.deletingLastPathComponent() != PathSafety.normalized(library) {
          issues.append(.init(operationID: operation.id, message: "只能创建资料库第一级目录"))
        }
      case .move:
        guard let sourcePath = operation.sourcePath else {
          issues.append(.init(operationID: operation.id, message: "移动操作缺少源文件"))
          continue
        }
        let source = URL(fileURLWithPath: sourcePath)
        if !PathSafety.isDirectChild(source, of: inbox) {
          issues.append(.init(operationID: operation.id, message: "源文件不是收件箱直接子项"))
        }
        let isRecoveredMove =
          !fileManager.fileExists(atPath: source.path)
          && operation.preSnapshot?.matches(destination) == true
          && (persistedStates[operation.id] == .running
            || persistedStates[operation.id] == .completed)
        if (fileManager.fileExists(atPath: destination.path)
          || hasSiblingCollision(at: destination, excluding: source)), !isRecoveredMove
        {
          issues.append(
            .init(operationID: operation.id, message: "目标已存在：\(destination.lastPathComponent)"))
        }
        let parent = destination.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: parent, isDirectory: &isDirectory)
          && !plannedDirectories.contains(parent)
        {
          issues.append(.init(operationID: operation.id, message: "目标目录不存在"))
        } else if fileManager.fileExists(atPath: parent, isDirectory: &isDirectory)
          && !isDirectory.boolValue
        {
          issues.append(.init(operationID: operation.id, message: "目标父路径不是目录"))
        }
        guard let snapshot = operation.preSnapshot, snapshot.matches(source) || isRecoveredMove
        else {
          issues.append(.init(operationID: operation.id, message: "源文件在方案生成后发生变化"))
          continue
        }
        if snapshot.volumeIdentifier != workspace.inboxVolumeID
          || snapshot.volumeIdentifier != workspace.libraryVolumeID
        {
          issues.append(.init(operationID: operation.id, message: "V2.0 不支持跨卷移动"))
        }
      case .rename:
        guard let sourcePath = operation.sourcePath else {
          issues.append(.init(operationID: operation.id, message: "改名操作缺少源文件"))
          continue
        }
        let source = URL(fileURLWithPath: sourcePath)
        if !PathSafety.isDirectChild(source, of: inbox) {
          issues.append(.init(operationID: operation.id, message: "源文件不是收件箱直接子项"))
        }
        let isRecoveredRename =
          !fileManager.fileExists(atPath: source.path)
          && operation.preSnapshot?.matches(destination) == true
          && (persistedStates[operation.id] == .running
            || persistedStates[operation.id] == .completed)
        if (fileManager.fileExists(atPath: destination.path)
          || hasSiblingCollision(at: destination, excluding: source)), !isRecoveredRename
        {
          issues.append(.init(operationID: operation.id, message: "目标已存在：\(destination.lastPathComponent)"))
        }
        guard let snapshot = operation.preSnapshot,
          snapshot.matches(source) || isRecoveredRename
        else {
          issues.append(.init(operationID: operation.id, message: "源文件在方案生成后发生变化"))
          continue
        }
        if snapshot.volumeIdentifier != workspace.inboxVolumeID {
          issues.append(.init(operationID: operation.id, message: "改名操作必须保持在同一卷"))
        }
      }
    }
    await progress(
      OrganizationProgress(
        phase: .preflighting,
        completed: plan.operations.count,
        total: plan.operations.count,
        failed: Set(issues.map(\.operationID)).count,
        isCancellable: false
      ))
    return PreflightReport(issues: issues)
  }

  public func execute(_ plan: OrganizationPlan) -> AsyncThrowingStream<ExecutionEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) { [self] in
        var results: [OperationResult] = []
        do {
          try database.savePlan(plan)
          let report = await preflight(plan)
          guard report.isReady else {
            throw OrganizerError.planBlocked(report.issues.map(\.message))
          }
          continuation.yield(.started(total: plan.operations.count))
          let existingStates = try database.operationStates(planID: plan.id)
          for operation in plan.operations {
            if cancellation.isCancelled { throw CancellationError() }
            try Task.checkCancellation()
            continuation.yield(.operationStarted(operation))
            if existingStates[operation.id] == .completed {
              let result = OperationResult(operationID: operation.id, state: .completed)
              results.append(result)
              try database.finishOperation(
                operation.id,
                state: .completed,
                learningSample: learningSample(for: operation, sessionID: plan.sessionID),
                namingSample: namingSample(for: operation, sessionID: plan.sessionID)
              )
              continuation.yield(.operationFinished(result))
              continue
            }
            try database.updateOperation(operation.id, state: .running)
            let result = apply(operation)
            try database.finishOperation(
              operation.id,
              state: result.state,
              error: result.error,
              learningSample: result.state == .completed
                ? learningSample(for: operation, sessionID: plan.sessionID) : nil,
              namingSample: result.state == .completed
                ? namingSample(for: operation, sessionID: plan.sessionID) : nil
            )
            results.append(result)
            try database.saveReceipt(
              ExecutionReceipt(planID: plan.id, results: results, isFinal: false))
            continuation.yield(.operationFinished(result))
          }
          let receipt = ExecutionReceipt(planID: plan.id, results: results)
          try database.saveReceipt(receipt)
          continuation.yield(.finished(receipt))
          continuation.finish()
        } catch is CancellationError {
          let receipt = ExecutionReceipt(planID: plan.id, results: results, wasCancelled: true)
          do {
            try database.saveReceipt(receipt)
            continuation.yield(.finished(receipt))
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { [cancellation] termination in
        if case .cancelled = termination {
          cancellation.cancel()
          task.cancel()
        }
      }
    }
  }

  public func undo(plan: OrganizationPlan, receipt: ExecutionReceipt) -> AsyncThrowingStream<
    ExecutionEvent, Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) { [self] in
        let retryable = Set(receipt.results.filter {
          $0.state == .completed || (receipt.isUndoReceipt && $0.state == .blocked)
        }.map(\.operationID))
        var results: [OperationResult] = []
        continuation.yield(.started(total: retryable.count))
        do {
          for operation in plan.operations.reversed() where retryable.contains(operation.id) {
            if cancellation.isCancelled { throw CancellationError() }
            try Task.checkCancellation()
            continuation.yield(.operationStarted(operation))
            try database.updateOperation(operation.id, state: .undoing)
            let result = revert(operation)
            try database.finishUndoOperation(operation.id, result: result)
            results.append(result)
            continuation.yield(.operationFinished(result))
          }
          let undoReceipt = mergedUndoReceipt(
            original: receipt, updates: results, wasCancelled: false)
          try database.saveReceipt(undoReceipt)
          continuation.yield(.finished(undoReceipt))
          continuation.finish()
        } catch is CancellationError {
          let undoReceipt = mergedUndoReceipt(
            original: receipt, updates: results, wasCancelled: true)
          do {
            try database.saveReceipt(undoReceipt)
            continuation.yield(.finished(undoReceipt))
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { [cancellation] termination in
        if case .cancelled = termination {
          cancellation.cancel()
          task.cancel()
        }
      }
    }
  }

  private func mergedUndoReceipt(
    original: ExecutionReceipt,
    updates: [OperationResult],
    wasCancelled: Bool
  ) -> ExecutionReceipt {
    let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.operationID, $0) })
    var merged = original.results.map { updatesByID[$0.operationID] ?? $0 }
    let existing = Set(merged.map(\.operationID))
    merged.append(contentsOf: updates.filter { !existing.contains($0.operationID) })
    return ExecutionReceipt(
      planID: original.planID,
      results: merged,
      wasCancelled: wasCancelled,
      isUndoReceipt: true
    )
  }

  private func apply(_ operation: PlannedOperation) -> OperationResult {
    do {
      switch operation.kind {
      case .createDirectory:
        do {
          try DirectoryOwnership.install(operation, fileManager: fileManager)
        } catch {
          let destination = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
          if fileManager.fileExists(atPath: destination.path),
            !DirectoryOwnership.isOwned(destination, by: operation, fileManager: fileManager)
          {
            return .init(operationID: operation.id, state: .blocked, error: "目录已经存在，未取得所有权")
          }
          return .init(operationID: operation.id, state: .failed, error: error.localizedDescription)
        }
      case .move, .rename:
        guard let sourcePath = operation.sourcePath else {
          return .init(operationID: operation.id, state: .failed, error: "缺少源文件")
        }
        let source = URL(fileURLWithPath: sourcePath)
        let destination = URL(fileURLWithPath: operation.destinationPath)
        if !fileManager.fileExists(atPath: source.path),
          let snapshot = operation.preSnapshot, snapshot.matches(destination)
        {
          return .init(operationID: operation.id, state: .completed)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
          return .init(operationID: operation.id, state: .blocked, error: "目标已存在")
        }
        guard let snapshot = operation.preSnapshot, snapshot.matches(source) else {
          return .init(operationID: operation.id, state: .blocked, error: "源文件在移动前发生变化")
        }
        try fileManager.moveItem(at: source, to: destination)
      }
      return .init(operationID: operation.id, state: .completed)
    } catch {
      return .init(operationID: operation.id, state: .failed, error: error.localizedDescription)
    }
  }

  private func learningSample(for operation: PlannedOperation, sessionID: UUID) -> LearningSample? {
    guard operation.kind == .move,
      let destinationID = operation.destinationID,
      let features = operation.decisionFeatures,
      let confirmation = operation.learningConfirmation
    else { return nil }
    let identity = operation.preSnapshot?.resourceIdentifier
      ?? operation.itemID?.uuidString
      ?? operation.sourcePath
      ?? operation.id.uuidString
    return LearningSample(
      libraryID: workspace.id,
      sessionID: sessionID,
      operationID: operation.id,
      itemIdentity: identity,
      destinationID: destinationID,
      features: features,
      confirmation: confirmation
    )
  }

  private func namingSample(for operation: PlannedOperation, sessionID: UUID) -> NamingSample? {
    guard let features = operation.namingDecisionFeatures,
      let source = operation.namingSampleSource
    else { return nil }
    let identity = operation.preSnapshot?.resourceIdentifier
      ?? operation.itemID?.uuidString
      ?? operation.sourcePath
      ?? operation.id.uuidString
    return NamingSample(
      workspaceID: workspace.id,
      sessionID: sessionID,
      operationID: operation.id,
      itemIdentity: identity,
      destinationID: operation.destinationID,
      source: source,
      features: features)
  }

  private func revert(_ operation: PlannedOperation) -> OperationResult {
    do {
      switch operation.kind {
      case .move, .rename:
        guard let sourcePath = operation.sourcePath else {
          return .init(operationID: operation.id, state: .blocked, error: "缺少原始位置")
        }
        let original = URL(fileURLWithPath: sourcePath)
        let current = URL(fileURLWithPath: operation.destinationPath)
        guard !fileManager.fileExists(atPath: original.path) else {
          return .init(operationID: operation.id, state: .blocked, error: "原始位置已被占用")
        }
        guard let snapshot = operation.preSnapshot, snapshot.matches(current) else {
          return .init(operationID: operation.id, state: .blocked, error: "目标文件已被修改或缺失")
        }
        try fileManager.moveItem(at: current, to: original)
      case .createDirectory:
        let directory = URL(fileURLWithPath: operation.destinationPath, isDirectory: true)
        guard operation.createdByApp else {
          return .init(operationID: operation.id, state: .blocked, error: "目录不是由本应用创建")
        }
        try DirectoryOwnership.removeIfOwned(directory, by: operation, fileManager: fileManager)
      }
      return .init(operationID: operation.id, state: .undone)
    } catch {
      return .init(operationID: operation.id, state: .blocked, error: error.localizedDescription)
    }
  }

  private func hasSiblingCollision(at destination: URL, excluding source: URL) -> Bool {
    let parent = destination.deletingLastPathComponent()
    guard let children = try? fileManager.contentsOfDirectory(
      at: parent, includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    else { return false }
    let desired = PathSafety.normalizedCollisionKey(destination.lastPathComponent)
    let sourcePath = PathSafety.normalized(source).path
    return children.contains {
      PathSafety.normalized($0).path != sourcePath
        && PathSafety.normalizedCollisionKey($0.lastPathComponent) == desired
    }
  }
}

private final class ExecutorCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
}
