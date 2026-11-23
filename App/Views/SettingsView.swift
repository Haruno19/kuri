import KuriConfig
import KuriCore
import KuriMCP
import KuriSandbox
import KuriStore
import KuriTools
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Models", systemImage: "cpu") { ModelsSettings() }
            Tab("Tools", systemImage: "wrench.and.screwdriver") { ToolsSettings() }
            Tab("Sandbox", systemImage: "shippingbox") { SandboxSettingsView() }
            Tab("Memory", systemImage: "bookmark") { MemorySettings() }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.config.appearance ?? .system },
                    set: { appearance in Task { await model.setAppearance(appearance) } })
                ) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
            }
            Section("Conversations") {
                Toggle("Generate titles", isOn: Binding(
                    get: { model.config.generateTitles ?? true },
                    set: { enabled in Task { await model.setGenerateTitles(enabled) } }))
                Text("After the first answer, the utility model (or the conversation's model) names the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        }
        .formStyle(.grouped)
    }

    private func fileRow(_ title: String, url: URL) -> some View {
        LabeledContent(title) {
            Button("Open \(url.lastPathComponent)") { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Models

private struct ModelsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("New conversations use", selection: Binding(
                    get: { model.config.defaultModel },
                    set: { ref in Task { await model.setDefaultModel(ref) } })
                ) {
                    Text("None").tag(ModelRef?.none)
                    ForEach(model.models, id: \.self) { ref in
                        Text(ref.description).tag(Optional(ref))
                    }
                }
            }

            ForEach(model.config.providers.keys.sorted(), id: \.self) { name in
                if let provider = model.config.providers[name] {
                    ProviderModelsSection(name: name, provider: provider)
                }
            }

            Section {
                if let home = model.engine?.home {
                    LabeledContent(model.config.providers.isEmpty ? "No providers yet" : "Providers") {
                        Button("Open config.json") { NSWorkspace.shared.open(home.configFile) }
                    }
                }
            } footer: {
                Text("""
                    Providers are declared in config.json. Models you add here are written to it; \
                    Kuri rewrites the file as tidy JSON5, so comments in it are not kept.
                    """)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderModelsSection: View {
    @Environment(AppModel.self) private var model
    let name: String
    let provider: ProviderConfig

    @State private var draft = ""
    @State private var contextWindow = ""
    @State private var available: [String] = []
    @State private var discoveryError: String?
    @State private var isDiscovering = false

    private var registered: [ModelConfig] { provider.models ?? [] }

    /// Served models not registered yet, narrowed by what's typed.
    private var suggestions: [String] {
        let ids = Set(registered.map(\.id))
        let candidates = available.filter { !ids.contains($0) }
        guard !draft.isEmpty else { return candidates }
        return candidates.filter { $0.localizedCaseInsensitiveContains(draft) }
    }

    var body: some View {
        Section {
            ForEach(registered, id: \.id) { entry in
                RegisteredModelRow(provider: name, entry: entry)
            }
            if provider.discoverModels == true {
                Text("Every model this server lists is also available, without adding it (discoverModels).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                TextField("Model id", text: $draft, prompt: Text("Model id"))
                    .textInputSuggestions {
                        ForEach(suggestions, id: \.self) { id in
                            Text(id).textInputCompletion(id)
                        }
                    }
                    .onSubmit(add)
                if !available.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { id in
                            Button(id) { draft = id }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Models served by \(name)")
                }
                TextField("Context", text: $contextWindow, prompt: Text("Context"))
                    .frame(width: 80)
                    .help("Context window in tokens (optional)")
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .labelsHidden()

            if let discoveryError {
                Text(discoveryError).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    Text([provider.format.rawValue, provider.baseURL?.absoluteString].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isDiscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await discover() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Ask \(name) which models it serves")
                }
            }
        }
        .task(id: name) { await discover() }
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            available = try await model.availableModels(provider: name)
            discoveryError = available.isEmpty ? "\(name) lists no models." : nil
        } catch {
            available = []
            discoveryError = "Couldn't list models: \(error.localizedDescription) You can still type an id."
        }
    }

    private func add() {
        let id = draft.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        let entry = ModelConfig(id: id, contextWindow: Int(contextWindow.trimmingCharacters(in: .whitespaces)))
        draft = ""
        contextWindow = ""
        Task { await model.register(entry, provider: name) }
    }
}

/// A registered model: its context window can be edited in place (empty
/// means unknown); Return or leaving the field saves it.
private struct RegisteredModelRow: View {
    @Environment(AppModel.self) private var model
    let provider: String
    let entry: ModelConfig
    @State private var context = ""
    @FocusState private var editing: Bool

    var body: some View {
        let ref = ModelRef(provider: provider, model: entry.id)
        HStack {
            Text(entry.id).font(.body.monospaced())
            if model.config.defaultModel == ref {
                Text("default").font(.caption.weight(.medium)).foregroundStyle(.tint)
            }
            Spacer()
            TextField("Context", text: $context, prompt: Text("Context"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .focused($editing)
                .onSubmit(save)
                .help("Context window in tokens")
            Text("tokens").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Use for New Conversations") { Task { await model.setDefaultModel(ref) } }
                Button("Remove", role: .destructive) {
                    Task { await model.unregister(model: entry.id, provider: provider) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .onAppear { context = Self.text(entry.contextWindow) }
        .onChange(of: entry.contextWindow) { _, window in if !editing { context = Self.text(window) } }
        .onChange(of: editing) { _, focused in if !focused { save() } }
    }

    private static func text(_ window: Int?) -> String { window.map(String.init) ?? "" }

    private func save() {
        let digits = context.filter(\.isNumber)
        let window = Int(digits).flatMap { $0 > 0 ? $0 : nil }
        context = Self.text(window)
        guard window != entry.contextWindow else { return }
        var updated = entry
        updated.contextWindow = window
        Task { await model.register(updated, provider: provider) }
    }
}

// MARK: - Sandbox

private struct SandboxSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                switch model.sandboxStatus {
                case .ready:
                    Label("Ready. The model has a `shell` tool.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .notInstalled:
                    Label("Not set up yet.", systemImage: "shippingbox")
                    Text("""
                        Setup downloads a Linux kernel release (about 680 MB, of which only the 18 MB kernel is \
                        kept), Apple's init image and the container image: about 0.8 GB on disk in the end. After \
                        that the sandbox works offline.
                        """)
                    .font(.callout).foregroundStyle(.secondary)
                    Button("Set Up Sandbox") { Task { await model.setUpSandbox() } }
                case .installing(let step, let fraction):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step)
                        if let fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Try Again") { Task { await model.setUpSandbox() } }
                }
            } header: {
                Text("Linux sandbox")
            } footer: {
                Text("""
                    Each conversation gets its own lightweight VM, started on its first command and stopped when \
                    idle. Attached folders are mounted at /work; without one, a scratch folder is. No network.
                    """)
                .foregroundStyle(.secondary)
            }

            SandboxOptions()
        }
        .formStyle(.grouped)
    }
}

/// The sandbox keys of config.json, edited in place. A value equal to its
/// default is written as no key at all.
private struct SandboxOptions: View {
    @Environment(AppModel.self) private var model
    @State private var image = ""
    @FocusState private var editingImage: Bool

    private var settings: SandboxSettings { SandboxSettings(model.config.sandbox) }
    private static let cpuChoices = Array(Set([1, 2, 4, 6, 8, 12, 16].filter { $0 <= ProcessInfo.processInfo.activeProcessorCount } + [4])).sorted()
    private static let memoryChoices = [512, 1024, 2048, 4096, 8192, 16384]
        .filter { UInt64($0) * 1_048_576 <= ProcessInfo.processInfo.physicalMemory / 2 || $0 == 2048 }
    private static let idleChoices = [2, 5, 10, 15, 30, 60]

    var body: some View {
        Section {
            LabeledContent("Image") {
                TextField("Image", text: $image, prompt: Text(SandboxSettings.defaultImage))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .focused($editingImage)
                    .onSubmit(saveImage)
            }
            Picker("CPUs", selection: binding(\.cpus) { settings, value in settings.cpus = value }) {
                ForEach(Self.choices(Self.cpuChoices, current: settings.cpus), id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Memory", selection: binding(\.memoryMiB) { settings, value in settings.memoryMiB = value }) {
                ForEach(Self.choices(Self.memoryChoices, current: settings.memoryMiB), id: \.self) { Text(Self.memory($0)).tag($0) }
            }
            Picker("Stops after", selection: binding(\.idleMinutes) { settings, value in settings.idleMinutes = value }) {
                ForEach(Self.choices(Self.idleChoices, current: settings.idleMinutes), id: \.self) { Text("\($0) min idle").tag($0) }
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("Changing the image, CPUs or memory stops running sandboxes; a new image needs setup again. Saved to config.json.")
                .foregroundStyle(.secondary)
        }
        .onAppear { image = model.config.sandbox?.image ?? "" }
        .onChange(of: model.config.sandbox?.image) { _, value in if !editingImage { image = value ?? "" } }
        .onChange(of: editingImage) { _, focused in if !focused { saveImage() } }
    }

    /// The values as config.json should hold them: defaults left out.
    private func save(_ change: (inout SandboxSettings) -> Void) {
        var next = settings
        change(&next)
        Task {
            await model.setSandbox(
                image: next.image == SandboxSettings.defaultImage ? nil : next.image,
                cpus: next.cpus == 4 ? nil : next.cpus,
                memoryMiB: next.memoryMiB == 2048 ? nil : next.memoryMiB,
                idleMinutes: next.idleMinutes == 10 ? nil : next.idleMinutes)
        }
    }

    private func binding(_ key: KeyPath<SandboxSettings, Int>,
                         _ set: @escaping (inout SandboxSettings, Int) -> Void) -> Binding<Int> {
        Binding(get: { settings[keyPath: key] }, set: { value in save { set(&$0, value) } })
    }

    private func saveImage() {
        let value = image.trimmingCharacters(in: .whitespaces)
        let next = value.isEmpty ? SandboxSettings.defaultImage : value
        guard next != settings.image else { return }
        save { $0.image = next }
    }

    /// The usual choices, plus whatever the file says if it's something else.
    private static func choices(_ list: [Int], current: Int) -> [Int] {
        list.contains(current) ? list : (list + [current]).sorted()
    }

    private static func memory(_ mib: Int) -> String {
        mib < 1024 ? "\(mib) MB" : "\(mib / 1024) GB"
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
                    TextField("Memory", text: $draft, prompt: Text(""))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
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
