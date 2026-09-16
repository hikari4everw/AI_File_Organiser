import Foundation

public enum ConceptIdentity {
  public static func of(_ item: ItemSnapshot) -> String {
    if let volume = item.volumeIdentifier, let resource = item.resourceIdentifier,
      !volume.isEmpty, !resource.isEmpty
    {
      return "resource:\(volume):\(resource)"
    }
    return "path:\(URL(fileURLWithPath: item.path).standardizedFileURL.path)"
  }
}
