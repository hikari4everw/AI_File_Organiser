import Foundation

public enum SessionState: String, Codable, Sendable {
  case idle, scanning, proposing, review, preflighting, executing, completed, partial, cancelled,
    failed
}

public enum ItemKind: String, Codable, Sendable {
  case file, directory, applicationBundle
}

public enum DestinationKind: String, Codable, Hashable, Sendable {
  case category, collection, uncertain, excluded
}

public enum ProposalSource: String, Codable, Sendable {
  case deterministic, foundationModel, user
}

public enum ReviewDecision: String, Codable, Sendable {
  case ready, needsReview, keep
}

public enum ProposalAction: String, Codable, Sendable {
  case move, keep, suggestFolder
}

public enum ProposalStatus: String, Codable, Sendable {
  case pending, approved, rejected, overridden
}

public enum FolderProposalStatus: String, Codable, Sendable {
  case pending, approved, rejected
}

public enum OperationKind: String, Codable, Sendable {
  case createDirectory, move, rename
}

public enum OperationState: String, Codable, Sendable {
  case pending, running, completed, undoing, failed, undone, blocked, undoBlocked
}

public struct Workspace: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var inboxPath: String
  public var libraryPath: String
  public var inboxBookmark: Data
  public var libraryBookmark: Data
  public var inboxVolumeID: String
  public var libraryVolumeID: String
  public var pinnedDestinationPaths: [String]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    inboxPath: String,
    libraryPath: String,
    inboxBookmark: Data = Data(),
    libraryBookmark: Data = Data(),
    inboxVolumeID: String,
    libraryVolumeID: String,
    pinnedDestinationPaths: [String] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.inboxPath = inboxPath
    self.libraryPath = libraryPath
    self.inboxBookmark = inboxBookmark
    self.libraryBookmark = libraryBookmark
    self.inboxVolumeID = inboxVolumeID
    self.libraryVolumeID = libraryVolumeID
    self.pinnedDestinationPaths = pinnedDestinationPaths
    self.createdAt = createdAt
  }
}

public struct OrganizationSession: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var workspaceID: UUID
  public var state: SessionState
  public var startedAt: Date
  public var finishedAt: Date?
  public var errorMessage: String?

  public init(
    id: UUID = UUID(),
    workspaceID: UUID,
    state: SessionState = .idle,
    startedAt: Date = Date(),
    finishedAt: Date? = nil,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.workspaceID = workspaceID
    self.state = state
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.errorMessage = errorMessage
  }
}

public struct ItemSnapshot: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var path: String
  public var name: String
  public var kind: ItemKind
  public var contentType: String?
  public var fileExtension: String
  public var size: Int64
  public var creationDate: Date?
  public var modificationDate: Date?
  public var resourceIdentifier: String?
  public var volumeIdentifier: String?
  public var isHidden: Bool
  public var isSymbolicLink: Bool
  public var isCloudPlaceholder: Bool
  public var shallowExtensions: [String]

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    path: String,
    name: String,
    kind: ItemKind,
    contentType: String? = nil,
    fileExtension: String = "",
    size: Int64 = 0,
    creationDate: Date? = nil,
    modificationDate: Date? = nil,
    resourceIdentifier: String? = nil,
    volumeIdentifier: String? = nil,
    isHidden: Bool = false,
    isSymbolicLink: Bool = false,
    isCloudPlaceholder: Bool = false,
    shallowExtensions: [String] = []
  ) {
    self.id = id
    self.sessionID = sessionID
    self.path = path
    self.name = name
    self.kind = kind
    self.contentType = contentType
    self.fileExtension = fileExtension
    self.size = size
    self.creationDate = creationDate
    self.modificationDate = modificationDate
    self.resourceIdentifier = resourceIdentifier
    self.volumeIdentifier = volumeIdentifier
    self.isHidden = isHidden
    self.isSymbolicLink = isSymbolicLink
    self.isCloudPlaceholder = isCloudPlaceholder
    self.shallowExtensions = shallowExtensions
  }
}

public enum ContentExtractionStatus: String, Codable, Hashable, Sendable {
  case success, noText, unsupported, unreadable, cloudPlaceholder, cancelled, notNeeded
}

public struct ExtractedContext: Codable, Hashable, Sendable {
  public var text: String
  public var source: String
  public var wasTruncated: Bool
  public var status: ContentExtractionStatus

  public init(
    text: String = "",
    source: String = "none",
    wasTruncated: Bool = false,
    status: ContentExtractionStatus = .notNeeded
  ) {
    self.text = text
    self.source = source
    self.wasTruncated = wasTruncated
    self.status = status
  }
}

public struct DirectorySummary: Codable, Hashable, Sendable {
  public var inspectedCount: Int
  public var fileCount: Int
  public var directoryCount: Int
  public var extensionCounts: [String: Int]
  public var representativeFiles: [String]
  public var hasSequentialNames: Bool
  public var wasTruncated: Bool

  public init(
    inspectedCount: Int = 0,
    fileCount: Int = 0,
    directoryCount: Int = 0,
    extensionCounts: [String: Int] = [:],
    representativeFiles: [String] = [],
    hasSequentialNames: Bool = false,
    wasTruncated: Bool = false
  ) {
    self.inspectedCount = inspectedCount
    self.fileCount = fileCount
    self.directoryCount = directoryCount
    self.extensionCounts = extensionCounts
    self.representativeFiles = representativeFiles
    self.hasSequentialNames = hasSequentialNames
    self.wasTruncated = wasTruncated
  }
}

public struct ItemContext: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID { snapshot.id }
  public var snapshot: ItemSnapshot
  public var normalizedKeywords: [String]
  public var extracted: ExtractedContext
  public var spotlightTitle: String?
  public var spotlightAuthors: [String]
  public var spotlightContentType: String?
  public var directorySummary: DirectorySummary?
  public var ruleHints: [String]

  public init(
    snapshot: ItemSnapshot,
    normalizedKeywords: [String],
    extracted: ExtractedContext = .init(),
    spotlightTitle: String? = nil,
    spotlightAuthors: [String] = [],
    spotlightContentType: String? = nil,
    directorySummary: DirectorySummary? = nil,
    ruleHints: [String] = []
  ) {
    self.snapshot = snapshot
    self.normalizedKeywords = normalizedKeywords
    self.extracted = extracted
    self.spotlightTitle = spotlightTitle
    self.spotlightAuthors = spotlightAuthors
    self.spotlightContentType = spotlightContentType
    self.directorySummary = directorySummary
    self.ruleHints = ruleHints
  }
}

public struct DestinationProfile: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var relativePath: String
  public var displayName: String
  public var keywords: [String]
  public var sampleContentTypes: [String]
  public var isPinned: Bool
  public var kind: DestinationKind
  public var depth: Int

  public init(
    id: UUID = UUID(),
    relativePath: String,
    displayName: String,
    keywords: [String] = [],
    sampleContentTypes: [String] = [],
    isPinned: Bool = false,
    kind: DestinationKind = .category,
    depth: Int = 1
  ) {
    self.id = id
    self.relativePath = relativePath
    self.displayName = displayName
    self.keywords = keywords
    self.sampleContentTypes = sampleContentTypes
    self.isPinned = isPinned
    self.kind = kind
    self.depth = max(1, depth)
  }
}

public struct Evidence: Codable, Hashable, Sendable {
  public var kind: String
  public var detail: String
  public var weight: Double

  public init(kind: String, detail: String, weight: Double) {
    self.kind = kind
    self.detail = detail
    self.weight = weight
  }
}

public struct RankedCandidate: Codable, Hashable, Sendable {
  public var destinationID: UUID
  public var score: Double
  public var evidence: [Evidence]

  public init(destinationID: UUID, score: Double, evidence: [Evidence]) {
    self.destinationID = destinationID
    self.score = score
    self.evidence = evidence
  }
}

public struct ModelProposal: Codable, Hashable, Sendable {
  public var itemID: UUID
  public var action: ProposalAction
  public var destinationID: UUID?
  public var suggestedFolderName: String?
  public var reason: String

  public init(
    itemID: UUID,
    action: ProposalAction,
    destinationID: UUID? = nil,
    suggestedFolderName: String? = nil,
    reason: String
  ) {
    self.itemID = itemID
    self.action = action
    self.destinationID = destinationID
    self.suggestedFolderName = suggestedFolderName
    self.reason = reason
  }
}

public struct ClassificationProposal: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var itemID: UUID
  public var action: ProposalAction
  public var destinationID: UUID?
  public var suggestedFolderName: String?
  public var source: ProposalSource
  public var reviewDecision: ReviewDecision
  public var status: ProposalStatus
  public var reason: String
  public var evidence: [Evidence]
  public var topCandidates: [RankedCandidate]
  public var catalogRevision: String?
  public var creatorID: UUID?
  public var creatorDestinationPath: String?

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    itemID: UUID,
    action: ProposalAction,
    destinationID: UUID? = nil,
    suggestedFolderName: String? = nil,
    source: ProposalSource,
    reviewDecision: ReviewDecision,
    status: ProposalStatus = .pending,
    reason: String,
    evidence: [Evidence] = [], topCandidates: [RankedCandidate] = [],
    catalogRevision: String? = nil, creatorID: UUID? = nil,
    creatorDestinationPath: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.itemID = itemID
    self.action = action
    self.destinationID = destinationID
    self.suggestedFolderName = suggestedFolderName
    self.source = source
    self.reviewDecision = reviewDecision
    self.status = status
    self.reason = reason
    self.evidence = evidence
    self.topCandidates = topCandidates
    self.catalogRevision = catalogRevision
    self.creatorID = creatorID
    self.creatorDestinationPath = creatorDestinationPath
  }

  private enum CodingKeys: String, CodingKey {
    case id, sessionID, itemID, action, destinationID, suggestedFolderName, source,
      reviewDecision, status, reason, evidence, topCandidates, catalogRevision,
      creatorID, creatorDestinationPath
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    id = try value.decode(UUID.self, forKey: .id)
    sessionID = try value.decode(UUID.self, forKey: .sessionID)
    itemID = try value.decode(UUID.self, forKey: .itemID)
    action = try value.decode(ProposalAction.self, forKey: .action)
    destinationID = try value.decodeIfPresent(UUID.self, forKey: .destinationID)
    suggestedFolderName = try value.decodeIfPresent(String.self, forKey: .suggestedFolderName)
    source = try value.decode(ProposalSource.self, forKey: .source)
    reviewDecision = try value.decode(ReviewDecision.self, forKey: .reviewDecision)
    status = try value.decode(ProposalStatus.self, forKey: .status)
    reason = try value.decode(String.self, forKey: .reason)
    evidence = try value.decode([Evidence].self, forKey: .evidence)
    topCandidates = try value.decodeIfPresent([RankedCandidate].self, forKey: .topCandidates) ?? []
    catalogRevision = try value.decodeIfPresent(String.self, forKey: .catalogRevision)
    creatorID = try value.decodeIfPresent(UUID.self, forKey: .creatorID)
    creatorDestinationPath = try value.decodeIfPresent(String.self, forKey: .creatorDestinationPath)
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.container(keyedBy: CodingKeys.self)
    try value.encode(id, forKey: .id)
    try value.encode(sessionID, forKey: .sessionID)
    try value.encode(itemID, forKey: .itemID)
    try value.encode(action, forKey: .action)
    try value.encodeIfPresent(destinationID, forKey: .destinationID)
    try value.encodeIfPresent(suggestedFolderName, forKey: .suggestedFolderName)
    try value.encode(source, forKey: .source)
    try value.encode(reviewDecision, forKey: .reviewDecision)
    try value.encode(status, forKey: .status)
    try value.encode(reason, forKey: .reason)
    try value.encode(evidence, forKey: .evidence)
    try value.encode(topCandidates, forKey: .topCandidates)
    try value.encodeIfPresent(catalogRevision, forKey: .catalogRevision)
    try value.encodeIfPresent(creatorID, forKey: .creatorID)
    try value.encodeIfPresent(creatorDestinationPath, forKey: .creatorDestinationPath)
  }
}

public struct FolderProposal: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var normalizedName: String
  public var displayName: String
  public var status: FolderProposalStatus
  public var relatedItemIDs: [UUID]
  public var parentDestinationID: UUID?

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    normalizedName: String,
    displayName: String,
    status: FolderProposalStatus = .pending,
    relatedItemIDs: [UUID], parentDestinationID: UUID? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.normalizedName = normalizedName
    self.displayName = displayName
    self.status = status
    self.relatedItemIDs = relatedItemIDs
    self.parentDestinationID = parentDestinationID
  }

  private enum CodingKeys: String, CodingKey {
    case id, sessionID, normalizedName, displayName, status, relatedItemIDs,
      parentDestinationID
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    id = try value.decode(UUID.self, forKey: .id)
    sessionID = try value.decode(UUID.self, forKey: .sessionID)
    normalizedName = try value.decode(String.self, forKey: .normalizedName)
    displayName = try value.decode(String.self, forKey: .displayName)
    status = try value.decode(FolderProposalStatus.self, forKey: .status)
    relatedItemIDs = try value.decode([UUID].self, forKey: .relatedItemIDs)
    parentDestinationID = try value.decodeIfPresent(UUID.self, forKey: .parentDestinationID)
  }
}

public struct FileSnapshot: Codable, Hashable, Sendable {
  public var formatVersion: Int
  public var resourceIdentifier: String?
  public var volumeIdentifier: String?
  public var size: Int64
  public var modificationDate: Date?
  public var directoryManifest: DirectoryManifest?

  public init(
    resourceIdentifier: String?, volumeIdentifier: String?, size: Int64, modificationDate: Date?,
    directoryManifest: DirectoryManifest? = nil, formatVersion: Int = 2
  ) {
    self.formatVersion = formatVersion
    self.resourceIdentifier = resourceIdentifier
    self.volumeIdentifier = volumeIdentifier
    self.size = size
    self.modificationDate = modificationDate
    self.directoryManifest = directoryManifest
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion, resourceIdentifier, volumeIdentifier, size, modificationDate
    case directoryManifest
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
    resourceIdentifier = try values.decodeIfPresent(String.self, forKey: .resourceIdentifier)
    volumeIdentifier = try values.decodeIfPresent(String.self, forKey: .volumeIdentifier)
    size = try values.decode(Int64.self, forKey: .size)
    modificationDate = try values.decodeIfPresent(Date.self, forKey: .modificationDate)
    directoryManifest = try values.decodeIfPresent(DirectoryManifest.self, forKey: .directoryManifest)
  }
}

public struct PlannedOperation: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sequence: Int
  public var kind: OperationKind
  public var sourcePath: String?
  public var destinationPath: String
  public var itemID: UUID?
  public var preSnapshot: FileSnapshot?
  public var createdByApp: Bool
  public var destinationID: UUID?
  public var decisionFeatures: DecisionFeatures?
  public var learningConfirmation: LearningConfirmation?
  public var namingDecisionFeatures: NamingDecisionFeatures?
  public var namingSampleSource: NamingSampleSource?

  public init(
    id: UUID = UUID(), sequence: Int, kind: OperationKind, sourcePath: String? = nil,
    destinationPath: String, itemID: UUID? = nil, preSnapshot: FileSnapshot? = nil,
    createdByApp: Bool = false, destinationID: UUID? = nil,
    decisionFeatures: DecisionFeatures? = nil,
    learningConfirmation: LearningConfirmation? = nil,
    namingDecisionFeatures: NamingDecisionFeatures? = nil,
    namingSampleSource: NamingSampleSource? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.kind = kind
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.itemID = itemID
    self.preSnapshot = preSnapshot
    self.createdByApp = createdByApp
    self.destinationID = destinationID
    self.decisionFeatures = decisionFeatures
    self.learningConfirmation = learningConfirmation
    self.namingDecisionFeatures = namingDecisionFeatures
    self.namingSampleSource = namingSampleSource
  }

  private enum CodingKeys: String, CodingKey {
    case id, sequence, kind, sourcePath, destinationPath, itemID, preSnapshot, createdByApp
    case destinationID, decisionFeatures, learningConfirmation, namingDecisionFeatures,
      namingSampleSource
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sequence = try values.decode(Int.self, forKey: .sequence)
    kind = try values.decode(OperationKind.self, forKey: .kind)
    sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
    destinationPath = try values.decode(String.self, forKey: .destinationPath)
    itemID = try values.decodeIfPresent(UUID.self, forKey: .itemID)
    preSnapshot = try values.decodeIfPresent(FileSnapshot.self, forKey: .preSnapshot)
    createdByApp = try values.decodeIfPresent(Bool.self, forKey: .createdByApp) ?? false
    destinationID = try values.decodeIfPresent(UUID.self, forKey: .destinationID)
    decisionFeatures = try values.decodeIfPresent(DecisionFeatures.self, forKey: .decisionFeatures)
    learningConfirmation = try values.decodeIfPresent(
      LearningConfirmation.self, forKey: .learningConfirmation)
    namingDecisionFeatures = try values.decodeIfPresent(
      NamingDecisionFeatures.self, forKey: .namingDecisionFeatures)
    namingSampleSource = try values.decodeIfPresent(
      NamingSampleSource.self, forKey: .namingSampleSource)
  }
}

public struct OrganizationPlan: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var createdAt: Date
  public var confirmedAt: Date
  public var operations: [PlannedOperation]
  public var reviewedSourcePaths: [String]
  public var catalogRevision: String?

  public init(
    id: UUID = UUID(), sessionID: UUID, createdAt: Date = Date(),
    confirmedAt: Date = Date(), operations: [PlannedOperation],
    reviewedSourcePaths: [String] = [], catalogRevision: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.confirmedAt = confirmedAt
    self.operations = operations.sorted { $0.sequence < $1.sequence }
    self.reviewedSourcePaths = reviewedSourcePaths.sorted()
    self.catalogRevision = catalogRevision
  }

  private enum CodingKeys: String, CodingKey {
    case id, sessionID, createdAt, confirmedAt, operations, reviewedSourcePaths, catalogRevision
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    id = try value.decode(UUID.self, forKey: .id)
    sessionID = try value.decode(UUID.self, forKey: .sessionID)
    createdAt = try value.decode(Date.self, forKey: .createdAt)
    confirmedAt = try value.decode(Date.self, forKey: .confirmedAt)
    operations = try value.decode([PlannedOperation].self, forKey: .operations)
    reviewedSourcePaths = try value.decodeIfPresent([String].self, forKey: .reviewedSourcePaths) ?? []
    catalogRevision = try value.decodeIfPresent(String.self, forKey: .catalogRevision)
  }
}

public struct OperationResult: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID { operationID }
  public var operationID: UUID
  public var state: OperationState
  public var error: String?

  public init(operationID: UUID, state: OperationState, error: String? = nil) {
    self.operationID = operationID
    self.state = state
    self.error = error
  }
}

public struct ExecutionReceipt: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var planID: UUID
  public var completedAt: Date
  public var results: [OperationResult]
  public var wasCancelled: Bool
  public var isUndoReceipt: Bool
  public var isFinal: Bool

  public init(
    id: UUID = UUID(), planID: UUID, completedAt: Date = Date(), results: [OperationResult],
    wasCancelled: Bool = false, isUndoReceipt: Bool = false, isFinal: Bool = true
  ) {
    self.id = id
    self.planID = planID
    self.completedAt = completedAt
    self.results = results
    self.wasCancelled = wasCancelled
    self.isUndoReceipt = isUndoReceipt
    self.isFinal = isFinal
  }

  private enum CodingKeys: String, CodingKey {
    case id, planID, completedAt, results, wasCancelled, isUndoReceipt, isFinal
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    planID = try values.decode(UUID.self, forKey: .planID)
    completedAt = try values.decode(Date.self, forKey: .completedAt)
    results = try values.decode([OperationResult].self, forKey: .results)
    wasCancelled = try values.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
    isUndoReceipt = try values.decodeIfPresent(Bool.self, forKey: .isUndoReceipt) ?? false
    isFinal = try values.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
  }
}

public struct DecisionRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var itemID: UUID
  public var originalDestinationID: UUID?
  public var finalDestinationID: UUID?
  public var action: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), sessionID: UUID, itemID: UUID,
    originalDestinationID: UUID?, finalDestinationID: UUID?,
    action: String, createdAt: Date = Date()
  ) {
    self.id = id
    self.sessionID = sessionID
    self.itemID = itemID
    self.originalDestinationID = originalDestinationID
    self.finalDestinationID = finalDestinationID
    self.action = action
    self.createdAt = createdAt
  }
}

public enum ScanEvent: Sendable {
  case started(total: Int)
  case discovered(ItemSnapshot)
  case skipped(path: String, reason: String)
  case finished(discovered: Int, skipped: Int)
}

public enum OrganizationProgressPhase: String, Codable, Hashable, Sendable {
  case scanning
  case analyzing
  case aiClassifying
  case preflighting
  case executing
  case undoing
}

public struct OrganizationProgress: Codable, Hashable, Sendable {
  public var phase: OrganizationProgressPhase
  public var completed: Int
  public var total: Int?
  public var skipped: Int
  public var failed: Int
  public var isIndeterminate: Bool
  public var isCancellable: Bool

  public init(
    phase: OrganizationProgressPhase,
    completed: Int = 0,
    total: Int? = nil,
    skipped: Int = 0,
    failed: Int = 0,
    isIndeterminate: Bool = false,
    isCancellable: Bool = true
  ) {
    self.phase = phase
    self.completed = max(0, completed)
    self.total = total.map { max(0, $0) }
    self.skipped = max(0, skipped)
    self.failed = max(0, failed)
    self.isIndeterminate = isIndeterminate
    self.isCancellable = isCancellable
  }
}

public typealias OrganizationProgressHandler = @Sendable (OrganizationProgress) async -> Void

public enum ExecutionEvent: Sendable {
  case started(total: Int)
  case operationStarted(PlannedOperation)
  case operationFinished(OperationResult)
  case finished(ExecutionReceipt)
}

public struct PreflightIssue: Codable, Hashable, Identifiable, Sendable {
  public var id = UUID()
  public var operationID: UUID
  public var message: String

  public init(operationID: UUID, message: String) {
    self.operationID = operationID
    self.message = message
  }
}

public struct PreflightReport: Codable, Hashable, Sendable {
  public var issues: [PreflightIssue]
  public var isReady: Bool { issues.isEmpty }

  public init(issues: [PreflightIssue] = []) { self.issues = issues }
}
