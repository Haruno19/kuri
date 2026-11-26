import AppKit
import Darwin
import Foundation
import KuriAgent
import KuriConfig
import KuriCore

/// `kuri`: Kuri in the terminal, a client with its own engine on the same
/// home folder as the app (decision 0028).
@main
enum Main {
    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst())))
    }

    /// How long kuri waits for Kuri to quit when asked to.
    static let appQuitWait: Duration = .seconds(30)
    static let lockPoll: Duration = .milliseconds(250)

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
            engine = try await openEngine(titles: !invocation.print, offeringToQuitTheApp: !invocation.print)
        } catch is Cancelled {
            return 1
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

    /// Opens the engine. If the app has the home folder, kuri can ask it to
    /// quit, as you'd quit it yourself, and go on once it has: at a
    /// terminal, and never for `-p`, which a script may be running.
    private static func openEngine(titles: Bool, offeringToQuitTheApp offering: Bool) async throws -> Engine {
        do {
            return try await Engine.open(blocks: [], titles: titles)
        } catch KuriError.homeInUse(let home, let holder, let pid?)
                    where offering && isatty(STDIN_FILENO) == 1 && Stream.err.isTerminal {
            // The id came from the lock: make sure it's still Kuri's.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  HomeLock.executable(of: pid)?.path.hasSuffix(".app/Contents/MacOS/Kuri") == true
            else { throw KuriError.homeInUse(home: home, holder: holder, pid: pid) }
            Stream.err.write("Kuri is open, and only one can use \(home) at a time. Quit it? "
                             + Stream.err.style("[y/N]", .dim) + " ")
            guard let reply = readLine(), ["y", "yes"].contains(reply.lowercased().trimmingCharacters(in: .whitespaces)) else {
                throw Cancelled()
            }
            app.terminate()
            Stream.err.line(Stream.err.style("Waiting for Kuri to quit…", .dim))
            let deadline = ContinuousClock.now + appQuitWait
            while true {
                do {
                    return try await Engine.open(blocks: [], titles: titles)
                } catch KuriError.homeInUse where ContinuousClock.now < deadline {
                    try await Task.sleep(for: lockPoll)
                }
            }
        }
    }
}
