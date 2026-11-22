import KuriConfig
import SwiftUI

/// For now: where the configuration lives, and a way to open it.
/// Editing providers and MCP servers from here comes later.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let home = model.engine?.home {
                Section("Configuration") {
                    fileRow("Providers and models", url: home.configFile)
                    fileRow("MCP servers", url: home.mcpFile)
                    LabeledContent("Data folder") {
                        Button(home.root.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([home.root])
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            Section("Models") {
                if model.models.isEmpty {
                    Text("No models declared in config.json.").foregroundStyle(.secondary)
                }
                ForEach(model.models, id: \.self) { ref in
                    Text(ref.description).font(.body.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            Button("Open \(url.lastPathComponent)") { NSWorkspace.shared.open(url) }
        }
    }
}
