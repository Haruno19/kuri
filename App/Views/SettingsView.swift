import KuriConfig
import KuriCore
import KuriMCP
import KuriStore
import KuriTools
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Tools", systemImage: "wrench.and.screwdriver") { ToolsSettings() }
            Tab("Memory", systemImage: "brain") { MemorySettings() }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let home = model.engine?.home {
                Section("Configuration") {
                    fileRow("Providers, models, tool policies", url: home.configFile)
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
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            Button("Open \(url.lastPathComponent)") { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Tools

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.tools.filter { $0.source == .builtIn }) { tool in
                    ToolRow(tool: tool)
                }
            } header: {
                Text("Built in")
            }

            ForEach(model.mcpServers) { server in
                MCPServerSection(server: server, tools: model.tools.filter { $0.source == .mcp(server: server.name) })
            }

            Section {
                if let home = model.engine?.home {
                    LabeledContent(model.mcpServers.isEmpty ? "No MCP servers yet" : "MCP servers") {
                        Button("Open mcp.json") { NSWorkspace.shared.open(home.mcpFile) }
                    }
                }
            } footer: {
                Text("""
                    Kuri reconnects servers as soon as mcp.json changes. Policies go in config.json under “tools” \
                    (any tool, e.g. `memory: "deny"`) or in mcp.json inside a server (its own tool names). \
                    MCP tools the server marks read-only are allowed; others ask first.
                    """)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MCPServerSection: View {
    @Environment(AppModel.self) private var model
    let server: MCPServerStatus
    let tools: [ToolInfo]
    @State private var showsLog = false

    var body: some View {
        Section {
            if case .failed(let message) = server.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(tools) { tool in
                ToolRow(tool: tool)
            }
            if !server.log.isEmpty {
                DisclosureGroup("Log", isExpanded: $showsLog) {
                    Text(server.log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                    Text(server.serverInfo.map { "\($0) · \(server.target)" } ?? server.target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if server.state == .connecting {
                    ProgressView().controlSize(.small)
                } else if server.state != .disabled {
                    Button("Reconnect") { Task { await model.reconnect(mcpServer: server.name) } }
                        .controlSize(.small)
                }
            }
        }
    }

    private var color: Color {
        switch server.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disabled: .gray
        }
    }
}

struct ToolRow: View {
    let tool: ToolInfo

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.originalName).font(.body.monospaced())
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(tool.description)
            }
            Spacer()
            PolicyBadge(policy: tool.policy)
        }
    }
}

struct PolicyBadge: View {
    let policy: ToolPolicy

    var body: some View {
        Text(policy.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch policy {
        case .allow: .green
        case .ask: .orange
        case .deny: .red
        }
    }
}

// MARK: - Memory

private struct MemorySettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var editing: Memory?
    @State private var editText = ""

    var body: some View {
        Form {
            Section {
                if model.memories.isEmpty {
                    Text("Nothing yet. Kuri saves durable facts here when you ask it to remember something.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.memories) { memory in
                    HStack(alignment: .firstTextBaseline) {
                        Text(memory.handle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .leading)
                        Text(memory.content)
                            .textSelection(.enabled)
                        Spacer()
                        Menu {
                            Button("Edit…") {
                                editText = memory.content
                                editing = memory
                            }
                            Button("Forget", role: .destructive) {
                                Task { await model.changeMemories([.remove(number: memory.number)]) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            } header: {
                Text("What Kuri remembers")
            } footer: {
                Text("Included in every conversation. The model edits it with the memory tool; you can too.")
                    .foregroundStyle(.secondary)
            }

            Section("Add") {
                HStack {
                    TextField("A fact about you, e.g. “I use zsh and Helix”", text: $draft)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { memory in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit \(memory.handle)").font(.headline)
                TextField("Memory", text: $editText, axis: .vertical)
                    .lineLimit(2...6)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let content = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        editing = nil
                        guard !content.isEmpty else { return }
                        Task { await model.changeMemories([.update(number: memory.number, content: content)]) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
    }

    private func add() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        draft = ""
        Task { await model.changeMemories([.add(content)]) }
    }
}
