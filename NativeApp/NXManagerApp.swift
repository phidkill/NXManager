import SwiftUI

@main
struct NXManagerApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    sidebarVisible.toggle()
                }
                .keyboardShortcut("S", modifiers: [.command, .control])
            }
        }
    }
}
