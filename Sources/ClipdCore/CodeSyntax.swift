import Foundation

// Code cards: detect the language, then colour a short preview of it.
//
// Two rules shaped everything in this file.
//
// 1. A false positive is much worse than a miss. Turning an email, a postal
//    address or a paragraph of prose into coloured confetti is a visible bug on
//    a card you look at fifty times a day. Missing the colours on a two line
//    shell command is not. So every language needs at least one STRONG signal
//    before it is considered at all, and shared English-ish words only add
//    confidence, they never decide on their own.
// 2. Tokens carry text, not ranges. Rejected: emitting NSRange or Range<String.Index>
//    pairs, which is the usual design and the usual source of bugs, because the
//    shell then has to convert them and any off by one silently drops or
//    duplicates characters. Runs of text give a much stronger invariant:
//    joining every token reproduces the input exactly. Every test asserts it.

/// The languages a card can colour.
///
/// TypeScript folds into `javascript` deliberately. The tokenizer would need no
/// new rules for it, and a header that says "JavaScript" over a .ts snippet is a
/// far smaller error than a second near identical rule set to maintain.
public enum CodeLanguage: String, Equatable, Sendable, CaseIterable {
    case swift
    case javascript
    case python
    case json
    case yaml
    case markdown
    case shell
    case sql
    case html
    case css
    case go
    case rust

    /// What the card header shows in place of "Text".
    public var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .html: return "HTML"
        case .css: return "CSS"
        case .go: return "Go"
        case .rust: return "Rust"
        }
    }
}

/// What a run of text is, for colouring purposes.
///
/// Deliberately small. These are the distinctions a 250 character preview can
/// actually show. Rejected: separate kinds for operators, parameters, function
/// names and so on, which a real editor theme has and which would need a real
/// parser to fill in honestly.
public enum TokenKind: String, Equatable, Sendable {
    case plain
    case keyword
    case type
    case string
    case number
    case comment
    /// A mapping key: the thing before a colon in JSON, YAML and CSS.
    case key
    case punctuation
    /// Markdown bold, italics and link text.
    case emphasis
}

public struct SyntaxToken: Equatable, Sendable {
    public let text: String
    public let kind: TokenKind

    public init(text: String, kind: TokenKind) {
        self.text = text
        self.kind = kind
    }
}

// MARK: - Detection

/// How much of a paste is looked at.
///
/// A 3 MB paste must cost the same as a 3 KB one, because detection runs on
/// every capture and on every row loaded from the database at launch. 2000
/// characters is roughly 40 lines, which is far more than enough evidence.
private let sampleLimit = 2000

/// Above this the exact JSON parse is skipped and the cheap shape check is used
/// instead. Parsing a 5 MB array to colour a 12 line preview is not worth it.
private let jsonExactParseLimit = 512 * 1024

/// Shorter than this and there is not enough evidence to be sure of anything.
private let minimumSampleLength = 16

/// The score a language must reach. A strong signal is worth 3 and a weak one
/// is worth 1, so this is "one strong plus two weak", or "two strong".
private let detectionThreshold = 5

private struct Evidence {
    var strong = 0
    var weak = 0
    var score: Int { strong * 3 + weak }
    var passes: Bool { strong >= 1 && score >= detectionThreshold }

    mutating func strongIf(_ condition: Bool) { if condition { strong += 1 } }
    mutating func weakIf(_ condition: Bool) { if condition { weak += 1 } }
}

/// The prefix of a paste, prepared once for about forty substring questions.
///
/// Measured: `String.contains(_:)` costs roughly 27 microseconds on a 2000
/// character sample, because it walks graphemes. Detection asks about forty of
/// those questions, which came to 0.8 ms per item and would be most of a second
/// to load 500 rows at launch. Searching the UTF-8 bytes instead is about forty
/// times faster and gives identical answers, because every needle in this file
/// is ASCII and ASCII bytes cannot appear inside a multi byte UTF-8 sequence.
private struct Sample {
    let text: String
    let lines: [String]
    let words: Set<String>
    private let bytes: [UInt8]
    private let lowerBytes: [UInt8]

    init(_ text: String) {
        self.text = text
        self.lines = text.components(separatedBy: "\n")
        self.bytes = Array(text.utf8)
        self.lowerBytes = bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        self.words = Sample.identifierWords(text)
    }

    func has(_ needle: String) -> Bool { Sample.find(bytes, Array(needle.utf8)) != nil }

    /// The same question, ignoring case. Used by HTML, where `<DIV` and `<div`
    /// are both common and neither is worth a second needle list.
    func hasIgnoringCase(_ lowercasedNeedle: String) -> Bool {
        Sample.find(lowerBytes, Array(lowercasedNeedle.utf8)) != nil
    }

    func count(of needle: String) -> Int {
        let n = Array(needle.utf8)
        guard !n.isEmpty else { return 0 }
        var total = 0
        var from = 0
        while let hit = Sample.find(bytes, n, from: from) {
            total += 1
            from = hit + n.count
        }
        return total
    }

    func countIgnoringCase(of lowercasedNeedle: String) -> Int {
        let n = Array(lowercasedNeedle.utf8)
        guard !n.isEmpty else { return 0 }
        var total = 0
        var from = 0
        while let hit = Sample.find(lowerBytes, n, from: from) {
            total += 1
            from = hit + n.count
        }
        return total
    }

    func hits(_ set: Set<String>) -> Int { words.intersection(set).count }

    /// Plain forward search. Rejected: Boyer-Moore, which would need a skip
    /// table per needle and the needles here are three to twenty bytes long.
    private static func find(_ haystack: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var i = from
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var k = 1
                while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Every identifier-ish word, lowercased for cheap membership tests.
    private static func identifierWords(_ text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else if !current.isEmpty {
                words.insert(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current.lowercased()) }
        return words
    }
}

/// Returns the language of a snippet, or nil when the text is not code.
///
/// nil is the common answer and the safe one. See the note at the top of this
/// file about why this leans towards missing snippets rather than colouring
/// prose.
public func detectCodeLanguage(_ text: String) -> CodeLanguage? {
    let prefix = String(text.prefix(sampleLimit))
    let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minimumSampleLength else { return nil }

    // JSON first, because an exact parse beats every heuristic in this file and
    // because minified JSON has no whitespace, which the next guard would throw
    // out.
    if looksLikeJSON(full: text, sample: trimmed) { return .json }

    // One unbroken run of characters is a URL, an email address, a file path or
    // a password. None of those is code, and all of them contain slashes,
    // colons, dots and braces that the scoring below would happily read as
    // structure.
    guard trimmed.contains(where: \.isWhitespace) else { return nil }

    let s = Sample(trimmed)

    // Line shaped languages come before the C-like family. A YAML file is full
    // of colons and a Markdown file is full of dashes, and both would otherwise
    // pick up stray points from the brace based scoring.
    if markdownEvidence(s).passes { return .markdown }
    if yamlEvidence(s).passes { return .yaml }

    // Ordered: on an exact tie the earlier language wins. The order puts the
    // languages with the most distinctive signatures first.
    let candidates: [(CodeLanguage, Evidence)] = [
        (.swift, swiftEvidence(s)),
        (.go, goEvidence(s)),
        (.rust, rustEvidence(s)),
        (.python, pythonEvidence(s)),
        (.javascript, javascriptEvidence(s)),
        (.sql, sqlEvidence(s)),
        (.html, htmlEvidence(s)),
        (.css, cssEvidence(s)),
        (.shell, shellEvidence(s)),
    ]

    var best: (CodeLanguage, Evidence)?
    for candidate in candidates where candidate.1.passes {
        if best == nil || candidate.1.score > best!.1.score { best = candidate }
    }
    return best?.0
}

// MARK: - JSON

private func looksLikeJSON(full: String, sample: String) -> Bool {
    guard let first = sample.first, first == "{" || first == "[" else { return false }

    // The strongest signal there is: it either parses or it does not. Fragments
    // stay off on purpose, so a bare "42" or a quoted word is not JSON.
    if full.utf8.count <= jsonExactParseLimit {
        let whole = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = whole.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
    }

    // Fallback for the truncated case: the sample is only the first 2000
    // characters of a large document, so it can never parse. Two or more
    // quoted keys followed by a colon is a shape prose does not have.
    let s = Sample(sample)
    return s.count(of: "\":") + s.count(of: "\" :") >= 2
}

// MARK: - Markdown

private func markdownEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    var headings = 0
    var bullets = 0
    var fences = 0
    var quotes = 0

    for line in s.lines {
        let body = line.drop(while: { $0 == " " })
        if body.hasPrefix("```") || body.hasPrefix("~~~") { fences += 1 }
        if body.hasPrefix("#"), body.drop(while: { $0 == "#" }).hasPrefix(" ") { headings += 1 }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") { bullets += 1 }
        if body.hasPrefix("> ") { quotes += 1 }
    }

    // Strong: shapes that prose does not produce by accident.
    e.strongIf(headings >= 1)
    e.strongIf(fences >= 2)
    // The cheap byte check first: a link must contain "](", and only then is it
    // worth walking the characters to confirm the whole shape.
    e.strongIf(s.has("](") && hasMarkdownLink(s.text))
    e.strongIf(s.count(of: "**") >= 2)
    e.strongIf(s.count(of: "`") >= 2)

    // Weak: a bulleted list is also how people write a shopping list, and a
    // quote marker is also how mail clients quote a reply.
    e.weakIf(bullets >= 2)
    e.weakIf(bullets >= 4)
    e.weakIf(quotes >= 1)
    e.weakIf(headings >= 2)
    e.weakIf(s.lines.count >= 4)
    return e
}

/// A `[text](target)` pair on one line. No regex here on purpose: one scan is
/// cheaper than compiling a pattern and there is exactly one shape to find.
private func hasMarkdownLink(_ text: String) -> Bool {
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        guard chars[i] == "[" else { i += 1; continue }
        var j = i + 1
        while j < chars.count, chars[j] != "]", chars[j] != "\n" { j += 1 }
        if j + 1 < chars.count, chars[j] == "]", chars[j + 1] == "(" {
            var k = j + 2
            while k < chars.count, chars[k] != ")", chars[k] != "\n" { k += 1 }
            if k < chars.count, chars[k] == ")", k > j + 2 { return true }
        }
        i = j + 1
    }
    return false
}

// MARK: - YAML

private func yamlEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    var mappings = 0
    var sequences = 0
    var comments = 0
    var indented = 0
    var documentMarkers = 0

    for line in s.lines {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        if body.isEmpty { continue }
        if body.hasPrefix("#") { comments += 1; continue }
        if body == "---" || body == "..." { documentMarkers += 1; continue }
        if indent > 0 { indented += 1 }
        var scalar = body
        if scalar.hasPrefix("- ") {
            sequences += 1
            scalar = scalar.dropFirst(2)
        } else if scalar == "-" {
            sequences += 1
            continue
        }
        if yamlKey(of: String(scalar)) != nil { mappings += 1 }
    }

    // Strong: two or more `key: value` lines. One is a sentence with a colon in
    // it, which is the negative case this whole check exists to survive.
    e.strongIf(mappings >= 2)
    e.strongIf(documentMarkers >= 1 && mappings >= 1)
    e.weakIf(mappings >= 4)
    e.weakIf(indented >= 2)
    e.weakIf(sequences >= 1)
    e.weakIf(comments >= 1)
    return e
}

/// The key part of a `key:` or `key: value` line, or nil when the line is not a
/// mapping. A key may not contain a space, which is what keeps "Note: call the
/// bank tomorrow" from counting.
private func yamlKey(of body: String) -> String? {
    guard let colon = body.firstIndex(of: ":") else { return nil }
    let after = body.index(after: colon)
    guard after == body.endIndex || body[after] == " " else { return nil }
    let key = body[body.startIndex..<colon]
    guard !key.isEmpty, key.count <= 64 else { return nil }
    guard !key.contains(" "), !key.contains("#") else { return nil }
    return String(key)
}

// MARK: - The C-like family

private let swiftKeywords: Set<String> = [
    "func", "let", "var", "guard", "struct", "class", "enum", "extension",
    "protocol", "import", "return", "if", "else", "for", "while", "switch",
    "case", "public", "private", "internal", "static", "init", "self", "nil",
    "true", "false", "throws", "try", "async", "await", "some", "where",
    "defer", "typealias", "override", "final", "lazy", "weak", "mutating",
]

private func swiftEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.has("func "))
    e.strongIf(s.has("guard let ") || s.has("guard "))
    e.strongIf(s.has("import Foundation") || s.has("import SwiftUI") || s.has("import AppKit"))
    e.strongIf(s.has("-> ") && s.has("{"))
    e.strongIf(s.has("?? ") || s.has("@MainActor") || s.has("@Test"))
    e.strongIf(s.has("public ") || s.has("private "))

    let count = s.hits(swiftKeywords)
    e.weakIf(count >= 3)
    e.weakIf(count >= 5)
    e.weakIf(count >= 7)
    e.weakIf(s.has("{") && s.has("}"))
    e.weakIf(s.has("()"))
    return e
}

private let goKeywords: Set<String> = [
    "func", "package", "import", "var", "const", "type", "struct", "interface",
    "return", "if", "else", "for", "range", "defer", "go", "chan", "select",
    "map", "nil", "err", "make", "string", "int", "bool",
]

private func goEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.has("package "))
    e.strongIf(s.has(":="))
    e.strongIf(s.has("func ("))
    e.strongIf(s.has("err != nil"))
    e.strongIf(s.has("fmt.") || s.has("go func"))

    let count = s.hits(goKeywords)
    e.weakIf(count >= 3)
    e.weakIf(count >= 5)
    e.weakIf(s.has("{") && s.has("}"))
    return e
}

private let rustKeywords: Set<String> = [
    "fn", "let", "mut", "pub", "struct", "impl", "enum", "match", "use", "mod",
    "return", "if", "else", "for", "while", "loop", "some", "none", "ok", "err",
    "trait", "crate", "self", "where", "dyn", "unwrap", "vec", "string",
]

private func rustEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.has("fn "))
    e.strongIf(s.has("let mut "))
    e.strongIf(s.has("impl ") || s.has("pub fn"))
    e.strongIf(s.has("println!") || s.has(".unwrap()") || s.has("&str"))
    e.strongIf(s.has("::") && s.has("{"))

    let count = s.hits(rustKeywords)
    e.weakIf(count >= 3)
    e.weakIf(count >= 5)
    e.weakIf(s.has("Vec<") || s.has("Option<") || s.has("Result<"))
    return e
}

private let pythonKeywords: Set<String> = [
    "def", "class", "import", "from", "return", "if", "elif", "else", "for",
    "while", "in", "not", "none", "true", "false", "self", "lambda", "with",
    "as", "try", "except", "raise", "yield", "async", "await", "pass", "print",
]

private func pythonEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.has("def "))
    e.strongIf(s.has("self.") || s.has("__init__"))
    e.strongIf(s.has("elif ") || s.has("if __name__"))
    e.strongIf(s.has("import ") && s.has(":\n"))
    e.strongIf(s.has("print(") || s.has("except "))

    // A line ending in a colon followed by an indented line. Python has no
    // braces, so this block shape is the closest thing it has to structure.
    var blocks = 0
    for (i, line) in s.lines.enumerated() where line.hasSuffix(":") {
        let next = i + 1 < s.lines.count ? s.lines[i + 1] : ""
        if next.hasPrefix(" ") || next.hasPrefix("\t") { blocks += 1 }
    }
    e.weakIf(blocks >= 1)
    e.weakIf(blocks >= 2)

    let count = s.hits(pythonKeywords)
    e.weakIf(count >= 3)
    e.weakIf(count >= 5)
    return e
}

private let javascriptKeywords: Set<String> = [
    "function", "const", "let", "var", "return", "if", "else", "for", "while",
    "import", "export", "async", "await", "class", "new", "typeof", "null",
    "undefined", "true", "false", "this", "interface", "type", "extends",
    "default", "require", "console",
]

private func javascriptEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.has("=>"))
    e.strongIf(s.has("const ") || s.has("function "))
    e.strongIf(s.has("===") || s.has("!=="))
    e.strongIf(s.has("console.") || s.has("require(")
               || s.has("export default") || s.has("document."))
    e.strongIf(s.has(": string") || s.has(": number") || s.has("interface "))

    let count = s.hits(javascriptKeywords)
    e.weakIf(count >= 3)
    e.weakIf(count >= 5)
    e.weakIf(s.has("{") && s.has("}"))
    e.weakIf(s.has(";"))
    return e
}

private let sqlKeywords: Set<String> = [
    "select", "from", "where", "insert", "into", "update", "set", "delete",
    "join", "inner", "left", "outer", "group", "order", "by", "having",
    "create", "table", "alter", "drop", "values", "primary", "key", "null",
    "and", "or", "limit", "offset", "distinct", "as", "on", "index",
]

private func sqlEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    // SQL has no punctuation of its own worth trusting, so every strong signal
    // is a pair of keywords that only ever appear together in a statement.
    e.strongIf(s.words.contains("select") && s.words.contains("from"))
    e.strongIf(s.words.contains("insert") && s.words.contains("into"))
    e.strongIf(s.words.contains("update") && s.words.contains("set"))
    e.strongIf(s.words.contains("delete") && s.words.contains("from"))
    e.strongIf(s.words.contains("create") && s.words.contains("table"))

    let count = s.hits(sqlKeywords)
    e.weakIf(count >= 4)
    e.weakIf(count >= 6)
    e.weakIf(count >= 8)
    // A one line statement is a very common paste and has too few keywords to
    // reach the threshold on words alone. The terminating semicolon and the
    // column list carry it. Prose that happens to say "update the set" has
    // neither, which is what keeps this safe.
    e.weakIf(s.has(";"))
    e.weakIf(s.has("(") && s.has(")"))
    return e
}

private func htmlEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    e.strongIf(s.hasIgnoringCase("<!doctype") || s.hasIgnoringCase("<html"))
    e.strongIf(s.hasIgnoringCase("</div>") || s.hasIgnoringCase("</span>")
               || s.hasIgnoringCase("</p>"))
    e.strongIf(s.hasIgnoringCase("<div") || s.hasIgnoringCase("<body")
               || s.hasIgnoringCase("<head"))
    e.strongIf(s.hasIgnoringCase("<a href") || s.hasIgnoringCase("class=\"")
               || s.hasIgnoringCase("id=\""))

    e.weakIf(s.countIgnoringCase(of: "</") >= 2)
    e.weakIf(s.countIgnoringCase(of: "<") >= 4)
    return e
}

private func cssEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    var declarations = 0
    var selectors = 0
    for line in s.lines {
        let body = line.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("{") { selectors += 1 }
        guard body.hasSuffix(";"), let colon = body.firstIndex(of: ":") else { continue }
        let property = body[body.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        if !property.isEmpty, !property.contains(" ") { declarations += 1 }
    }
    e.strongIf(declarations >= 2 && selectors >= 1)
    e.strongIf(s.has("@media") || s.has("!important"))
    e.strongIf(declarations >= 4)

    e.weakIf(s.has("px") || s.has("rem") || s.has("rgba("))
    e.weakIf(s.has("#") && declarations >= 1)
    e.weakIf(selectors >= 2)
    return e
}

/// Commands that mean the line is a shell command and not a sentence.
///
/// Deliberately a list of tools rather than a grammar. Shell has almost no
/// syntax of its own, so "the first word is `kubectl`" carries more information
/// than any amount of structure matching.
private let shellCommands: Set<String> = [
    "cd", "ls", "echo", "export", "sudo", "git", "docker", "kubectl", "aws",
    "npm", "npx", "yarn", "pnpm", "brew", "curl", "wget", "chmod", "chown",
    "mkdir", "rm", "cp", "mv", "cat", "grep", "sed", "awk", "find", "tar",
    "ssh", "scp", "systemctl", "apt", "pip", "pip3", "make", "terraform",
    "helm", "psql", "mysql", "source", "tail", "head", "ps", "kill", "open",
    "swift", "xcodebuild", "cargo", "gh", "rsync", "unzip", "diff", "touch",
]

private let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case",
    "esac", "function", "export", "local", "return", "in", "echo", "set",
]

private func shellEvidence(_ s: Sample) -> Evidence {
    var e = Evidence()
    var commandLines = 0
    for line in s.lines {
        let body = line.trimmingCharacters(in: .whitespaces)
        // A line with braces or a call is another language borrowing the same
        // first word, for example `go func() {`. Skip it rather than claim it.
        if body.contains("{") || body.contains("(") || body.hasSuffix(":") { continue }
        guard let first = body.split(separator: " ").first else { continue }
        if shellCommands.contains(String(first)) { commandLines += 1 }
    }

    e.strongIf(s.text.hasPrefix("#!/"))
    e.strongIf(commandLines >= 1)
    e.strongIf(commandLines >= 3)
    e.strongIf(s.has("$(") || s.has("${"))

    e.weakIf(s.has(" -") || s.has(" --"))
    e.weakIf(s.has(" | ") || s.has(" && "))
    e.weakIf(s.hits(shellKeywords) >= 3)
    // Commands do not end in a full stop and do not start with a capital. This
    // is what separates `docker compose up -d` from "Docker is a nice tool."
    let firstLine = s.lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
    e.weakIf(!firstLine.hasSuffix(".") && !(firstLine.first?.isUppercase ?? false))
    return e
}

// MARK: - Preview shaping

/// A tab becomes this many spaces.
///
/// Rejected: real tab stops, which need the drawing width to compute and would
/// make the Core code depend on the font. Four spaces is what every one of
/// these languages formats to anyway.
private let tabWidth = 4

/// A code shaped preview: newlines kept, tabs expanded, common indentation removed.
///
/// Snippets are usually copied from deep inside a function, so every line starts
/// with eight or twelve spaces. On a 250 point wide card that is a third of the
/// width spent on nothing. Removing the shared indent keeps the relative shape
/// and gives the width back.
public func makeCodePreview(_ text: String, maxLines: Int = 12, maxChars: Int = 700) -> String {
    let normalised = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    var lines = normalised.components(separatedBy: "\n").map(expandTabs)
    while let first = lines.first, isBlank(first) { lines.removeFirst() }
    while let last = lines.last, isBlank(last) { lines.removeLast() }
    guard !lines.isEmpty else { return "" }

    // Blank lines are ignored when measuring, otherwise one empty line in the
    // middle of a snippet would pin the common indent at zero.
    let indents = lines.filter { !isBlank($0) }.map(leadingSpaces)
    let common = indents.min() ?? 0
    if common > 0 {
        lines = lines.map { String($0.dropFirst(min(common, leadingSpaces($0)))) }
    }

    if lines.count > maxLines {
        lines = Array(lines.prefix(max(0, maxLines - 1))) + ["…"]
    }
    var out = lines.joined(separator: "\n")
    if out.count > maxChars {
        out = String(out.prefix(max(0, maxChars - 1))) + "…"
    }
    return out
}

private func isBlank(_ line: String) -> Bool {
    !line.contains { !$0.isWhitespace }
}

private func leadingSpaces(_ line: String) -> Int {
    line.prefix(while: { $0 == " " }).count
}

private func expandTabs(_ line: String) -> String {
    guard line.contains("\t") else { return line }
    return line.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
}

// MARK: - Highlighting

/// Splits text into coloured runs.
///
/// The invariant that matters: `highlight(t, as: l).map(\.text).joined() == t`,
/// for every input, always. The card renders the joined tokens, so any drift
/// here is text the user copied silently disappearing from the preview.
public func highlight(_ text: String, as language: CodeLanguage) -> [SyntaxToken] {
    guard !text.isEmpty else { return [] }
    switch language {
    case .yaml: return scanYAML(text)
    case .markdown: return scanMarkdown(text)
    case .html: return scanHTML(text)
    default: return scanCLike(text, rules: rules(for: language))
    }
}

/// One scanner for nine languages, parameterised.
///
/// Rejected: a scanner per language. They differ only in the keyword set, the
/// comment markers and the string quotes, and nine near copies is nine places
/// to fix the same escape handling bug.
private struct ScannerRules {
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    var stringDelimiters: [Character] = ["\"", "'"]
    /// Extra characters that count as part of an identifier, for example the
    /// dash in the CSS property `background-color`.
    var identifierExtras: Set<Character> = []
    /// Promote the thing before a colon to `.key`. True for JSON and CSS only.
    var promoteKeysBeforeColon = false
    /// Treat a capitalised word as a type name. Wrong often enough to be a
    /// heuristic, right often enough to be worth it in Swift, Go and Rust.
    var capitalisedIsType = true
    /// `$NAME` and `${NAME}` are variables. Shell only.
    var dollarVariables = false
}

private func rules(for language: CodeLanguage) -> ScannerRules {
    switch language {
    case .swift:
        return ScannerRules(keywords: swiftKeywords)
    case .javascript:
        return ScannerRules(keywords: javascriptKeywords,
                            stringDelimiters: ["\"", "'", "`"])
    case .go:
        return ScannerRules(keywords: goKeywords,
                            stringDelimiters: ["\"", "'", "`"])
    case .rust:
        return ScannerRules(keywords: rustKeywords)
    case .python:
        return ScannerRules(keywords: pythonKeywords,
                            lineComments: ["#"], blockComment: nil)
    case .shell:
        return ScannerRules(keywords: shellKeywords,
                            lineComments: ["#"], blockComment: nil,
                            capitalisedIsType: false, dollarVariables: true)
    case .sql:
        return ScannerRules(keywords: sqlKeywords, caseInsensitiveKeywords: true,
                            lineComments: ["--"], stringDelimiters: ["'", "\""],
                            capitalisedIsType: false)
    case .json:
        return ScannerRules(keywords: ["true", "false", "null"],
                            lineComments: [], blockComment: nil,
                            stringDelimiters: ["\""],
                            promoteKeysBeforeColon: true, capitalisedIsType: false)
    case .css:
        return ScannerRules(lineComments: [], stringDelimiters: ["\"", "'"],
                            identifierExtras: ["-"],
                            promoteKeysBeforeColon: true, capitalisedIsType: false)
    case .yaml, .markdown, .html:
        // Handled by their own line based scanners.
        return ScannerRules()
    }
}

/// Collects runs and merges neighbours of the same kind, so a card gets a dozen
/// attributed runs rather than several hundred one character ones.
private struct TokenBuilder {
    private(set) var tokens: [SyntaxToken] = []

    mutating func emit(_ text: String, _ kind: TokenKind) {
        guard !text.isEmpty else { return }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1] = SyntaxToken(text: last.text + text, kind: kind)
        } else {
            tokens.append(SyntaxToken(text: text, kind: kind))
        }
    }
}

private func matches(_ chars: [Character], _ index: Int, _ needle: String) -> Bool {
    let n = Array(needle)
    guard !n.isEmpty, index + n.count <= chars.count else { return false }
    for k in 0..<n.count where chars[index + k] != n[k] { return false }
    return true
}

private func nextNonSpaceIsColon(_ chars: [Character], _ from: Int) -> Bool {
    var j = from
    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
    return j < chars.count && chars[j] == ":"
}

private let punctuationCharacters: Set<Character> = [
    "{", "}", "[", "]", "(", ")", "<", ">", ",", ";", ":", ".", "=", "+", "-",
    "*", "/", "%", "&", "|", "!", "?", "^", "~", "@", "#", "$",
]

private func scanCLike(_ text: String, rules: ScannerRules) -> [SyntaxToken] {
    let chars = Array(text)
    var out = TokenBuilder()
    var pending: [Character] = []
    var i = 0

    func flush() {
        if !pending.isEmpty {
            out.emit(String(pending), .plain)
            pending.removeAll(keepingCapacity: true)
        }
    }

    func isIdentifier(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || rules.identifierExtras.contains(c)
    }

    while i < chars.count {
        let c = chars[i]

        if rules.lineComments.contains(where: { matches(chars, i, $0) }) {
            flush()
            var j = i
            while j < chars.count, chars[j] != "\n" { j += 1 }
            out.emit(String(chars[i..<j]), .comment)
            i = j
            continue
        }

        if let block = rules.blockComment, matches(chars, i, block.open) {
            flush()
            var j = i + block.open.count
            while j < chars.count, !matches(chars, j, block.close) { j += 1 }
            j = j < chars.count ? j + block.close.count : chars.count
            out.emit(String(chars[i..<min(j, chars.count)]), .comment)
            i = min(j, chars.count)
            continue
        }

        if rules.stringDelimiters.contains(c) {
            flush()
            var j = i + 1
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == c { j += 1; break }
                // An unterminated quote stops at the line end. Running to the
                // end of the snippet instead would paint the rest of the card
                // as one string, which looks broken on a truncated preview.
                if chars[j] == "\n" { break }
                j += 1
            }
            j = min(j, chars.count)
            let kind: TokenKind = (rules.promoteKeysBeforeColon
                                   && nextNonSpaceIsColon(chars, j)) ? .key : .string
            out.emit(String(chars[i..<j]), kind)
            i = j
            continue
        }

        if rules.dollarVariables, c == "$", i + 1 < chars.count {
            let next = chars[i + 1]
            if next == "{" {
                flush()
                var j = i + 2
                while j < chars.count, chars[j] != "}" { j += 1 }
                j = min(j + 1, chars.count)
                out.emit(String(chars[i..<j]), .type)
                i = j
                continue
            }
            if next.isLetter || next == "_" {
                flush()
                var j = i + 1
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                out.emit(String(chars[i..<j]), .type)
                i = j
                continue
            }
        }

        // A digit only starts a number when it is not in the middle of a name,
        // so `utf8` stays one identifier rather than a word plus a number.
        let previousIsIdentifier = i > 0 && isIdentifier(chars[i - 1])
        if c.isNumber, !previousIsIdentifier {
            flush()
            var j = i
            while j < chars.count, chars[j].isHexDigit || chars[j] == "."
                    || chars[j] == "x" || chars[j] == "_" { j += 1 }
            out.emit(String(chars[i..<j]), .number)
            i = j
            continue
        }

        if c.isLetter || c == "_" {
            var j = i
            while j < chars.count, isIdentifier(chars[j]) { j += 1 }
            let word = String(chars[i..<j])
            var kind: TokenKind = .plain
            let lookup = rules.caseInsensitiveKeywords ? word.lowercased() : word
            if rules.keywords.contains(lookup) {
                kind = .keyword
            } else if rules.capitalisedIsType, word.first?.isUppercase == true {
                kind = .type
            }
            if rules.promoteKeysBeforeColon, kind == .plain, nextNonSpaceIsColon(chars, j) {
                kind = .key
            }
            if kind == .plain {
                pending.append(contentsOf: word)
            } else {
                flush()
                out.emit(word, kind)
            }
            i = j
            continue
        }

        if punctuationCharacters.contains(c) {
            flush()
            out.emit(String(c), .punctuation)
            i += 1
            continue
        }

        pending.append(c)
        i += 1
    }
    flush()
    return out.tokens
}

// MARK: - YAML scanner

/// Splits into lines and keeps the newline on the end of each one, so joining
/// the result is the input again.
private func linesKeepingBreaks(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if ch == "\n" {
            lines.append(current)
            current = ""
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// YAML is line shaped, so it gets a line scanner rather than the C-like one.
/// Rejected: running the C-like scanner with `#` comments, which coloured every
/// bare word in a value as an identifier and lost the key emphasis entirely.
private func scanYAML(_ text: String) -> [SyntaxToken] {
    var out = TokenBuilder()
    for raw in linesKeepingBreaks(text) {
        var line = raw
        var newline = ""
        if line.hasSuffix("\n") {
            newline = "\n"
            line.removeLast()
        }
        let indent = line.prefix(while: { $0 == " " })
        out.emit(String(indent), .plain)
        var body = String(line.dropFirst(indent.count))

        if body.isEmpty {
            out.emit(newline, .plain)
            continue
        }
        if body.hasPrefix("#") {
            out.emit(body, .comment)
            out.emit(newline, .plain)
            continue
        }
        if body == "---" || body == "..." {
            out.emit(body, .punctuation)
            out.emit(newline, .plain)
            continue
        }
        if body.hasPrefix("- ") || body == "-" {
            out.emit("-", .punctuation)
            body.removeFirst()
            if body.hasPrefix(" ") {
                out.emit(" ", .plain)
                body.removeFirst()
            }
        }
        if let key = yamlKey(of: body) {
            out.emit(key, .key)
            out.emit(":", .punctuation)
            emitYAMLValue(String(body.dropFirst(key.count + 1)), into: &out)
        } else {
            emitYAMLValue(body, into: &out)
        }
        out.emit(newline, .plain)
    }
    return out.tokens
}

private func emitYAMLValue(_ value: String, into out: inout TokenBuilder) {
    guard !value.isEmpty else { return }
    let spaces = value.prefix(while: { $0 == " " })
    out.emit(String(spaces), .plain)
    var rest = String(value.dropFirst(spaces.count))
    guard !rest.isEmpty else { return }

    // An inline comment runs to the end of the line.
    var trailing = ""
    if let hash = rest.range(of: " #") {
        trailing = String(rest[hash.lowerBound...])
        rest = String(rest[rest.startIndex..<hash.lowerBound])
    }

    if rest.hasPrefix("\"") || rest.hasPrefix("'") {
        out.emit(rest, .string)
    } else if ["true", "false", "null", "yes", "no", "~"].contains(rest.lowercased()) {
        out.emit(rest, .keyword)
    } else if Double(rest) != nil {
        out.emit(rest, .number)
    } else {
        out.emit(rest, .plain)
    }
    if !trailing.isEmpty {
        out.emit(String(trailing.prefix(1)), .plain)
        out.emit(String(trailing.dropFirst()), .comment)
    }
}

// MARK: - Markdown scanner

private func scanMarkdown(_ text: String) -> [SyntaxToken] {
    var out = TokenBuilder()
    var inFence = false

    for raw in linesKeepingBreaks(text) {
        var line = raw
        var newline = ""
        if line.hasSuffix("\n") {
            newline = "\n"
            line.removeLast()
        }
        let indent = line.prefix(while: { $0 == " " })
        let body = String(line.dropFirst(indent.count))
        out.emit(String(indent), .plain)

        if body.hasPrefix("```") || body.hasPrefix("~~~") {
            inFence.toggle()
            out.emit(body, .punctuation)
        } else if inFence {
            // Fenced content is left alone. Guessing its language from the info
            // string is possible, but a wrong guess inside a fence is exactly
            // the confetti this file exists to avoid.
            out.emit(body, .plain)
        } else if body.hasPrefix("#") {
            out.emit(body, .keyword)
        } else if body.hasPrefix(">") {
            out.emit(body, .comment)
        } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            out.emit(String(body.prefix(1)), .punctuation)
            emitMarkdownInline(String(body.dropFirst(1)), into: &out)
        } else if let dot = orderedListMarker(body) {
            out.emit(String(body.prefix(dot)), .number)
            emitMarkdownInline(String(body.dropFirst(dot)), into: &out)
        } else if body == "---" || body == "***" || body == "___" {
            out.emit(body, .punctuation)
        } else {
            emitMarkdownInline(body, into: &out)
        }
        out.emit(newline, .plain)
    }
    return out.tokens
}

/// The length of a `1. ` style marker, or nil.
private func orderedListMarker(_ body: String) -> Int? {
    let digits = body.prefix(while: { $0.isNumber })
    guard !digits.isEmpty, digits.count <= 3 else { return nil }
    let after = body.dropFirst(digits.count)
    guard after.hasPrefix(". ") else { return nil }
    return digits.count + 1
}

private func emitMarkdownInline(_ text: String, into out: inout TokenBuilder) {
    let chars = Array(text)
    var pending: [Character] = []
    var i = 0

    func flush() {
        if !pending.isEmpty {
            out.emit(String(pending), .plain)
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// Finds a closing marker on the same line. Nil means the marker was never
    /// closed, in which case it stays plain text rather than swallowing the
    /// rest of the line.
    func closing(_ marker: String, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if matches(chars, j, marker) { return j }
            j += 1
        }
        return nil
    }

    while i < chars.count {
        if chars[i] == "`" {
            if let end = closing("`", from: i + 1) {
                flush()
                out.emit(String(chars[i...end]), .string)
                i = end + 1
                continue
            }
        }
        if matches(chars, i, "**") {
            if let end = closing("**", from: i + 2) {
                flush()
                out.emit(String(chars[i..<(end + 2)]), .emphasis)
                i = end + 2
                continue
            }
        }
        if chars[i] == "*" || chars[i] == "_" {
            let marker = String(chars[i])
            if let end = closing(marker, from: i + 1), end > i + 1 {
                flush()
                out.emit(String(chars[i...end]), .emphasis)
                i = end + 1
                continue
            }
        }
        if chars[i] == "[" {
            if let close = closing("]", from: i + 1),
               close + 1 < chars.count, chars[close + 1] == "(",
               let paren = closing(")", from: close + 2) {
                flush()
                out.emit(String(chars[i...close]), .emphasis)
                out.emit(String(chars[(close + 1)...paren]), .string)
                i = paren + 1
                continue
            }
        }
        pending.append(chars[i])
        i += 1
    }
    flush()
}

// MARK: - HTML scanner

private func scanHTML(_ text: String) -> [SyntaxToken] {
    let chars = Array(text)
    var out = TokenBuilder()
    var i = 0

    while i < chars.count {
        if matches(chars, i, "<!--") {
            var j = i + 4
            while j < chars.count, !matches(chars, j, "-->") { j += 1 }
            j = j < chars.count ? j + 3 : chars.count
            out.emit(String(chars[i..<min(j, chars.count)]), .comment)
            i = min(j, chars.count)
            continue
        }
        if chars[i] == "<" {
            out.emit("<", .punctuation)
            i += 1
            if i < chars.count, chars[i] == "/" || chars[i] == "!" {
                out.emit(String(chars[i]), .punctuation)
                i += 1
            }
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" { j += 1 }
            out.emit(String(chars[i..<j]), .keyword)
            i = j
            // Attributes, up to the closing angle bracket.
            while i < chars.count, chars[i] != ">" {
                let c = chars[i]
                if c == "\"" || c == "'" {
                    var k = i + 1
                    while k < chars.count, chars[k] != c { k += 1 }
                    k = min(k + 1, chars.count)
                    out.emit(String(chars[i..<k]), .string)
                    i = k
                } else if c.isLetter || c == "_" {
                    var k = i
                    while k < chars.count, chars[k].isLetter || chars[k].isNumber
                            || chars[k] == "-" || chars[k] == "_" || chars[k] == ":" { k += 1 }
                    out.emit(String(chars[i..<k]), .key)
                    i = k
                } else if punctuationCharacters.contains(c) {
                    out.emit(String(c), .punctuation)
                    i += 1
                } else {
                    out.emit(String(c), .plain)
                    i += 1
                }
            }
            if i < chars.count {
                out.emit(">", .punctuation)
                i += 1
            }
            continue
        }
        var j = i
        while j < chars.count, chars[j] != "<" { j += 1 }
        out.emit(String(chars[i..<j]), .plain)
        i = j
    }
    return out.tokens
}
