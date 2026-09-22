import Foundation
import Testing

@testable import AIFileOrganizerCore

/// `SecurityScopedBookmarks` 是沙箱应用重新打开工作区的唯一入口，此前在
/// `Tests/` 中零引用。它的 `resolve()` 内部有 5 条错误分支和 2 处失败清理
/// （`SecurityScopedBookmarks.swift:60-89`）。
///
/// ## 环境限制（重要，决定了本套件能覆盖到哪一步）
///
/// 创建安全范围书签需要 `com.apple.security.files.bookmarks.app-scope` 授权：
///
/// ```text
/// Error Domain=NSCocoaErrorDomain Code=256
/// "Required entitlement com.apple.security.files.bookmarks.app-scope is missing or false"
/// ```
///
/// 而 `App` 的 entitlements 只挂在应用 target 上（`project.yml` 的
/// `entitlements:`），`AIFileOrganizerCoreTests` 与 `AIFileOrganizerUITests`
/// 都没有任何 entitlements 设置。因此在 `swift test` 与 Xcode 测试下：
///
/// - `create(for:)` **必然抛错** → `makeWorkspace` 走不到书签那一步；
/// - `resolve(...)` 的路径比对、卷比对、stale 检查、`startAccessing` 分支
///   **全部不可达**，因为无法先造出一个可解析的安全范围书签。
///
/// 所以这里**不写**任何会静默跳过或靠分支猜测通过的用例：能确定断言的
/// 就断言，不能覆盖的在下方 `resolveIsNotReachableInTestEnvironment`
/// 中把原因固化成一条会失败的检查——一旦将来给测试 target 加了授权，
/// 这条检查会立刻失败并提醒补上真正的覆盖。
@Suite struct SecurityScopedBookmarksTests {
  private func makeDirectories() throws -> (root: URL, inbox: URL, library: URL) {
    let root = try temporaryDirectory()
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    return (root, inbox, library)
  }

  /// 若测试二进制能创建安全范围书签（即已获得 app-scope 授权），返回 true。
  private func canCreateScopedBookmark() -> Bool {
    let probe = FileManager.default.temporaryDirectory
      .appendingPathComponent("aifo-bookmark-probe-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(
      at: probe, withIntermediateDirectories: true)) != nil
    else { return false }
    defer { try? FileManager.default.removeItem(at: probe) }
    return (try? SecurityScopedBookmarks.create(for: probe)) != nil
  }

  @Test func makeWorkspaceSurfacesBookmarkCreationFailureGracefully() throws {
    let (root, inbox, library) = try makeDirectories()
    defer { try? FileManager.default.removeItem(at: root) }

    if canCreateScopedBookmark() {
      // 已授权环境：走真实成功路径，并覆盖路径规范化。
      let workspace = try SecurityScopedBookmarks.makeWorkspace(inbox: inbox, library: library)
      #expect(!workspace.inboxBookmark.isEmpty)
      #expect(!workspace.libraryBookmark.isEmpty)
      #expect(workspace.inboxPath == PathSafety.normalized(inbox).path)
      #expect(workspace.libraryPath == PathSafety.normalized(library).path)
      #expect(!workspace.inboxVolumeID.isEmpty)
      #expect(workspace.inboxVolumeID == workspace.libraryVolumeID)
    } else {
      // 本环境：必须抛出明确的 bookmarkCreationFailed，而不是崩溃或吞掉错误。
      var thrown: (any Error)?
      do {
        _ = try SecurityScopedBookmarks.makeWorkspace(inbox: inbox, library: library)
      } catch {
        thrown = error
      }
      guard case .bookmarkCreationFailed(let message) = try #require(thrown as? OrganizerError)
      else {
        Issue.record("期望 bookmarkCreationFailed，实际为 \(String(describing: thrown))")
        return
      }
      #expect(message.contains("无法保存目录授权"))
    }
  }

  /// `validateWorkspace` 在书签创建**之前**执行，因此同卷守卫可以在本环境
  /// 被真实触发——这条用例不依赖任何授权。
  @Test func makeWorkspaceRejectsDirectoryOverlapBeforeCreatingBookmarks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("Parent", isDirectory: true)
    let child = parent.appendingPathComponent("Child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    var thrown: (any Error)?
    do {
      _ = try SecurityScopedBookmarks.makeWorkspace(inbox: parent, library: child)
    } catch {
      thrown = error
    }
    guard case .invalidWorkspace(let message) = try #require(thrown as? OrganizerError) else {
      Issue.record("期望 invalidWorkspace，实际为 \(String(describing: thrown))")
      return
    }
    #expect(message.contains("互相包含"))
  }

  @Test func createRejectsDirectoryThatDoesNotExist() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("aifo-missing-\(UUID().uuidString)", isDirectory: true)

    var thrown: (any Error)?
    do {
      _ = try SecurityScopedBookmarks.create(for: missing)
    } catch {
      thrown = error
    }
    // 不存在（且无授权）时同样必须是 bookmarkCreationFailed，而不是漏出底层错误。
    guard case .bookmarkCreationFailed = try #require(thrown as? OrganizerError) else {
      Issue.record("期望 bookmarkCreationFailed，实际为 \(String(describing: thrown))")
      return
    }
  }

  /// `resolve()` 是本类里唯一会访问文件系统之外的授权状态、并持有
  /// `startAccessingSecurityScopedResource()` 配平逻辑的方法。
  ///
  /// 它需要"一个可解析的安全范围书签"作为输入，而本环境根本无法创建——
  /// 因此无法覆盖其路径比对 / 卷比对 / stale / 访问失败等分支。
  /// 这条用例把这个事实固化为断言：一旦测试 target 获得 app-scope 授权，
  /// 它就会失败，提醒作者补上真正的 `resolve()` 覆盖。
  @Test func resolveIsNotReachableInTestEnvironment() throws {
    #expect(
      !canCreateScopedBookmark(),
      """
      测试环境现在可以创建安全范围书签了——请补上 SecurityScopedBookmarks.resolve() \
      的覆盖：路径变化（inboxPath/libraryPath 不匹配）、卷变化（volumeID 不匹配）、\
      stale 书签、startAccessingSecurityScopedResource 失败，以及成功路径的 \
      ResolvedWorkspaceAccess.stop() 配平。
      """)
  }
}
