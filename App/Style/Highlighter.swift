import SwiftUI

/// What a stretch of code is, as far as colouring goes.
enum CodeToken {
    case plain, keyword, declaration, type, function, string, number, comment, module, `operator`
    case variable, key, tag, attribute, inserted, deleted, section
}

/// A small, forgiving highlighter: one pass that knows comments, strings,
/// numbers, keywords and a few shapes (calls, capitalised types, keys
/// before a colon) for the languages a model writes most. It aims to look
/// right, not to parse.
enum Highlighter {
    private static let cache: NSCache<NSString, Highlighted> = {
        let cache = NSCache<NSString, Highlighted>()
        cache.countLimit = 120
        return cache
    }()

    private final class Highlighted {
        let string: AttributedString
        init(_ string: AttributedString) { self.string = string }
    }

    static func highlighted(_ code: String, language: String?, theme: CodeTheme) -> AttributedString {
        let key = "\(theme.dark ? 1 : 0)\(language ?? "")\u{0}\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit.string }
        var out = AttributedString()
        for (text, token) in tokens(code, language: language) {
            var piece = AttributedString(text)
            piece.foregroundColor = theme.color(token)
            if token == .comment { piece.inlinePresentationIntent = .emphasized }
            out.append(piece)
        }
        cache.setObject(Highlighted(out), forKey: key)
        return out
    }

    /// The code split into coloured stretches; consecutive stretches of the
    /// same kind are merged.
    static func tokens(_ code: String, language: String?) -> [(String, CodeToken)] {
        let grammar = Grammar.named(language)
        let s = Array(code.unicodeScalars)
        var spans: [(Int, Int, CodeToken)] = []
        switch grammar.mode {
        case .diff: diff(s, into: &spans)
        case .markup: markup(s, into: &spans)
        case .code: Scanner(s: s, g: grammar).run(into: &spans)
        }
        var out: [(String, CodeToken)] = []
        var view = String.UnicodeScalarView()
        var current: CodeToken?
        for (start, end, token) in spans where end > start {
            if token != current, let current {
                out.append((String(view), current))
                view = String.UnicodeScalarView()
            }
            current = token
            view.append(contentsOf: s[start..<end])
        }
        if let current { out.append((String(view), current)) }
        return out
    }

    // MARK: Diffs and markup

    private static func diff(_ s: [Unicode.Scalar], into spans: inout [(Int, Int, CodeToken)]) {
        var i = 0
        while i < s.count {
            var end = i
            while end < s.count && s[end] != "\n" { end += 1 }
            if end < s.count { end += 1 }
            let token: CodeToken = switch s[i] {
            case "+": .inserted
            case "-": .deleted
            case "@": .section
            default: .plain
            }
            spans.append((i, end, token))
            i = end
        }
    }

    private static func markup(_ s: [Unicode.Scalar], into spans: inout [(Int, Int, CodeToken)]) {
        var i = 0
        func starts(_ text: String, at k: Int) -> Bool {
            let t = Array(text.unicodeScalars)
            return k + t.count <= s.count && Array(s[k..<(k + t.count)]) == t
        }
        while i < s.count {
            if starts("<!--", at: i) {
                var end = i + 4
                while end < s.count && !starts("-->", at: end) { end += 1 }
                end = min(s.count, end + 3)
                spans.append((i, end, .comment))
                i = end
            } else if s[i] == "<" {
                spans.append((i, i + 1, .plain))
                var k = i + 1
                if k < s.count && (s[k] == "/" || s[k] == "!" || s[k] == "?") { spans.append((k, k + 1, .plain)); k += 1 }
                let nameStart = k
                while k < s.count && (Scanner.isWord(s[k]) || s[k] == "-" || s[k] == ":") { k += 1 }
                spans.append((nameStart, k, .tag))
                // Attributes until the tag closes.
                while k < s.count && s[k] != ">" {
                    if s[k] == "\"" || s[k] == "'" {
                        let quote = s[k]
                        var end = k + 1
                        while end < s.count && s[end] != quote { end += 1 }
                        end = min(s.count, end + 1)
                        spans.append((k, end, .string))
                        k = end
                    } else if Scanner.isWord(s[k]) {
                        let start = k
                        while k < s.count && (Scanner.isWord(s[k]) || s[k] == "-" || s[k] == ":") { k += 1 }
                        spans.append((start, k, .attribute))
                    } else {
                        spans.append((k, k + 1, .plain))
                        k += 1
                    }
                }
                if k < s.count { spans.append((k, k + 1, .plain)); k += 1 }
                i = k
            } else {
                spans.append((i, i + 1, .plain))
                i += 1
            }
        }
    }
}

// MARK: - Code

private struct Scanner {
    let s: [Unicode.Scalar]
    let g: Grammar

    static func isWord(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c.properties.isAlphabetic || ("0"..."9").contains(c)
    }

    func starts(_ token: [Unicode.Scalar], at i: Int) -> Bool {
        guard !token.isEmpty, i + token.count <= s.count else { return false }
        for k in 0..<token.count where s[i + k] != token[k] { return false }
        return true
    }

    func run(into spans: inout [(Int, Int, CodeToken)]) {
        let lineComments = g.lineComments.map { Array($0.unicodeScalars) }
        let blockOpen = g.blockComment.map { Array($0.0.unicodeScalars) } ?? []
        let blockClose = g.blockComment.map { Array($0.1.unicodeScalars) } ?? []
        var i = 0
        var previousWord = ""
        // Shell: whether the next word is a command.
        var commandPosition = true

        while i < s.count {
            let c = s[i]

            if c == "\n" {
                spans.append((i, i + 1, .plain))
                i += 1
                commandPosition = true
                continue
            }

            if starts(blockOpen, at: i) {
                var end = i + blockOpen.count
                while end < s.count && !starts(blockClose, at: end) { end += 1 }
                end = min(s.count, end + blockClose.count)
                spans.append((i, end, .comment))
                i = end
                continue
            }

            // `#` starts a shell comment only at the start of a word.
            if lineComments.contains(where: { starts($0, at: i) }),
               !(g.shell && i > 0 && !s[i - 1].properties.isWhitespace) {
                var end = i
                while end < s.count && s[end] != "\n" { end += 1 }
                spans.append((i, end, .comment))
                i = end
                continue
            }

            if g.quotes.contains(c) {
                let end = stringEnd(from: i)
                let isKey = g.keysBeforeColon && followedByColon(end)
                spans.append((i, end, isKey ? .key : .string))
                i = end
                commandPosition = false
                continue
            }

            if g.shell && c == "$" && i + 1 < s.count {
                var end = i + 1
                if s[end] == "{" {
                    while end < s.count && s[end] != "}" && s[end] != "\n" { end += 1 }
                    end = min(s.count, end + 1)
                } else {
                    while end < s.count && (Scanner.isWord(s[end]) || "?#@!*".unicodeScalars.contains(s[end])) { end += 1 }
                }
                if end > i + 1 {
                    spans.append((i, end, .variable))
                    i = end
                    continue
                }
            }

            if g.shell && c == "-" && (i == 0 || s[i - 1].properties.isWhitespace) {
                var end = i
                while end < s.count && !s[end].properties.isWhitespace { end += 1 }
                spans.append((i, end, .plain))
                i = end
                continue
            }

            if let prefix = g.attributePrefix, c == prefix, i + 1 < s.count, s[i + 1].properties.isAlphabetic {
                var end = i + 1
                while end < s.count && (Scanner.isWord(s[end]) || s[end] == ".") { end += 1 }
                spans.append((i, end, .attribute))
                i = end
                continue
            }

            if ("0"..."9").contains(c) && (i == 0 || !(Scanner.isWord(s[i - 1]) || s[i - 1] == ".")) {
                var end = i + 1
                while end < s.count && (Scanner.isWord(s[end]) || (s[end] == "." && end + 1 < s.count && ("0"..."9").contains(s[end + 1]))) {
                    end += 1
                }
                spans.append((i, end, .number))
                i = end
                commandPosition = false
                continue
            }

            if Scanner.isWord(c) || (g.dollarInWords && c == "$") {
                var end = i + 1
                while end < s.count && (Scanner.isWord(s[end]) || (g.dashInWords && s[end] == "-" && end + 1 < s.count && Scanner.isWord(s[end + 1]))
                                        || (g.dollarInWords && s[end] == "$")
                                        // Shell words run to the next space: paths, URLs, `model:tag`.
                                        || (g.shell && !s[end].properties.isWhitespace && !"|&;<>()$\"'`=".unicodeScalars.contains(s[end]))) {
                    end += 1
                }
                let word = String(String.UnicodeScalarView(s[i..<end]))
                spans.append((i, end, classify(word, end: end, previous: previousWord, command: commandPosition)))
                previousWord = word
                commandPosition = false
                i = end
                continue
            }

            if !c.properties.isWhitespace { previousWord = "" }
            if g.shell && ("|;&(".unicodeScalars.contains(c)) { commandPosition = true }
            spans.append((i, i + 1, g.operators.unicodeScalars.contains(c) ? .operator : .plain))
            i += 1
        }
    }

    private func classify(_ word: String, end: Int, previous: String, command: Bool) -> CodeToken {
        let lookup = g.caseInsensitive ? word.lowercased() : word
        if g.keysBeforeColon && followedByColon(end) { return .key }
        if g.keywords.contains(lookup) { return .keyword }
        if g.declarations.contains(lookup) { return .declaration }
        if g.constants.contains(lookup) { return .number }
        if g.modules.contains(lookup) { return .module }
        if g.functionIntroducers.contains(previous) { return .function }
        if g.typeIntroducers.contains(previous) { return .type }
        if g.shell { return command ? .function : .plain }
        if next(after: end) == "(" { return .function }
        if g.capitalizedTypes, let first = word.unicodeScalars.first, first.properties.isUppercase { return .type }
        return .plain
    }

    private func next(after i: Int) -> Unicode.Scalar? {
        var k = i
        while k < s.count && (s[k] == " " || s[k] == "\t") { k += 1 }
        return k < s.count ? s[k] : nil
    }

    private func followedByColon(_ end: Int) -> Bool {
        guard let c = next(after: end) else { return false }
        return c == ":" || (g.equalsIsColon && c == "=")
    }

    /// The end of a string starting at `i`: escapes skipped; triple quotes
    /// and backticks may span lines, others stop at the line's end.
    private func stringEnd(from i: Int) -> Int {
        let quote = s[i]
        if i + 2 < s.count && s[i + 1] == quote && s[i + 2] == quote && g.tripleQuotes {
            var k = i + 3
            while k + 2 < s.count && !(s[k] == quote && s[k + 1] == quote && s[k + 2] == quote) { k += 1 }
            return min(s.count, k + 3)
        }
        let multiline = quote == "`"
        var k = i + 1
        while k < s.count {
            if s[k] == "\\" && g.escapes { k += 2; continue }
            if s[k] == quote { return k + 1 }
            if s[k] == "\n" && !multiline { return k }
            k += 1
        }
        return s.count
    }
}

// MARK: - Languages

private struct Grammar {
    enum Mode { case code, markup, diff }
    var mode = Mode.code
    var lineComments: [String] = ["//"]
    var blockComment: (String, String)? = ("/*", "*/")
    var quotes: Set<Unicode.Scalar> = ["\"", "'"]
    var tripleQuotes = false
    var escapes = true
    var keywords: Set<String> = []
    var declarations: Set<String> = []
    var constants: Set<String> = ["true", "false", "null", "nil"]
    var modules: Set<String> = ["import"]
    /// Words after which a name is a function's (`func f`) or a type's (`struct T`).
    var functionIntroducers: Set<String> = []
    var typeIntroducers: Set<String> = []
    var attributePrefix: Unicode.Scalar?
    var operators = "+-*/=<>!&|%^~"
    var capitalizedTypes = true
    var caseInsensitive = false
    var keysBeforeColon = false
    var equalsIsColon = false
    var shell = false
    var dashInWords = false
    var dollarInWords = false

    static func named(_ name: String?) -> Grammar {
        switch name?.lowercased() ?? "" {
        case "swift": swift
        case "python", "py", "python3": python
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx": javascript
        case "rust", "rs": rust
        case "go", "golang": go
        case "c", "h", "cpp", "c++", "cc", "hpp", "cxx", "objc", "objective-c", "m", "mm": c
        case "java", "kotlin", "kt", "kts", "scala", "cs", "csharp", "c#", "dart": java
        case "ruby", "rb": ruby
        case "sh", "bash", "zsh", "shell", "console", "fish", "shellsession", "terminal": shellScript
        case "json", "jsonc", "json5": json
        case "yaml", "yml": yaml
        case "toml", "ini", "conf", "cfg": toml
        case "sql", "sqlite", "postgresql", "mysql": sql
        case "html", "xml", "svg", "plist", "vue", "xhtml": Grammar(mode: .markup)
        case "css", "scss", "less": css
        case "diff", "patch": Grammar(mode: .diff)
        case "lua": lua
        default: generic
        }
    }

    private static let control: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "throw", "throws",
        "try", "catch", "finally", "in", "await", "async", "yield", "guard", "defer", "where", "is", "as", "new", "delete",
        "goto", "when", "match", "loop", "repeat", "then",
    ]

    static var generic: Grammar {
        var g = Grammar()
        g.lineComments = ["//", "#"]
        g.keywords = control
        g.declarations = ["function", "func", "def", "fn", "let", "var", "const", "class", "struct", "enum", "type", "public", "private", "static"]
        g.functionIntroducers = ["function", "func", "def", "fn"]
        return g
    }

    static var swift: Grammar {
        var g = Grammar()
        g.keywords = control.union(["repeat", "fallthrough", "rethrows", "some", "any", "inout", "consume", "borrowing", "consuming"])
        g.declarations = ["func", "let", "var", "class", "struct", "enum", "protocol", "extension", "actor", "init", "deinit",
                          "subscript", "typealias", "associatedtype", "static", "private", "fileprivate", "public", "internal",
                          "open", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned", "convenience",
                          "required", "indirect", "nonisolated", "isolated", "macro", "operator", "package"]
        g.constants = ["true", "false", "nil", "self", "Self", "super"]
        g.functionIntroducers = ["func"]
        g.typeIntroducers = ["class", "struct", "enum", "protocol", "extension", "actor", "typealias"]
        g.attributePrefix = "@"
        g.tripleQuotes = true
        g.quotes = ["\""]
        return g
    }

    static var python: Grammar {
        var g = Grammar()
        g.lineComments = ["#"]
        g.blockComment = nil
        g.tripleQuotes = true
        g.keywords = ["if", "elif", "else", "for", "while", "break", "continue", "return", "raise", "try", "except", "finally",
                      "with", "as", "in", "is", "not", "and", "or", "pass", "yield", "await", "async", "lambda", "assert",
                      "del", "global", "nonlocal", "match", "case"]
        g.declarations = ["def", "class"]
        g.constants = ["True", "False", "None", "self", "cls"]
        g.modules = ["import", "from"]
        g.functionIntroducers = ["def"]
        g.typeIntroducers = ["class"]
        g.attributePrefix = "@"
        return g
    }

    static var javascript: Grammar {
        var g = Grammar()
        g.quotes = ["\"", "'", "`"]
        g.keywords = control.union(["of", "typeof", "instanceof", "void", "satisfies", "keyof"])
        g.declarations = ["function", "const", "let", "var", "class", "interface", "type", "enum", "extends", "implements",
                          "static", "public", "private", "protected", "readonly", "abstract", "get", "set", "declare", "namespace"]
        g.constants = ["true", "false", "null", "undefined", "this", "super", "NaN", "Infinity"]
        g.modules = ["import", "export", "from", "require", "module"]
        g.functionIntroducers = ["function"]
        g.typeIntroducers = ["class", "interface", "type", "enum", "extends", "implements"]
        g.attributePrefix = "@"
        g.dollarInWords = true
        return g
    }

    static var rust: Grammar {
        var g = Grammar()
        g.quotes = ["\""]
        g.keywords = control.union(["unsafe", "move", "ref", "dyn", "impl"])
        g.declarations = ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "type", "pub", "crate", "mod"]
        g.constants = ["true", "false", "self", "Self", "None", "Some", "Ok", "Err", "super"]
        g.modules = ["use", "extern"]
        g.functionIntroducers = ["fn"]
        g.typeIntroducers = ["struct", "enum", "trait", "type", "impl"]
        g.attributePrefix = "#"
        return g
    }

    static var go: Grammar {
        var g = Grammar()
        g.quotes = ["\"", "'", "`"]
        g.keywords = control.union(["range", "select", "go", "chan", "fallthrough"])
        g.declarations = ["func", "var", "const", "type", "struct", "interface", "map"]
        g.constants = ["true", "false", "nil", "iota"]
        g.modules = ["import", "package"]
        g.functionIntroducers = ["func"]
        g.typeIntroducers = ["type"]
        return g
    }

    static var c: Grammar {
        var g = Grammar()
        g.keywords = control.union(["sizeof", "typedef", "operator", "template", "typename", "using", "namespace"])
        g.declarations = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "auto",
                          "const", "static", "extern", "struct", "union", "enum", "class", "public", "private", "protected",
                          "virtual", "inline", "volatile", "constexpr", "id", "instancetype"]
        g.constants = ["true", "false", "NULL", "nullptr", "nil", "YES", "NO", "this", "self"]
        g.modules = []
        g.attributePrefix = "#"
        g.typeIntroducers = ["struct", "class", "enum", "union"]
        return g
    }

    static var java: Grammar {
        var g = Grammar()
        g.tripleQuotes = true
        g.keywords = control.union(["instanceof", "synchronized", "fun", "val", "object", "companion", "override"])
        g.declarations = ["class", "interface", "enum", "record", "extends", "implements", "public", "private", "protected",
                          "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean", "char", "byte",
                          "short", "var", "val", "fun", "data", "sealed", "open", "internal", "suspend", "def", "struct",
                          "namespace", "using", "readonly", "string"]
        g.constants = ["true", "false", "null", "this", "super"]
        g.modules = ["import", "package"]
        g.functionIntroducers = ["fun", "def"]
        g.typeIntroducers = ["class", "interface", "enum", "record", "object", "extends", "implements"]
        g.attributePrefix = "@"
        return g
    }

    static var ruby: Grammar {
        var g = Grammar()
        g.lineComments = ["#"]
        g.blockComment = nil
        g.keywords = ["if", "elsif", "else", "unless", "case", "when", "while", "until", "for", "in", "do", "end", "return",
                      "break", "next", "yield", "begin", "rescue", "ensure", "raise", "then", "and", "or", "not"]
        g.declarations = ["def", "class", "module", "attr_reader", "attr_writer", "attr_accessor", "private", "public", "protected"]
        g.constants = ["true", "false", "nil", "self"]
        g.modules = ["require", "require_relative", "include", "extend"]
        g.functionIntroducers = ["def"]
        g.typeIntroducers = ["class", "module"]
        g.attributePrefix = ":"
        return g
    }

    static var shellScript: Grammar {
        var g = Grammar()
        g.lineComments = ["#"]
        g.blockComment = nil
        g.shell = true
        g.dashInWords = true
        g.capitalizedTypes = false
        g.operators = "|&<>;"
        g.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                      "function", "return", "exit", "select"]
        g.declarations = ["export", "local", "readonly", "declare", "alias", "unset", "set"]
        g.constants = ["true", "false"]
        g.modules = ["source"]
        return g
    }

    static var json: Grammar {
        var g = Grammar()
        g.quotes = ["\""]
        g.keysBeforeColon = true
        g.capitalizedTypes = false
        g.modules = []
        g.operators = ""
        return g
    }

    static var yaml: Grammar {
        var g = Grammar()
        g.lineComments = ["#"]
        g.blockComment = nil
        g.keysBeforeColon = true
        g.dashInWords = true
        g.capitalizedTypes = false
        g.modules = []
        g.constants = ["true", "false", "null", "yes", "no", "on", "off"]
        g.operators = "|>"
        return g
    }

    static var toml: Grammar {
        var g = yaml
        g.lineComments = ["#", ";"]
        g.equalsIsColon = true
        g.tripleQuotes = true
        g.operators = "="
        return g
    }

    static var sql: Grammar {
        var g = Grammar()
        g.lineComments = ["--"]
        g.caseInsensitive = true
        g.capitalizedTypes = false
        g.escapes = false
        g.keywords = ["select", "from", "where", "and", "or", "not", "in", "is", "like", "between", "join", "left", "right",
                      "inner", "outer", "full", "on", "group", "by", "order", "having", "limit", "offset", "union", "all",
                      "distinct", "as", "case", "when", "then", "else", "end", "exists", "asc", "desc", "returning", "with",
                      "values", "set", "into", "begin", "commit", "rollback", "transaction"]
        g.declarations = ["create", "table", "insert", "update", "delete", "drop", "alter", "index", "view", "trigger",
                          "primary", "key", "foreign", "references", "unique", "default", "constraint", "if", "integer", "int",
                          "text", "real", "blob", "varchar", "boolean", "timestamp", "serial"]
        g.constants = ["null", "true", "false"]
        g.modules = []
        return g
    }

    static var css: Grammar {
        var g = Grammar()
        g.lineComments = []
        g.keysBeforeColon = true
        g.dashInWords = true
        g.capitalizedTypes = false
        g.modules = ["@import", "@media"]
        g.attributePrefix = "@"
        g.operators = ""
        return g
    }

    static var lua: Grammar {
        var g = Grammar()
        g.lineComments = ["--"]
        g.blockComment = ("--[[", "]]")
        g.keywords = ["if", "then", "else", "elseif", "end", "for", "while", "do", "repeat", "until", "return", "break",
                      "in", "and", "or", "not", "goto"]
        g.declarations = ["function", "local"]
        g.constants = ["true", "false", "nil", "self"]
        g.modules = ["require"]
        g.functionIntroducers = ["function"]
        return g
    }
}
