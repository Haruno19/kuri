import Darwin
import Foundation
import KuriAgent
import KuriCore

/// `kuri`: Kuri in the terminal, a client with its own engine on the same
/// home folder as the app (decision 0028).
@main
enum Main {
    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst())))
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func run(_ arguments: [String]) async -> Int32 {
        let invocation: Invocation
        do {
            invocation = try Invocation.parse(arguments)
        } catch {
            Stream.err.line("kuri: \(Session.message(error))")
            Stream.err.line("Run kuri --help for usage.")
            return 2
        }
        switch invocation.command {
        case .help:
            Stream.out.line(Invocation.help)
            return 0
        case .version:
            Stream.out.line("kuri \(version)")
            return 0
        default:
            break
        }

        var prompt = invocation.prompt
        if invocation.print {
            // Piped stdin joins the prompt: `git diff | kuri -p "review this"`.
            if isatty(STDIN_FILENO) == 0,
               let piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !piped.isEmpty {
                prompt = [prompt, piped].compactMap(\.self).joined(separator: "\n\n")
            }
            guard let prompt, !prompt.isEmpty else {
                Stream.err.line("kuri: -p needs a prompt, as words or on stdin")
                return 2
            }
        }

        let engine: Engine
        do {
            // `-p` exits as its turn ends, so it asks for no title (decision 0028).
            engine = try await Engine.open(blocks: [], titles: !invocation.print)
        } catch {
            Stream.err.line("kuri: \(error.localizedDescription)")
            return 1
        }
        let code: Int32 = switch invocation.command {
        case .models: await Commands.models(engine)
        case .sandbox(let action): await Commands.sandbox(action, engine)
        default: await Session(engine: engine, invocation: invocation, prompt: prompt).run()
        }
        await engine.shutdown()
        return code
    }
}
