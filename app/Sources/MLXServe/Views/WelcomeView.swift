import SwiftUI

struct WelcomeView: View {
    let onDismiss: () -> Void

    @State private var pulseMenu = false
    @State private var appeared = false

    private static func loadBundledImage(_ name: String) -> NSImage? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent("MLXCore_MLXCore.bundle/Resources/\(name)"),
            // Dev builds: look relative to source
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }

    private static let appIcon: NSImage? = loadBundledImage("appiconb.png")

    private static let trayIcon: NSImage? = {
        guard let img = loadBundledImage("tray.png") else { return nil }
        img.isTemplate = true  // adapts to light/dark mode
        return img
    }()

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)

            // App icon
            if let icon = Self.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.bottom, 10)
            }

            Text("Welcome to MLX Core")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 3)

            Text("Local AI on Apple Silicon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            // Feature cards
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(
                    icon: "menubar.rectangle",
                    title: "Lives in your menu bar",
                    description: "Click the icon in the top-right of your screen to start a server, download models, and chat."
                )
                FeatureRow(
                    icon: "bolt.fill",
                    title: "Run models locally",
                    description: "No cloud, no API keys. All processing stays on your device."
                )
                FeatureRow(
                    icon: "wrench.and.screwdriver.fill",
                    title: "Agent with tools",
                    description: "Let the model read files, run commands, search the web, and write code."
                )
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            // Tray hint
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .offset(y: pulseMenu ? -2 : 2)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseMenu)
                Text("Look for the")
                    .foregroundStyle(.secondary)
                if let tray = Self.trayIcon {
                    Image(nsImage: tray)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.accentColor)
                }
                Text("icon in your menu bar")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.bottom, 14)

            // Dismiss button
            Button {
                onDismiss()
                NSApp.keyWindow?.close()
            } label: {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: true, vertical: true)
        .background(.ultraThinMaterial)
        .onAppear {
            pulseMenu = true
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
        .opacity(appeared ? 1 : 0)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
