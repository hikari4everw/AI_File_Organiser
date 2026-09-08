import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileThumbnail: View {
  let path: String
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
      }
    }
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    .task(id: path) { await loadThumbnail() }
  }

  private func loadThumbnail() async {
    let request = QLThumbnailGenerator.Request(
      fileAt: URL(fileURLWithPath: path),
      size: CGSize(width: 640, height: 420),
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .thumbnail
    )
    do {
      let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(
        for: request)
      image = representation.nsImage
    } catch {
      image = nil
    }
  }
}
