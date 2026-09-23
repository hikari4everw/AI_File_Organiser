import Foundation

public struct PlanBuilder: Sendable {
  public init() {}

  public func build(
    sessionID: UUID,
    workspace: Workspace,
    items: [ItemSnapshot],
    destinations: [DestinationProfile],
    proposals: [ClassificationProposal],
    folderProposals: [FolderProposal],
    renameProposals: [RenameProposal] = [],
    selectedSourceIDs: Set<UUID> = [],
    catalogRevision: String? = nil
  ) throws -> OrganizationPlan {
    let library = URL(fileURLWithPath: workspace.libraryPath, isDirectory: true)
    let inbox = URL(fileURLWithPath: workspace.inboxPath, isDirectory: true)
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let destinationsByID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
    let renamesByItem = Dictionary(uniqueKeysWithValues: renameProposals.compactMap { proposal in
      proposal.selectedBaseName == nil ? nil : (proposal.itemID, proposal)
    })
    var operations: [PlannedOperation] = []
    var handledItems: Set<UUID> = []
    var sequence = 0

    let approvedFolders = folderProposals.filter { $0.status == .approved }
    for folder in approvedFolders {
      let name = try PathSafety.validateFolderName(folder.displayName)
      let parent = folder.parentDestinationID.flatMap { destinationsByID[$0] }
      if folder.parentDestinationID != nil && (parent == nil || parent?.kind != .category) {
        throw OrganizerError.invalidWorkspace("作者目录的父分类不存在")
      }
      let relative = parent.map { $0.relativePath + "/" + name } ?? name
      let destination = try PathSafety.safeDestination(library: library, relativePath: relative)
      let eligibleItemIDs = folder.relatedItemIDs.filter { itemID in
        guard let item = itemsByID[itemID], !handledItems.contains(itemID),
          sourceAllowed(item, inbox: inbox, library: library,
            selectedSourceIDs: selectedSourceIDs),
          let itemProposal = proposals.first(where: { $0.itemID == itemID })
        else { return false }
        let matchesAction = parent == nil
          ? itemProposal.action == .suggestFolder
          : itemProposal.action == .move && itemProposal.destinationID == parent?.id
        return matchesAction
          && PathSafety.normalizedFolderKey(itemProposal.suggestedFolderName ?? "")
            == folder.normalizedName
      }
      guard !eligibleItemIDs.isEmpty else { continue }
      operations.append(
        PlannedOperation(
          sequence: sequence,
          kind: .createDirectory,
          destinationPath: destination.path,
          createdByApp: true,
          destinationID: parent?.id
        ))
      sequence += 1
      for itemID in eligibleItemIDs {
        guard let item = itemsByID[itemID] else { continue }
        operations.append(
          try moveOperation(
            item: item,
            destinationDirectory: destination,
            sequence: sequence,
            destinationID: parent?.id ?? DestinationIndexer().identifier(for: name),
            confirmation: .userApproved,
            rename: renamesByItem[item.id]
          ))
        sequence += 1
        handledItems.insert(itemID)
      }
    }

    for proposal in proposals {
      guard proposal.action == .move, !handledItems.contains(proposal.itemID),
        proposal.suggestedFolderName == nil else { continue }
      let isAccepted =
        proposal.reviewDecision == .ready || proposal.status == .approved
        || proposal.status == .overridden
      guard isAccepted, let destinationID = proposal.destinationID,
        let destination = destinationsByID[destinationID], let item = itemsByID[proposal.itemID]
      else { continue }
      guard sourceAllowed(item, inbox: inbox, library: library,
        selectedSourceIDs: selectedSourceIDs) else { continue }
      let relativePath: String
      if let creatorPath = proposal.creatorDestinationPath {
        guard creatorPath.hasPrefix(destination.relativePath + "/"),
          !creatorPath.dropFirst(destination.relativePath.count + 1).contains("/")
        else { throw OrganizerError.invalidWorkspace("作者目录不属于所选分类") }
        relativePath = creatorPath
      } else {
        relativePath = destination.relativePath
      }
      let directory = try PathSafety.safeDestination(
        library: library, relativePath: relativePath)
      let finalName: String
      if let baseName = renamesByItem[item.id]?.selectedBaseName {
        finalName = try FilenameValidator().validatedFullName(baseName: baseName, item: item)
      } else {
        finalName = item.name
      }
      if PathSafety.normalized(URL(fileURLWithPath: item.path))
        == PathSafety.normalized(directory.appendingPathComponent(finalName))
      { continue }
      operations.append(
        try moveOperation(
          item: item,
          destinationDirectory: directory,
          sequence: sequence,
          destinationID: destinationID,
          confirmation: proposal.source == .user || proposal.status == .approved
            || proposal.status == .overridden ? .userApproved : .acceptedSuggestion,
          rename: renamesByItem[item.id]
        ))
      sequence += 1
      handledItems.insert(item.id)
    }

    for item in items where !handledItems.contains(item.id) {
      guard PathSafety.isDirectChild(URL(fileURLWithPath: item.path), of: inbox) else { continue }
      guard sourceAllowed(item, inbox: inbox, library: library,
        selectedSourceIDs: selectedSourceIDs) else { continue }
      guard let rename = renamesByItem[item.id], let baseName = rename.selectedBaseName else {
        continue
      }
      let fullName = try FilenameValidator().validatedFullName(baseName: baseName, item: item)
      guard PathSafety.normalizedCollisionKey(fullName) != PathSafety.normalizedCollisionKey(item.name)
      else { continue }
      let source = URL(fileURLWithPath: item.path)
      let destination = source.deletingLastPathComponent().appendingPathComponent(fullName)
      let operationID = UUID()
      operations.append(PlannedOperation(
        id: operationID,
        sequence: sequence,
        kind: .rename,
        sourcePath: source.path,
        destinationPath: destination.path,
        itemID: item.id,
        preSnapshot: try FileSnapshot.capture(source),
        namingDecisionFeatures: namingFeatures(item: item, fullName: fullName, rename: rename),
        namingSampleSource: namingSource(rename)
      ))
      sequence += 1
    }

    let sources = operations.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0) }
    for left in sources.indices {
      for right in sources.indices where left < right {
        if PathSafety.contains(sources[left], sources[right])
          || PathSafety.contains(sources[right], sources[left])
        { throw OrganizerError.invalidWorkspace("不能同时选择父目录和其中的作品") }
      }
    }
    let reviewed = sources.filter { !PathSafety.isDirectChild($0, of: inbox) }.map(\.path)
    return OrganizationPlan(sessionID: sessionID, operations: operations,
      reviewedSourcePaths: reviewed, catalogRevision: catalogRevision)
  }

  private func sourceAllowed(
    _ item: ItemSnapshot, inbox: URL, library: URL,
    selectedSourceIDs: Set<UUID>
  ) -> Bool {
    let source = URL(fileURLWithPath: item.path)
    guard !item.isSymbolicLink else { return false }
    if PathSafety.isDirectChild(source, of: inbox) { return true }
    return selectedSourceIDs.contains(item.id)
      && (PathSafety.contains(inbox, source) || PathSafety.contains(library, source))
  }

  private func moveOperation(
    item: ItemSnapshot,
    destinationDirectory: URL,
    sequence: Int,
    destinationID: UUID? = nil,
    confirmation: LearningConfirmation? = nil,
    rename: RenameProposal? = nil
  ) throws
    -> PlannedOperation
  {
    let source = URL(fileURLWithPath: item.path)
    let snapshot = try FileSnapshot.capture(source)
    let fullName: String
    if let rename, let baseName = rename.selectedBaseName {
      fullName = try FilenameValidator().validatedFullName(baseName: baseName, item: item)
    } else {
      fullName = item.name
    }
    return PlannedOperation(
      sequence: sequence,
      kind: .move,
      sourcePath: source.path,
      destinationPath: destinationDirectory.appendingPathComponent(fullName).path,
      itemID: item.id,
      preSnapshot: snapshot,
      destinationID: destinationID,
      decisionFeatures: DecisionFeatures(
        itemKind: item.kind,
        fileExtension: item.fileExtension,
        keywords: KeywordTokenizer.tokens(from: item.name)
      ),
      learningConfirmation: confirmation,
      namingDecisionFeatures: rename.map { namingFeatures(item: item, fullName: fullName, rename: $0) },
      namingSampleSource: rename.map(namingSource)
    )
  }

  private func namingFeatures(
    item: ItemSnapshot, fullName: String, rename: RenameProposal
  ) -> NamingDecisionFeatures {
    let originalBase = item.kind == .file
      ? URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent : item.name
    let finalBase = item.kind == .file
      ? URL(fileURLWithPath: fullName).deletingPathExtension().lastPathComponent : fullName
    return NamingDecisionFeatures(
      itemKind: item.kind,
      fileExtension: item.fileExtension,
      originalBaseName: originalBase,
      finalBaseName: finalBase,
      templatePattern: rename.templatePattern)
  }

  private func namingSource(_ rename: RenameProposal) -> NamingSampleSource {
    switch rename.source {
    case .namingRule: .namingRule
    case .foundationModel: .acceptedSuggestion
    case .user: .userApproved
    }
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
