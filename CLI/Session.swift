import Darwin
import Foundation
import KuriAgent
import KuriConfig
import KuriCore
import KuriMCP
import KuriStore
import KuriTools

/// A conversation in the terminal: a session of many turns, or one turn
/// with `-p`. Engine events, typed lines and signals all arrive as one
/// stream of inputs, handled in order on the main actor, so nothing races.
final class Session {
    enum Input: Sendable {
        case event(EngineEvent)
        case line(String)
        case keys([UInt8])
        case endOfInput
        case interrupt
        case terminate(Int32)
    }

    /// How long `-p` waits for MCP servers to connect before its turn, so
    /// the model sees their tools: each run starts them from cold.
    static let mcpWait: Duration = .seconds(10)
    static let mcpPoll: Duration = .milliseconds(50)
    /// Lines of a command's output shown as it runs; the rest are counted.
    static let outputLines = 8
    /// How much of a tool call's arguments an approval shows.
    static let argumentsShown = 240

    private let engine: Engine
    private let invocation: Invocation
    private let prompt: String?
    private let oneTurn: Bool
    /// The answer: stdout.
    private let answer = Stream.out
    /// Tool calls, notes and questions: stdout in a session. With `-p`,
    /// stdout carries only the answer, so they go to stderr, and only when
    /// it's a terminal.
    private let activity: Stream?
    private let typing = isatty(STDIN_FILENO) == 1
    private let inputs: AsyncStream<Input>
    private let feed: AsyncStream<Input>.Continuation
    private let events: AsyncStream<EngineEvent>
    private let signals = Signals()
    /// What's typed, in a session; paused while a `/shell` command runs.
    private var reader: InputReader?
    /// Draws what's typed while kuri waits for it, when both ends are a terminal.
    private var editor: LineEditor?
    /// A `/shell` command has the terminal: Ctrl-C is its, not the session's.
    private var shellRunning = false

    private var conversation: Conversation?
    /// For the conversation made on the first message.
    private var newModel: ModelRef?
    private var newFolders: [ConversationFolder] = []
    private var notes: [String] = []

    private var running = false
    private var queued = 0
    private var stopping = false
    private var quitAfterTurn = false
    private var done = false
    private var exitCode: Int32 = 0

    private enum Block { case answer, activity }
    private var lastBlock: Block?
    private var thinkingShown = false
    private var answerStreamed = false
    private var partialOutput: [String: String] = [:]
    private var shownOutput: [String: Int] = [:]
    private var hiddenOutput: [String: Int] = [:]
    private var reportedFailures: Set<String> = []

    /// The question being answered from stdin, in a session.
    private var request: InputRequest?
    private var answers: [String: String] = [:]
    private var questionIndex = 0

    init(engine: Engine, invocation: Invocation, prompt: String?) {
        self.engine = engine
        self.invocation = invocation
        self.prompt = prompt
        oneTurn = invocation.print
        activity = invocation.print ? (Stream.err.isTerminal ? Stream.err : nil) : Stream.out
        (inputs, feed) = AsyncStream.makeStream(of: Input.self)
        // Subscribed before anything starts, so no event is missed.
        events = engine.events()
    }

    func run() async -> Int32 {
        let feed = feed
        let events = events
        Task { for await event in events { feed.yield(.event(event)) } }
        signals.on(SIGINT) { [weak self] in self?.interruptRequested() }
        signals.on(SIGTERM) { feed.yield(.terminate(143)) }
        signals.on(SIGHUP) { feed.yield(.terminate(129)) }

        do {
            try await prepare()
        } catch is Cancelled {
            return 0
        } catch {
            Stream.err.line("kuri: \(Self.message(error))")
            return error is UsageError ? 2 : 1
        }

        if oneTurn {
            for note in notes { self.note(note) }
            await waitForMCP()
            await submit(prompt ?? "")
        } else {
            await showHeader(lastExchange: true)
            if typing, answer.isTerminal {
                _ = TerminalInput.original
                editor = LineEditor(stream: answer, commands: Set(Self.commands.map(\.0) + ["/help", "/quit"]))
            }
            let reader = InputReader()
            self.reader = reader
            Task {
                for await typed in reader.typed {
                    switch typed {
                    case .line(let line): feed.yield(.line(line))
                    case .keys(let keys): feed.yield(.keys(keys))
                    }
                }
                feed.yield(.endOfInput)
            }
            if let prompt {
                answer.blankLine()
                answer.write(answer.style("›", .bold) + " " + prompt + "\n")
                await submit(prompt)
            } else {
                showPrompt()
            }
        }

        for await input in inputs {
            await handle(input)
            if done { break }
        }
        editor?.finish()
        stopListening()
        farewell()
        return exitCode
    }

    // MARK: Starting

    private func prepare() async throws {
        if let model = invocation.model, await engine.config.providers[model.provider] == nil {
            throw KuriError.unknownProvider(model.provider)
        }
        switch invocation.resume {
        case nil:
            break
        case .latestHere:
            conversation = try await Conversations.latest(attachedTo: Folders.current, in: engine)
            if conversation == nil { notes.append("No conversation is attached to this folder yet: starting a new one.") }
        case .pick:
            guard typing else { throw UsageError(message: "-r without an id needs a terminal to choose in") }
            guard let picked = try await Conversations.pick(in: engine) else { throw Cancelled() }
            conversation = picked
        case .id(let prefix):
            conversation = try await Conversations.find(prefix, in: engine)
        }
        if var conversation, let model = invocation.model, conversation.model != model {
            conversation.model = model
            try await engine.update(conversation)
            self.conversation = conversation
        }
        if conversation == nil {
            newModel = invocation.model
            let (folders, note) = try Folders.forNewConversation(invocation)
            newFolders = folders
            if let note { notes.append(note) }
        }
    }

    /// On a clean screen: the session starts there, and `/clear` goes back
    /// to it. Only the start shows a resumed conversation's last exchange.
    private func showHeader(lastExchange: Bool) async {
        let config = await engine.config
        let model = conversation?.model ?? newModel ?? config.defaultModel
        let folders = (try? await currentFolders()) ?? []
        if answer.isTerminal {
            let place = folders.isEmpty ? "no folder" : folders.map(Folders.describe).joined(separator: ", ")
            answer.clearScreen()
            answer.write(Header.text([
                answer.style("Kuri", .bold) + " " + answer.style(Main.version, .dim),
                (model?.description ?? "no model: set defaultModel in config.json") + answer.style(" · ", .dim) + place,
                command("/help") + answer.style(" for commands · Ctrl-C stops a turn · Ctrl-D quits", .dim),
            ], on: answer))
        }
        guard lastExchange else { return }
        for note in notes { self.note(note) }
        if let conversation { await showLastExchange(of: conversation) }
    }

    /// A command's name, as `/help` and the header show it.
    private func command(_ name: String) -> String {
        answer.style(name, .bold, .accent)
    }

    /// What a resumed conversation was last about: its last message and the answer to it.
    private func showLastExchange(of conversation: Conversation) async {
        answer.blankLine()
        let title = conversation.title.isEmpty ? "Untitled" : conversation.title
        answer.line(answer.style("Continuing “\(title)”", .dim))
        guard let items = try? await engine.store.items(of: conversation.id),
              let last = items.lastIndex(where: { item in
                  if case .message(let message) = item.payload { message.role == .user } else { false }
              }),
              case .message(let question) = items[last].payload
        else { return }
        let reply = items[(last + 1)...].compactMap { item -> String? in
            if case .message(let message) = item.payload, message.role == .assistant { message.text } else { nil }
        }.joined(separator: "\n\n")
        answer.blankLine()
        answer.line(answer.style("›", .bold) + " " + question.text)
        if !reply.isEmpty {
            answer.blankLine()
            answer.line(reply)
        }
    }

    /// In `-p`, the model should see the MCP servers' tools, and they were
    /// only just started.
    private func waitForMCP() async {
        let deadline = ContinuousClock.now + Self.mcpWait
        while await engine.mcpServers().contains(where: { $0.state == .connecting }) {
            guard ContinuousClock.now < deadline else {
                note("Some MCP servers are still connecting; going on without them.")
                return
            }
            try? await Task.sleep(for: Self.mcpPoll)
        }
    }

    // MARK: Inputs

    private func handle(_ input: Input) async {
        switch input {
        case .event(let event):
            // Output goes where the prompt was, and the prompt under it.
            editor?.hide()
            await handle(event)
            editor?.show()
        case .line(let line):
            if typing { answer.inputEnded() }
            await handle(line: line)
        case .keys(let keys):
            guard let action = editor?.feed(keys) else { return }
            stopListening()
            switch action {
            case .submit(let line): await handle(line: line)
            case .interrupt: await interrupt()
            case .endOfInput: await handle(.endOfInput)
            }
        case .endOfInput:
            if let asked = request {
                // Quitting declines the question, so the turn can end.
                request = nil
                switch asked.kind {
                case .approval:
                    await engine.respond(to: asked.id, with: .approved(false))
                case .clarify(let clarify):
                    let none = Dictionary(uniqueKeysWithValues: clarify.questions.map { ($0.id, "") })
                    await engine.respond(to: asked.id, with: .answers(none))
                }
            }
            if running {
                quitAfterTurn = true
                note("Finishing this turn first; Ctrl-C stops it.")
            } else {
                done = true
            }
        case .interrupt:
            if typing { answer.controlEchoed() }
            await interrupt()
        case .terminate(let code):
            exitCode = code
            done = true
        }
    }

    /// Ctrl-C reaches every process in the terminal's foreground group, a
    /// `/shell` command and this one alike. The command deals with it; here
    /// it's dropped, rather than queued behind the command and acted on after.
    private func interruptRequested() {
        guard !shellRunning else { return }
        feed.yield(.interrupt)
    }

    private func interrupt() async {
        if running, let id = conversation?.id {
            if stopping {
                // A second Ctrl-C while the first is still stopping: leave now.
                exitCode = 130
                done = true
            } else {
                stopping = true
                await engine.cancel(id)
            }
        } else if oneTurn {
            exitCode = 130
            done = true
        } else {
            answer.endLine()
            note("Ctrl-D quits.")
            showPrompt()
        }
    }

    private func handle(line: String) async {
        if request != nil {
            await answerQuestion(line)
            return
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showPrompt()
            return
        }
        if let word = text.split(separator: " ").first, word.wholeMatch(of: /\/[a-z]+/) != nil {
            await command(text)
            return
        }
        await submit(text)
    }

    private func submit(_ text: String) async {
        do {
            let id = try await conversationForSending()
            let busy = await engine.runningConversations.contains(id)
            try await engine.send(text, to: id)
            if busy { note("Queued: it joins the turn at its next step.") }
        } catch {
            failure(error)
            if oneTurn {
                exitCode = 1
                done = true
            } else {
                showPrompt()
            }
        }
    }

    /// The conversation is made with the first message, so a session left
    /// without one leaves nothing behind.
    private func conversationForSending() async throws -> UUID {
        if let conversation { return conversation.id }
        let created = try await engine.newConversation(model: newModel)
        if !newFolders.isEmpty { try await engine.setFolders(newFolders, for: created.id) }
        conversation = created
        return created.id
    }

    private func currentFolders() async throws -> [ConversationFolder] {
        if let conversation { return try await engine.folders(of: conversation.id) }
        return newFolders
    }

    // MARK: Events

    private func handle(_ event: EngineEvent) async {
        let ours = conversation?.id
        switch event {
        case .conversationUpdated(let updated) where updated.id == ours:
            conversation = updated
        case .turnStarted(let turn) where turn.conversationID == ours:
            running = true
            stopping = false
            thinkingShown = false
            answerStreamed = false
        case .inference(let id, let inference) where id == ours:
            render(inference)
        case .itemAdded(let item) where item.conversationID == ours:
            render(item)
        case .toolOutput(let id, let callID, let text) where id == ours:
            output(text, of: callID)
        case .toolFinished(let id, let call, let result) where id == ours:
            finished(call, result)
        case .inputRequested(let asked) where asked.conversationID == ours:
            await ask(asked)
        case .inputResolved(let requestID) where requestID == request?.id:
            // Answered elsewhere, or the turn was stopped.
            request = nil
            editor?.finish()
            stopListening()
        case .modelFallback(let id, let from, let to, let reason) where id == ours:
            note("\(from) failed (\(reason)); \(to) takes over.")
        case .compacting(let id, let on) where id == ours && running:
            note(on ? "Summarising the conversation to make room…" : "Summarised.")
        case .queueChanged(let id, let queue) where id == ours:
            queued = queue.count
        case .turnFinished(let id, _, let outcome) where id == ours:
            finish(outcome)
        case .mcpServersChanged(let servers):
            for server in servers {
                guard case .failed(let reason) = server.state, !reportedFailures.contains(server.name) else { continue }
                reportedFailures.insert(server.name)
                note("MCP server \(server.name) failed: \(reason)")
            }
        case .configFailed(let message):
            note(message)
        default:
            break
        }
    }

    private func render(_ inference: InferenceEvent) {
        switch inference {
        case .textDelta(let text):
            begin(.answer, on: answer)
            answer.write(text)
            answerStreamed = true
            thinkingShown = false
        case .reasoningDelta:
            guard !thinkingShown, let activity else { return }
            thinkingShown = true
            begin(.activity, on: activity)
            activity.line(activity.style("thinking…", .dim, .italic))
        default:
            break
        }
    }

    private func render(_ item: Item) {
        switch item.payload {
        case .message(let message) where message.role == .assistant:
            // Some providers send the whole text at once, with no deltas.
            if !answerStreamed, !message.text.isEmpty {
                begin(.answer, on: answer)
                answer.write(message.text)
            }
            answerStreamed = false
        case .toolCall(let call):
            show(call)
        default:
            break
        }
        thinkingShown = false
    }

    private func show(_ call: ToolCall) {
        guard let activity else { return }
        let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .null
        let line: String
        switch call.name {
        case "shell":
            let command = arguments["command"]?.stringValue ?? ""
            let lines = command.split(whereSeparator: \.isNewline)
            line = activity.style("$", .dim) + " " + (lines.first.map(String.init) ?? "") + (lines.count > 1 ? activity.style(" …", .dim) : "")
        case "tasklist":
            let entries = TaskListTool.entries(fromArguments: call.arguments) ?? []
            begin(.activity, on: activity)
            for entry in entries {
                switch entry.status {
                case .pending: activity.line(activity.style("○", .dim) + " " + entry.content)
                case .inProgress: activity.line(activity.style("◐", .yellow) + " " + entry.content)
                case .completed: activity.line(activity.style("● " + entry.content, .dim))
                }
            }
            return
        case "clarify":
            return
        case "memory":
            line = activity.style("•", .dim) + " Change memory"
        case "conversation_search":
            let query = arguments["query"]?.stringValue.map { " for “\($0)”" } ?? ""
            line = activity.style("•", .dim) + " Search conversations\(query)"
        default:
            line = activity.style("•", .dim) + " " + Self.toolName(call.name)
        }
        begin(.activity, on: activity)
        activity.line(line)
    }

    /// A running command's output, line by line: a chunk can end mid-line.
    private func output(_ text: String, of callID: String) {
        var buffer = partialOutput[callID, default: ""] + text
        while let end = buffer.firstIndex(where: \.isNewline) {
            outputLine(String(buffer[..<end]), of: callID)
            buffer = String(buffer[buffer.index(after: end)...])
        }
        partialOutput[callID] = buffer
    }

    private func outputLine(_ text: String, of callID: String) {
        guard let activity else { return }
        let shown = shownOutput[callID, default: 0]
        guard shown < Self.outputLines else {
            hiddenOutput[callID, default: 0] += 1
            return
        }
        shownOutput[callID] = shown + 1
        begin(.activity, on: activity)
        activity.line(activity.style("  │ ", .dim) + activity.style(text, .dim))
    }

    private func finished(_ call: ToolCall, _ result: ToolOutput) {
        if let rest = partialOutput.removeValue(forKey: call.id), !rest.isEmpty { outputLine(rest, of: call.id) }
        let lines = result.text.split(whereSeparator: \.isNewline).map(String.init)
        if call.name == "shell" {
            // A quick command may print nothing live; its result still has the output.
            if shownOutput[call.id] == nil {
                for line in lines.dropFirst() where line != "(no output)" { outputLine(line, of: call.id) }
            }
            if let hidden = hiddenOutput.removeValue(forKey: call.id), let activity {
                activity.line(activity.style("  │ … \(hidden) more line\(hidden == 1 ? "" : "s")", .dim))
            }
            shownOutput[call.id] = nil
            if let status = lines.first, let activity {
                if let code = status.firstMatch(of: /^Exit code (-?\d+)\./)?.1, code != "0" {
                    activity.line(activity.style("  ✗ exit \(code)", .red))
                } else if result.isError {
                    activity.line(activity.style("  ✗ \(status)", .red))
                }
            }
        } else if result.isError, let activity {
            activity.line(activity.style("  ✗ \(lines.first ?? "failed")", .red))
        }
    }

    private func finish(_ outcome: TurnOutcome) {
        running = false
        stopping = false
        answer.endLine()
        switch outcome {
        case .completed(.maxTokens):
            note("The answer reached the model's output limit.")
        case .completed:
            break
        case .failed(let message):
            failure(message)
            if oneTurn { exitCode = 1 }
        case .cancelled:
            note("Stopped.")
            if oneTurn { exitCode = 130 }
        }
        if oneTurn || quitAfterTurn {
            done = true
        } else if queued == 0 {
            showPrompt()
        }
    }

    // MARK: Questions

    private func ask(_ asked: InputRequest) async {
        if oneTurn {
            askOnTTY(asked)
            return
        }
        request = asked
        answers = [:]
        questionIndex = 0
        switch asked.kind {
        case .approval(let approval):
            begin(.activity, on: answer)
            answer.line(answer.style("?", .yellow) + " Allow \(describe(approval))? " + answer.style("[y/N]", .dim))
            listenForAnswer()
        case .clarify(let clarify):
            showQuestion(clarify.questions[0])
        }
    }

    private func showQuestion(_ question: ClarifyRequest.Question) {
        begin(.activity, on: answer)
        answer.line(answer.style("?", .yellow) + " " + question.question)
        for (index, option) in (question.options ?? []).enumerated() {
            answer.line(answer.style("  \(index + 1).", .dim) + " " + option)
        }
        listenForAnswer()
    }

    private func listenForAnswer() {
        listen(LineEditor.Prompt(text: "  › ", styled: answer.style("  ›", .bold) + " "), commands: false)
    }

    private func answerQuestion(_ line: String) async {
        guard let asked = request else { return }
        let text = line.trimmingCharacters(in: .whitespaces)
        switch asked.kind {
        case .approval:
            request = nil
            await engine.respond(to: asked.id, with: .approved(["y", "yes"].contains(text.lowercased())))
        case .clarify(let clarify):
            let question = clarify.questions[questionIndex]
            answers[question.id] = Self.choice(text, from: question.options)
            questionIndex += 1
            if questionIndex < clarify.questions.count {
                showQuestion(clarify.questions[questionIndex])
            } else {
                request = nil
                await engine.respond(to: asked.id, with: .answers(answers))
            }
        }
    }

    /// `-p` has stdin and stdout taken, so it asks on the terminal itself,
    /// or, with none, declines (decision 0028). Asked in a task of its own:
    /// Ctrl-C must still reach the session while the question waits.
    private func askOnTTY(_ asked: InputRequest) {
        let engine = engine
        guard TTY.isAvailable else {
            switch asked.kind {
            case .approval(let approval):
                note("Declined \(describe(approval)): there's no terminal to ask on.")
                Task { await engine.respond(to: asked.id, with: .approved(false)) }
            case .clarify(let clarify):
                let none = Dictionary(uniqueKeysWithValues: clarify.questions.map {
                    ($0.id, "(No answer: kuri -p had no terminal to ask on.)")
                })
                Task { await engine.respond(to: asked.id, with: .answers(none)) }
            }
            return
        }
        switch asked.kind {
        case .approval(let approval):
            let prompt = "Allow \(describe(approval))? [y/N] "
            Task {
                let reply = await TTY.ask(prompt) ?? ""
                await engine.respond(to: asked.id, with: .approved(["y", "yes"].contains(reply.lowercased())))
            }
        case .clarify(let clarify):
            Task {
                var answers: [String: String] = [:]
                for question in clarify.questions {
                    let options = (question.options ?? []).enumerated().map { "  \($0.offset + 1). \($0.element)\n" }.joined()
                    let reply = await TTY.ask("? \(question.question)\n\(options)  › ") ?? ""
                    answers[question.id] = Self.choice(reply, from: question.options)
                }
                await engine.respond(to: asked.id, with: .answers(answers))
            }
        }
    }

    private func describe(_ approval: ApprovalRequest) -> String {
        var arguments = approval.arguments
        if approval.tool == "shell",
           let command = (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)))?["command"]?.stringValue {
            return "running `\(command)`"
        }
        if arguments.count > Self.argumentsShown { arguments = String(arguments.prefix(Self.argumentsShown)) + "…" }
        return "\(Self.toolName(approval.tool)) \(arguments)"
    }

    /// An option's number picks it; anything else is the answer as written.
    private static func choice(_ text: String, from options: [String]?) -> String {
        if let options, let number = Int(text), options.indices.contains(number - 1) { return options[number - 1] }
        return text
    }

    /// MCP tools are named `<server>__<tool>`.
    static func toolName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count > 1 ? "\(parts[0]) › \(parts.dropFirst().joined(separator: "__"))" : name
    }

    // MARK: Commands

    /// Name, arguments, what it does: as `/help` lists them.
    static let commands = [
        ("/model", "[provider/model]", "show the models, or switch this conversation's"),
        ("/folders", "[add|remove <path>]", "show the attached folders, or change them (add --read-only <path>)"),
        ("/shell", "<command>", "run a command in your own shell, in this folder"),
        ("/compact", "", "summarise the conversation to make room"),
        ("/retry", "", "answer the last message again"),
        ("/new", "", "start a new conversation"),
        ("/clear", "", "clear the screen; the conversation goes on"),
        ("/exit", "", "quit (Ctrl-D does too)"),
    ]

    private func command(_ text: String) async {
        let parts = text.split(separator: " ", maxSplits: 1)
        let name = String(parts[0])
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        var startsTurn = false
        do {
            switch name {
            case "/help":
                begin(.activity, on: answer)
                let width = Self.commands.map { $0.0.count + 1 + $0.1.count }.max() ?? 0
                for (name, arguments, summary) in Self.commands {
                    let padding = String(repeating: " ", count: width - name.count - 1 - arguments.count + 3)
                    answer.line(command(name) + " " + arguments + padding + answer.style(summary, .dim))
                }
            case "/clear":
                await showHeader(lastExchange: false)
            case "/shell":
                guard let argument, !argument.isEmpty else { throw UsageError(message: "Usage: /shell <command>") }
                await runShell(argument)
            case "/exit", "/quit":
                done = true
                return
            case "/new":
                guard !running else { throw UsageError(message: "Stop this turn first (Ctrl-C).") }
                if let previous = conversation {
                    newFolders = try await engine.folders(of: previous.id)
                    newModel = previous.model
                }
                conversation = nil
                note("New conversation.")
            case "/model":
                try await model(argument)
            case "/folders":
                try await folders(argument)
            case "/compact":
                guard let id = conversation?.id else { throw UsageError(message: "Nothing to summarise yet.") }
                note("Summarising…")
                try await engine.compact(id)
                note("Summarised.")
            case "/retry":
                guard let id = conversation?.id else { throw UsageError(message: "Nothing to retry yet.") }
                try await engine.retry(id)
                startsTurn = true
            default:
                throw UsageError(message: "Unknown command \(name). /help lists them.")
            }
        } catch {
            failure(error)
        }
        if !startsTurn { showPrompt() }
    }

    private func model(_ argument: String?) async throws {
        let config = await engine.config
        let current = conversation?.model ?? newModel ?? config.defaultModel
        guard let argument else {
            begin(.activity, on: answer)
            let models = await engine.models
            if models.isEmpty { answer.line("No models yet: add one in Kuri's Settings › Models.") }
            for model in models {
                answer.line(model == current ? answer.style("● \(model)", .bold) : answer.style("○", .dim) + " \(model)")
            }
            return
        }
        guard let model = ModelRef(argument) else {
            throw UsageError(message: "A model is provider/model, as in config.json.")
        }
        guard config.providers[model.provider] != nil else { throw KuriError.unknownProvider(model.provider) }
        if var conversation {
            conversation.model = model
            try await engine.update(conversation)
            self.conversation = conversation
        } else {
            newModel = model
        }
        note("Model: \(model)")
    }

    private func folders(_ argument: String?) async throws {
        var folders = try await currentFolders()
        guard let argument else {
            begin(.activity, on: answer)
            if folders.isEmpty { answer.line("No folders attached.") }
            for folder in folders { answer.line(Folders.describe(folder)) }
            return
        }
        guard !running else { throw UsageError(message: "Stop this turn first (Ctrl-C).") }
        var words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let action = words.removeFirst()
        var path = words.first ?? ""
        var readOnly = false
        if path.hasPrefix("--read-only") {
            readOnly = true
            path = String(path.dropFirst("--read-only".count)).trimmingCharacters(in: .whitespaces)
        }
        guard !path.isEmpty else { throw UsageError(message: "Usage: /folders add [--read-only] <path>, /folders remove <path>") }
        let resolved = try Folders.resolve(path)
        switch action {
        case "add":
            folders.removeAll { Folders.same($0.path, resolved) }
            folders.append(ConversationFolder(path: resolved, readOnly: readOnly))
        case "remove":
            let before = folders.count
            folders.removeAll { Folders.same($0.path, resolved) }
            guard folders.count < before else { throw UsageError(message: "\(Folders.display(resolved)) isn't attached.") }
        default:
            throw UsageError(message: "Usage: /folders add [--read-only] <path>, /folders remove <path>")
        }
        if let conversation {
            try await engine.setFolders(folders, for: conversation.id)
        } else {
            newFolders = folders
        }
        note(folders.isEmpty ? "No folders attached." : "Folders: " + folders.map(Folders.describe).joined(separator: ", "))
    }

    /// Runs `command` with your login shell's binary, in this folder, on the
    /// terminal itself: its output isn't captured and it can be interactive
    /// (an editor, a pager). Nothing of it goes into the conversation.
    /// Engine events wait meanwhile, so a running turn's output can't land
    /// in the middle of the command's.
    private func runShell(_ command: String) async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        answer.blankLine()
        reader?.switchTo(.paused)
        shellRunning = true
        let ending = await ForegroundCommand.run([shell, "-c", command], in: Folders.current)
        shellRunning = false
        reader?.switchTo(.lines)
        answer.othersWrote()
        switch ending {
        case nil:
            failure("Couldn't start \(shell).")
        case .signalled(SIGINT):
            note("Interrupted.")
        case .signalled(let signal):
            failure("Ended by signal \(signal).")
        case .exited(let status):
            if status != 0 { failure("exit \(status)") }
        }
    }

    // MARK: Output

    /// A blank line between an answer and the activity around it.
    private func begin(_ block: Block, on stream: Stream) {
        if lastBlock != block { stream.blankLine() }
        lastBlock = block
    }

    private func note(_ text: String) {
        guard let stream = activity ?? (oneTurn ? Stream.err : nil) else { return }
        begin(.activity, on: stream)
        stream.line(stream.style(text, .dim))
    }

    private func failure(_ error: any Error) {
        failure(Self.message(error))
    }

    private func failure(_ message: String) {
        let stream = activity ?? Stream.err
        guard stream.isTerminal else {
            // A log or a pipe reads it like any command's error.
            stream.line("kuri: \(message)")
            return
        }
        begin(.activity, on: stream)
        stream.line(stream.style("✗ \(message)", .red))
    }

    private func showPrompt() {
        // During a turn its end shows the prompt.
        guard !oneTurn, typing, !done, !running else { return }
        answer.blankLine()
        lastBlock = nil
        listen(LineEditor.Prompt(text: "› ", styled: answer.style("›", .bold) + " "), commands: true)
    }

    /// Waits for a line after `prompt`: in the line editor, or, when it
    /// can't draw, with the terminal echoing as it does.
    private func listen(_ prompt: LineEditor.Prompt, commands: Bool) {
        guard let editor, let reader else {
            answer.write(prompt.styled)
            return
        }
        reader.switchTo(.keys) { TerminalInput.keys() }
        editor.begin(prompt, commands: commands)
        if let keys = editor.takeTypeahead() { feed.yield(.keys(keys)) }
    }

    /// The terminal back to its own line editing, as kuri found it.
    private func stopListening() {
        reader?.switchTo(.lines) { TerminalInput.lines() }
    }

    private func farewell() {
        guard !oneTurn, answer.isTerminal, let id = conversation?.id else { return }
        answer.blankLine()
        answer.line(answer.style("Resume with kuri -r \(id.uuidString.lowercased().prefix(8))", .dim))
    }

    static func message(_ error: any Error) -> String {
        if let usage = error as? UsageError { return usage.message }
        return error.localizedDescription
    }
}

/// The user backed out of a choice: not an error.
struct Cancelled: Error {}
