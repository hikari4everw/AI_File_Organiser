import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    reopenMainWindowIfNeeded()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      reopenMainWindowIfNeeded()
    }
    return true
  }

  private func reopenMainWindowIfNeeded() {
    DispatchQueue.main.async {
      guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) else { return }
      guard
        let item = NSApp.mainMenu?.items
          .compactMap(\.submenu)
          .flatMap(\.items)
          .first(where: {
            $0.keyEquivalent == "n"
              && $0.keyEquivalentModifierMask.contains(.command)
              && $0.action != nil
          }),
        let action = item.action
      else { return }

      NSApp.sendAction(action, to: item.target, from: item)
      NSApp.activate()
    }
  }
}

@main
struct AIFileOrganizerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("AI File Organizer", id: "main") {
      ContentView(model: model)
        .frame(minWidth: 980, minHeight: 680)
    }
    .restorationBehavior(.disabled)
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
