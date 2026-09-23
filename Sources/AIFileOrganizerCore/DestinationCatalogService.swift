import Foundation

public struct DestinationCatalogService: Sendable {
  private let indexer: DestinationIndexer

  public init(indexer: DestinationIndexer = .init()) { self.indexer = indexer }

  public func index(
    workspace: Workspace,
    maxDepth: Int = 4,
    kindsByRelativePath: [String: DestinationKind] = [:],
    roleOverrides: [String: LibraryNodeRole] = [:]
  ) throws -> [DestinationProfile] {
    try indexer.index(
      workspace: workspace,
      maxDepth: maxDepth,
      kindsByRelativePath: kindsByRelativePath,
      roleOverrides: roleOverrides
    )
  }
}
