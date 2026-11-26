import Foundation
import JavaScriptCore
import Testing

/// The code references in docs/flows.html point at real lines: every step
/// names the line that does it ('path:line: code'), and that line still
/// holds the code. When code moves, `python3 docs/sync-flow-refs.py`
/// updates the line numbers.
@Suite struct FlowReferenceTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fix = "run `python3 docs/sync-flow-refs.py`, or fix the reference by hand"

    let page: String

    init() throws {
        page = try String(contentsOf: Self.root.appending(path: "docs/flows.html"), encoding: .utf8)
    }

    @Test func everyReferenceHoldsItsCode() throws {
        let references = try Regex(#"'([\w/.]+\.swift):(\d+): ((?:[^'\\]|\\.)*)'"#)
        var files: [String: [String]] = [:]
        var count = 0
        for match in page.matches(of: references) {
            count += 1
            let path = String(match.output[1].substring!)
            let line = Int(match.output[2].substring!)!
            let code = String(match.output[3].substring!).replacing(#/\\(.)/#) { String($0.output.1) }
            let base = path.hasPrefix("App/") || path.hasPrefix("CLI/") ? Self.root : Self.root.appending(path: "Packages/KuriKit/Sources")
            guard let lines = try files[path] ?? (try? String(contentsOf: base.appending(path: path), encoding: .utf8))
                .map({ $0.components(separatedBy: "\n") })
            else {
                Issue.record("\(path): no such file")
                continue
            }
            files[path] = lines
            if line <= lines.count, lines[line - 1].contains(code) { continue }
            let actual = lines.indices.filter { lines[$0].contains(code) }.map { String($0 + 1) }
            Issue.record(actual.isEmpty
                ? "\(path):\(line): “\(code)” is gone; fix the reference by hand"
                : "\(path):\(line): “\(code)” is now at line \(actual.joined(separator: ", ")); \(Self.fix)")
        }
        #expect(count > 100)
    }

    /// The flows are data in the page's script: one stray quote or a lost
    /// brace and no diagram draws, while every reference above still reads.
    @Test func pageScriptParses() throws {
        let start = try #require(page.range(of: "<script>"))
        let end = try #require(page.range(of: "</script>", range: start.upperBound..<page.endIndex))
        let script = String(page[start.upperBound..<end.lowerBound])
        let line = page[..<start.upperBound].count { $0 == "\n" } + 1
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let source = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        if !JSCheckScriptSyntax(context, source, nil, Int32(line), &exception) {
            let error = JSValueToStringCopy(context, exception, nil)
            defer { error.map(JSStringRelease) }
            let lineValue = JSObjectGetProperty(context, JSValueToObject(context, exception, nil),
                                                JSStringCreateWithCFString("line" as CFString), nil)
            let message = error.map { JSStringCopyCFString(nil, $0) as String } ?? "syntax error"
            Issue.record("docs/flows.html:\(Int(JSValueToNumber(context, lineValue, nil))): \(message)")
        }
    }

    @Test func everyStepInsideKuriHasAReference() throws {
        // Participants: `id: ["Label", "module", "kind"],`
        let participant = try Regex(#"(?m)^\s*([a-z]+):\s*\["[^"]*", "[^"]*", "([a-z]+)"\]"#)
        var kinds: [String: String] = [:]
        for match in page.matches(of: participant) {
            kinds[String(match.output[1].substring!)] = String(match.output[2].substring!)
        }
        let outside: Set<String> = ["actor", "external"]
        #expect(kinds["engine"] == "agent")

        let step = try Regex(#"\["([a-z]+)", "([a-z]+)", "(?:[^"\\]|\\.)*"(?:, "[a-z]")?(, '(?:[^'\\]|\\.)*')?\]"#)
        var steps = 0
        for match in page.matches(of: step) {
            steps += 1
            let from = String(match.output[1].substring!), to = String(match.output[2].substring!)
            guard match.output[3].substring == nil else { continue }
            if let a = kinds[from], let b = kinds[to], outside.contains(a), outside.contains(b) { continue }
            Issue.record("step \(from) → \(to) has no code reference: \(page[match.range].prefix(120))")
        }
        #expect(steps > 100)
    }
}
