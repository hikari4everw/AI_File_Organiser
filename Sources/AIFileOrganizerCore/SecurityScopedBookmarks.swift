import Foundation

public struct ResolvedWorkspaceAccess {
  public let inboxURL: URL
  public let libraryURL: URL
  private let accessedURLs: [URL]

  init(inboxURL: URL, libraryURL: URL, accessedURLs: [URL]) {
    self.inboxURL = inboxURL
    self.libraryURL = libraryURL
    self.accessedURLs = accessedURLs
  }

  public func stop() {
    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
  }
}

public enum SecurityScopedBookmarks {
  public static func create(for url: URL) throws -> Data {
    do {
      return try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: [.volumeIdentifierKey],
        relativeTo: nil
      )
    } catch {
      throw OrganizerError.bookmarkCreationFailed("无法保存目录授权：\(error.localizedDescription)")
    }
  }

  public static func makeWorkspace(inbox: URL, library: URL) throws -> Workspace {
    let volumes = try PathSafety.validateWorkspace(inbox: inbox, library: library)
    return Workspace(
      inboxPath: PathSafety.normalized(inbox).path,
      libraryPath: PathSafety.normalized(library).path,
      inboxBookmark: try create(for: inbox),
      libraryBookmark: try create(for: library),
      inboxVolumeID: volumes.0,
      libraryVolumeID: volumes.1
    )
  }

  public static func resolve(_ workspace: Workspace) throws -> ResolvedWorkspaceAccess {
    var inboxStale = false
    var libraryStale = false
    do {
      let inbox = try URL(
        resolvingBookmarkData: workspace.inboxBookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &inboxStale
      )
      let library = try URL(
        resolvingBookmarkData: workspace.libraryBookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &libraryStale
      )
      guard !inboxStale, !libraryStale else {
        throw OrganizerError.bookmarkResolutionFailed("目录授权已失效，请重新选择目录")
      }
      guard inbox.startAccessingSecurityScopedResource() else {
        throw OrganizerError.bookmarkResolutionFailed("无法访问收件箱，请重新授权")
      }
      guard library.startAccessingSecurityScopedResource() else {
        inbox.stopAccessingSecurityScopedResource()
        throw OrganizerError.bookmarkResolutionFailed("无法访问资料库，请重新授权")
      }
      let resolvedInbox = PathSafety.normalized(inbox)
      let resolvedLibrary = PathSafety.normalized(library)
      do {
        guard resolvedInbox.path == workspace.inboxPath,
          resolvedLibrary.path == workspace.libraryPath
        else {
          throw OrganizerError.bookmarkResolutionFailed("目录位置已变化，请重新授权")
        }
        let volumes = try PathSafety.validateWorkspace(
          inbox: resolvedInbox,
          library: resolvedLibrary
        )
        guard volumes.0 == workspace.inboxVolumeID, volumes.1 == workspace.libraryVolumeID else {
          throw OrganizerError.bookmarkResolutionFailed("目录所在磁盘已变化，请重新授权")
        }
      } catch {
        inbox.stopAccessingSecurityScopedResource()
        library.stopAccessingSecurityScopedResource()
        throw error
      }
      return ResolvedWorkspaceAccess(
        inboxURL: resolvedInbox,
        libraryURL: resolvedLibrary,
        accessedURLs: [inbox, library]
      )
    } catch let error as OrganizerError {
      throw error
    } catch {
      throw OrganizerError.bookmarkResolutionFailed("无法恢复目录授权：\(error.localizedDescription)")
    }
  }
}
