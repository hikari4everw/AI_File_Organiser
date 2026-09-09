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
  case createDirectory, move
}

public enum OperationState: String, Codable, Sendable {
  case pending, running, completed, failed, undone, blocked
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

public struct ExtractedContext: Codable, Hashable, Sendable {
  public var text: String
  public var source: String
  public var wasTruncated: Bool

  public init(text: String = "", source: String = "none", wasTruncated: Bool = false) {
    self.text = text
    self.source = source
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

  public init(
    snapshot: ItemSnapshot,
    normalizedKeywords: [String],
    extracted: ExtractedContext = .init(),
    spotlightTitle: String? = nil,
    spotlightAuthors: [String] = [],
    spotlightContentType: String? = nil
  ) {
    self.snapshot = snapshot
    self.normalizedKeywords = normalizedKeywords
    self.extracted = extracted
    self.spotlightTitle = spotlightTitle
    self.spotlightAuthors = spotlightAuthors
    self.spotlightContentType = spotlightContentType
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
    evidence: [Evidence] = []
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
  }
}

public struct FolderProposal: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var normalizedName: String
  public var displayName: String
  public var status: FolderProposalStatus
  public var relatedItemIDs: [UUID]

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    normalizedName: String,
    displayName: String,
    status: FolderProposalStatus = .pending,
    relatedItemIDs: [UUID]
  ) {
    self.id = id
    self.sessionID = sessionID
    self.normalizedName = normalizedName
    self.displayName = displayName
    self.status = status
    self.relatedItemIDs = relatedItemIDs
  }
}

public struct FileSnapshot: Codable, Hashable, Sendable {
  public var resourceIdentifier: String?
  public var volumeIdentifier: String?
  public var size: Int64
  public var modificationDate: Date?

  public init(
    resourceIdentifier: String?, volumeIdentifier: String?, size: Int64, modificationDate: Date?
  ) {
    self.resourceIdentifier = resourceIdentifier
    self.volumeIdentifier = volumeIdentifier
    self.size = size
    self.modificationDate = modificationDate
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

  public init(
    id: UUID = UUID(), sequence: Int, kind: OperationKind, sourcePath: String? = nil,
    destinationPath: String, itemID: UUID? = nil, preSnapshot: FileSnapshot? = nil,
    createdByApp: Bool = false
  ) {
    self.id = id
    self.sequence = sequence
    self.kind = kind
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.itemID = itemID
    self.preSnapshot = preSnapshot
    self.createdByApp = createdByApp
  }
}

public struct OrganizationPlan: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var createdAt: Date
  public var confirmedAt: Date
  public var operations: [PlannedOperation]

  public init(
    id: UUID = UUID(), sessionID: UUID, createdAt: Date = Date(),
    confirmedAt: Date = Date(), operations: [PlannedOperation]
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.confirmedAt = confirmedAt
    self.operations = operations.sorted { $0.sequence < $1.sequence }
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

  public init(
    id: UUID = UUID(), planID: UUID, completedAt: Date = Date(), results: [OperationResult]
  ) {
    self.id = id
    self.planID = planID
    self.completedAt = completedAt
    self.results = results
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
