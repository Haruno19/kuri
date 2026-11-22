import SwiftUI

/// The menu bar popover. A starting point for the compact chat.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            ForEach(model.conversations.prefix(6)) { conversation in
                Button {
                    model.selection = conversation.id
                    open()
                } label: {
                    Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            Divider()
            Button("Open Kuri") { open() }.buttonStyle(.plain).padding(.horizontal, 8)
            Button("Quit Kuri") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).padding(.horizontal, 8)
                .keyboardShortcut("q")
        }
        .padding(.vertical, 8)
        .frame(width: 260)
    }

    private func open() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
