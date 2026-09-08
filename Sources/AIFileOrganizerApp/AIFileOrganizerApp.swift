import SwiftUI

@main
struct AIFileOrganizerApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .frame(minWidth: 980, minHeight: 680)
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 1180, height: 760)
    .commands {
      CommandGroup(after: .newItem) {
        Button("开始整理") { model.startOrganizing() }
          .keyboardShortcut("r", modifiers: [.command])
          .disabled(model.workspace == nil || model.isWorking)
      }
    }
  }
}
