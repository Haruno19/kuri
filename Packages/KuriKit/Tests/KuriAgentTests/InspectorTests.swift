import Foundation
import KuriConfig
import KuriCore
import KuriInference
import KuriStore
import KuriTools
import Testing
@testable import KuriAgent

@Suite struct RepositoryStatusTests {
    @Test func parsesPorcelainV2() {
        let status = [
            "# branch.oid 1234567890abcdef",
            "# branch.head fix/iso-weeks",
            "# branch.upstream origin/fix/iso-weeks",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/Notes/Date Parser.swift",
            "1 A. N... 000000 100644 100644 000 ccc Tests/New.swift",
            "2 R. N... 100644 100644 100644 ddd eee R100 Docs/After.md",
            "Docs/Before.md",
            "? notes.txt",
            "",
        ].joined(separator: "\0")
        var result = RepositoryStatus.parse(status: status)
        #expect(result.branch == "fix/iso-weeks")
        #expect(result.ahead == 2 && result.behind == 1)
        #expect(result.changes.map(\.path) == ["Sources/Notes/Date Parser.swift", "Tests/New.swift", "Docs/After.md", "notes.txt"])
        #expect(result.changes.map(\.kind) == [.modified, .added, .renamed, .untracked])

        result.apply(numstat: ["14\t3\tSources/Notes/Date Parser.swift", "9\t0\tTests/New.swift",
                               "1\t1\t", "Docs/Before.md", "Docs/After.md", ""].joined(separator: "\0"))
        #expect(result.changes[0].added == 14 && result.changes[0].removed == 3)
        #expect(result.changes[1].added == 9)
        #expect(result.changes[2].added == 1)
        #expect(result.changes[3].added == nil)
    }

    @Test func detachedHeadHasNoBranch() {
        #expect(RepositoryStatus.parse(status: "# branch.head (detached)\0").branch == nil)
    }

    @Test(.enabled(if: Git.executable != nil)) func readsARealRepository() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kuri-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let git = { (arguments: [String]) in
            await Git.run(Git.executable!, ["-C", folder.path(percentEncoded: false), "-c", "user.name=Kuri",
                                            "-c", "user.email=kuri@example.invalid"] + arguments)
        }
        _ = await git(["init", "-q", "-b", "main"])
        try "one\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = await git(["add", "."])
        _ = await git(["commit", "-q", "-m", "First"])
        try "one\ntwo\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: folder.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let status = try #require(await RepositoryStatus.read(at: folder.path(percentEncoded: false)))
        #expect(status.branch == "main")
        #expect(status.lastCommit?.subject == "First")
        let a = try #require(status.changes.first { $0.path == "a.txt" })
        #expect(a.kind == .modified && a.added == 1 && a.removed == 0)
        #expect(status.changes.first { $0.path == "b.txt" }?.kind == .untracked)

        // Not a repository.
        let plain = FileManager.default.temporaryDirectory.appending(path: "kuri-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(await RepositoryStatus.read(at: plain.path(percentEncoded: false)) == nil)
    }
}

extension EngineTests {
    @Test func usersTaskListEditBecomesTheCurrentList() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(home: home, store: try Store(url: home.database),
                            config: Config(generateTitles: false), mcpConfig: MCPConfig(), factory: ProviderFactory())
        await engine.start()
        defer { Task { await engine.shutdown() } }

        let conversation = try await engine.newConversation()
        let entries = [TaskListTool.Entry(content: "Reproduce", status: .completed),
                       TaskListTool.Entry(content: "Fix it", status: .pending)]
        try await engine.editTaskList(entries, in: conversation.id)

        let items = try await engine.store.items(of: conversation.id)
        #expect(TaskListTool.current(in: items) == entries)
        // A call and its result, side by side: a valid history for providers.
        guard items.count == 2, case .toolCall(let call) = items[0].payload, case .toolResult(let result) = items[1].payload
        else {
            Issue.record("expected a call and its result")
            return
        }
        #expect(TaskListTool.isUserEdit(call))
        #expect(result.callID == call.id && !result.isError)
        // Characters every provider takes as a call id.
        #expect(call.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    }

    @Test func contextUsageAddsUp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "kuri-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = KuriHome(root: root)
        try home.prepare()
        let engine = Engine(home: home, store: try Store(url: home.database),
                            config: Config(generateTitles: false), mcpConfig: MCPConfig(), factory: ProviderFactory())
        await engine.start()
        defer { Task { await engine.shutdown() } }
        let conversation = try await engine.newConversation()
        try await engine.store.append(Item(conversationID: conversation.id, payload: .message(Message(role: .user, text: String(repeating: "a", count: 400)))))
        try await engine.store.append(Item(conversationID: conversation.id, payload: .toolCall(ToolCall(id: "c1", name: "shell", arguments: #"{"command":"ls"}"#))))
        try await engine.store.append(Item(conversationID: conversation.id, payload: .toolResult(ToolResult(callID: "c1", output: String(repeating: "b", count: 800)))))
        let usage = try await engine.contextUsage(conversation.id)
        #expect(usage.messages > 90 && usage.toolOutput > 190)
        #expect(usage.system > 0)
        #expect(abs(usage.system + usage.memory + usage.messages + usage.toolOutput - usage.tokens) <= 2)
    }
}
