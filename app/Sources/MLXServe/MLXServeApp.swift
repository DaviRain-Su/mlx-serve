import SwiftUI
import AppKit

@main
struct MLXClawApp: App {
    private static let menuBarIcon: NSImage = {
        // Try Bundle.main (works in .app bundles) then Bundle.module (works in dev builds)
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Resources/tray.png"),
            Bundle.main.bundleURL.appendingPathComponent("MLXClaw_MLXClaw.bundle/Resources/tray.png"),
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                return img
            }
        }
        return NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "MLX Claw")!
    }()

    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(openChat: { openWindow(id: "chat") }, openBrowser: { openWindow(id: "browser") })
                .environmentObject(appState)
                .environmentObject(appState.server)
                .environmentObject(appState.downloads)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("MLX Claw", id: "chat") {
            ChatView()
                .environmentObject(appState)
                .environmentObject(appState.server)
                .environmentObject(appState.toolExecutor)
                .environmentObject(appState.agentMemory)
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 650)

        Window("Browser", id: "browser") {
            BrowserView()
        }
        .defaultSize(width: 1024, height: 768)
    }
}
