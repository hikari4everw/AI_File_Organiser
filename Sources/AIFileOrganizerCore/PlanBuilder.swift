import Foundation

public struct PlanBuilder: Sendable {
  public init() {}

  public func build(
    sessionID: UUID,
    workspace: Workspace,
    items: [ItemSnapshot],
    destinations: [DestinationProfile],
    proposals: [ClassificationProposal],
    folderProposals: [FolderProposal]
  ) throws -> OrganizationPlan {
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let destinationsByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
    var operations: [PlannedOperation] = []
    var handledItems: Set<UUID> = []
    var sequence = 0

    let approvedFolders = folderProposals.filter { $0.status == .approved }
    for folder in approvedFolders {
      let name = try PathSafety.validateFolderName(folder.displayName)
      let destination = try PathSafety.safeDestination(library: library, relativePath: name)
      let eligibleItemIDs = folder.relatedItemIDs.filter { itemID in
        guard itemsByID[itemID] != nil, !handledItems.contains(itemID),
          let itemProposal = proposals.first(where: { $0.itemID == itemID })
        else { return false }
        return itemProposal.action == .suggestFolder
          && PathSafety.normalizedFolderKey(itemProposal.suggestedFolderName ?? "")
            == folder.normalizedName
      }
      guard !eligibleItemIDs.isEmpty else { continue }
      operations.append(
        PlannedOperation(
          sequence: sequence,
          kind: .createDirectory,
          destinationPath: destination.path,
          createdByApp: true
        ))
      sequence += 1
      for itemID in eligibleItemIDs {
        guard let item = itemsByID[itemID] else { continue }
        operations.append(
          try moveOperation(
            item: item,
            destinationDirectory: destination,
            sequence: sequence,
            destinationID: DestinationIndexer().identifier(for: name),
            confirmation: .userApproved
          ))
        sequence += 1
        handledItems.insert(itemID)
      }
    }

    for proposal in proposals {
      guard proposal.action == .move, !handledItems.contains(proposal.itemID) else { continue }
      let isAccepted =
        proposal.reviewDecision == .ready || proposal.status == .approved
        || proposal.status == .overridden
      guard isAccepted, let destinationID = proposal.destinationID,
        let destination = destinationsByID[destinationID], let item = itemsByID[proposal.itemID]
      else { continue }
      let directory = try PathSafety.safeDestination(
        library: library, relativePath: destination.relativePath)
      operations.append(
        try moveOperation(
          item: item,
          destinationDirectory: directory,
          sequence: sequence,
          destinationID: destinationID,
          confirmation: proposal.source == .user || proposal.status == .approved
            || proposal.status == .overridden ? .userApproved : .acceptedSuggestion
        ))
      sequence += 1
      handledItems.insert(item.id)
    }

    return OrganizationPlan(sessionID: sessionID, operations: operations)
  }

  private func moveOperation(
    item: ItemSnapshot,
    destinationDirectory: URL,
    sequence: Int,
    destinationID: UUID? = nil,
    confirmation: LearningConfirmation? = nil
  ) throws
    -> PlannedOperation
  {
    let source = URL(fileURLWithPath: item.path)
    let snapshot = try FileSnapshot.capture(source)
    return PlannedOperation(
      sequence: sequence,
      kind: .move,
      sourcePath: source.path,
      destinationPath: destinationDirectory.appendingPathComponent(item.name).path,
      itemID: item.id,
      preSnapshot: snapshot,
      destinationID: destinationID,
      decisionFeatures: DecisionFeatures(
        itemKind: item.kind,
        fileExtension: item.fileExtension,
        keywords: KeywordTokenizer.tokens(from: item.name)
      ),
      learningConfirmation: confirmation
    )
  }
}

extension FileSnapshot {
  public static func capture(_ url: URL) throws -> FileSnapshot {
    let currentURL = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    let values = try currentURL.resourceValues(forKeys: [
      .fileResourceIdentifierKey, .volumeIdentifierKey, .fileSizeKey,
      .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
    ])
    let manifest = values.isDirectory == true && values.isPackage != true
      ? try DirectoryManifest.capture(currentURL)
      : nil
    return FileSnapshot(
      resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
      volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) },
      size: Int64(values.fileSize ?? 0),
      modificationDate: values.contentModificationDate,
      directoryManifest: manifest
    )
  }

  public func matches(_ url: URL) -> Bool {
    guard formatVersion >= 2 else { return false }
    guard let current = try? FileSnapshot.capture(url) else { return false }
    if let resourceIdentifier, let currentID = current.resourceIdentifier,
      resourceIdentifier != currentID
    {
      return false
    }
    if let volumeIdentifier, let currentVolume = current.volumeIdentifier,
      volumeIdentifier != currentVolume
    {
      return false
    }
    guard size == current.size else { return false }
    let dateMatches: Bool
    switch (modificationDate, current.modificationDate) {
    case (nil, nil): dateMatches = true
    case (let lhs?, let rhs?): dateMatches = lhs == rhs
    default: dateMatches = false
    }
    guard dateMatches else { return false }
    if let directoryManifest { return directoryManifest.matches(url) }
    return true
  }
}
