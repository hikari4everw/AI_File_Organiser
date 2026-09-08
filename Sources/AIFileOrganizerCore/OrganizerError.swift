import Foundation

public enum OrganizerError: LocalizedError, Sendable {
  case invalidWorkspace(String)
  case bookmarkCreationFailed(String)
  case bookmarkResolutionFailed(String)
  case accessDenied(String)
  case scanFailed(String)
  case modelUnavailable(String)
  case invalidModelOutput(String)
  case invalidFolderName(String)
  case planBlocked([String])
  case operationFailed(String)
  case persistenceFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidWorkspace(let message), .bookmarkCreationFailed(let message),
      .bookmarkResolutionFailed(let message), .accessDenied(let message),
      .scanFailed(let message), .modelUnavailable(let message),
      .invalidModelOutput(let message), .invalidFolderName(let message),
      .operationFailed(let message), .persistenceFailed(let message):
      message
    case .planBlocked(let messages):
      messages.joined(separator: "\n")
    }
  }
}
