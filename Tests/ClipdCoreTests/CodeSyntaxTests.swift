import Testing
import Foundation
@testable import ClipdCore

// Samples are written the way they arrive on the clipboard: a few lines lifted
// out of a real file, indentation and all.

private let swiftSample = """
    func makePreview(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let flat = text.replacingOccurrences(of: "\\n", with: " ")
        return String(flat.prefix(200))
    }
    """

private let javascriptSample = """
    const users = await db.query("select * from users");
    export function greet(name) {
      console.log(`hello ${name}`);
      return name === "" ? null : name;
    }
    """

private let pythonSample = """
    def make_preview(text, limit=200):
        if not text:
            return ""
        flat = text.replace("\\n", " ")
        return flat[:limit]
    """

private let jsonSample = """
    {
      "id": "9f2c",
      "count": 12,
      "tags": ["a", "b"],
      "active": true
    }
    """

private let yamlSample = """
    version: "3.9"
    services:
      api:
        image: ghcr.io/example/api:1.4
        ports:
          - 8080:8080
        environment:
          LOG_LEVEL: debug
    """

private let markdownSample = """
    # Retention policy

    The sweep runs on launch and then hourly.

    - keeps the newest 500 items
    - deletes anything older than 30 days

    See [the notes](https://example.com/notes) for the measured numbers.
    """

private let shellSample = """
    #!/bin/bash
    set -euo pipefail
    docker compose up -d
    kubectl get pods -n prod | grep api
    """

private let sqlSample = """
    SELECT id, created_at, source_name
    FROM history
    WHERE created_at > now() - interval '30 days'
    ORDER BY created_at DESC
    LIMIT 50;
    """

private let htmlSample = """
    <!DOCTYPE html>
    <html lang="en">
      <body>
        <div class="card">Hello</div>
      </body>
    </html>
    """

private let cssSample = """
    .card {
      background-color: #1f1f1f;
      border-radius: 10px;
      padding: 12px 16px;
    }
    """

private let goSample = """
    package main

    import "fmt"

    func main() {
        items, err := load()
        if err != nil {
            return
        }
        fmt.Println(items)
    }
    """

private let rustSample = """
    pub fn preview(text: &str) -> String {
        let mut out = String::new();
        for line in text.lines().take(12) {
            out.push_str(line);
        }
        out
    }
    """

private let samples: [(CodeLanguage, String)] = [
    (.swift, swiftSample), (.javascript, javascriptSample), (.python, pythonSample),
    (.json, jsonSample), (.yaml, yamlSample), (.markdown, markdownSample),
    (.shell, shellSample), (.sql, sqlSample), (.html, htmlSample),
    (.css, cssSample), (.go, goSample), (.rust, rustSample),
]

// MARK: - Detection

@Test("Every supported language is detected from a realistic snippet")
func detectsEveryLanguage() {
    for (language, sample) in samples {
        #expect(detectCodeLanguage(sample) == language,
                "\(language.displayName) was read as \(detectCodeLanguage(sample)?.displayName ?? "prose")")
    }
}

@Test("Every language has a display name for the card header")
func everyLanguageHasADisplayName() {
    for language in CodeLanguage.allCases {
        #expect(!language.displayName.isEmpty)
    }
    #expect(CodeLanguage.javascript.displayName == "JavaScript")
    #expect(CodeLanguage.json.displayName == "JSON")
}

@Test("A paragraph of English prose is not code")
func proseIsNotCode() {
    // The case that matters most. Colouring an email as Swift is a bug you see
    // every day; missing the colours on a snippet is a bug you never notice.
    let prose = """
        Thanks for the quick reply. I went through the numbers again this \
        morning and the second option still looks better to me, mostly because \
        it does not need a migration. If you want, we can go over it tomorrow \
        before the standup and decide then.
        """
    #expect(detectCodeLanguage(prose) == nil)
}

@Test("A bare URL, an email address and a postal address are not code")
func contactDetailsAreNotCode() {
    #expect(detectCodeLanguage("https://claude.ai/code/artifact/59a22b55-1c2d") == nil)
    #expect(detectCodeLanguage("someone.longer@example-company.com") == nil)
    #expect(detectCodeLanguage("""
        Jalan Jenderal Sudirman No 52
        Kebayoran Baru, Jakarta Selatan 12190
        Indonesia
        """) == nil)
}

@Test("A short sentence containing a colon is not YAML")
func sentenceWithAColonIsNotYAML() {
    // One `key: value` line is a note to yourself. Two is a config file.
    #expect(detectCodeLanguage("Reminder: call the bank before Friday.") == nil)
    #expect(detectCodeLanguage("Note: the invoice number is 44821 and it is due.") == nil)
}

@Test("A random password-like string is not code")
func passwordIsNotCode() {
    // These are full of the punctuation the scoring looks for, and they must
    // never be highlighted. A password should not even be here, but if the
    // deny-list misses one it must still look like a boring grey card.
    #expect(detectCodeLanguage("Xk9#mQ2$vL8pR!aZ7tW3") == nil)
    #expect(detectCodeLanguage("aws_secret::4f8b{c2}=91d/dK+7q") == nil)
}

@Test("A prose list and a plain word list are not Markdown")
func plainListIsNotMarkdown() {
    #expect(detectCodeLanguage("""
        milk
        bread
        coffee beans
        """) == nil)
}

@Test("The everyday clipboard stays grey: mail, notes, paths, ids and numbers")
func everydayTextIsNotCode() {
    // A sweep of the things that actually land on a clipboard all day. Each one
    // contains punctuation the scoring looks at, and none of them is code.
    let everyday = [
        "Hi Sarah, please find the invoice attached. Let me know if the totals look right.",
        "Meeting notes: we agreed to ship on Friday, and Tom will handle the release notes.",
        "Order #44821 was delivered to 52 Wellington Street, Level 3, Melbourne VIC 3000.",
        "The flight leaves at 09:45 and arrives at 13:20, so we have about two hours.",
        "arn:aws:ecs:ap-southeast-3:123456789012:cluster/prod-cluster",
        "/Users/someone/Library/Application Support/Clipd/history.sqlite",
        "Dear team,\n\nThank you for the work this quarter. Revenue is up and churn is down.\n\nAnna",
        "TODO:\n- call the accountant\n- renew the domain\n- book the flights",
        "Q3 revenue: 1.2M\nQ4 revenue: 1.6M",
        "He said: \"I will be there at six.\" She replied that it was far too early.",
        "Berlin, Germany | +49 30 123456 | anna.mueller@example.de",
        "Please update the set of files and drop the old ones when you get a chance.",
    ]
    for text in everyday {
        let language = detectCodeLanguage(text)
        #expect(language == nil,
                "read as \(language?.displayName ?? "-"): \(text.prefix(40))")
    }
}

@Test("A one line SQL statement is still recognised")
func oneLineSQL() {
    // Too few keywords to pass on words alone. The semicolon and the column
    // list are what carry it over the threshold.
    #expect(detectCodeLanguage("insert into history (id, text) values ($1, $2) on conflict do nothing;") == .sql)
}

@Test("Very short text never gets a language")
func shortTextIsNotCode() {
    #expect(detectCodeLanguage("") == nil)
    #expect(detectCodeLanguage("   ") == nil)
    #expect(detectCodeLanguage("ok") == nil)
    #expect(detectCodeLanguage("func x() {") == nil)
}

@Test("TypeScript is folded into JavaScript rather than getting its own case")
func typescriptFoldsIntoJavascript() {
    let ts = """
        export interface Card {
          id: string;
          count: number;
        }
        const render = (card: Card): string => card.id;
        """
    #expect(detectCodeLanguage(ts) == .javascript)
}

@Test("Minified JSON is detected even though it has no whitespace")
func minifiedJSON() {
    // The no-whitespace guard that throws out URLs and passwords runs after the
    // JSON parse, exactly so this case survives it.
    #expect(detectCodeLanguage("{\"id\":\"9f2c\",\"count\":12,\"active\":true}") == .json)
}

@Test("A truncated JSON document is still detected from its first 2000 characters")
func truncatedJSONFallsBackToShape() {
    // Only a prefix is ever scanned, so a large document can never parse. The
    // shape check has to carry it.
    let body = (0..<400).map { "  \"field\($0)\": \"value\($0)\"" }.joined(separator: ",\n")
    let big = "{\n" + body + "\n}"
    #expect(big.count > 2000)
    #expect(detectCodeLanguage(big) == .json)
}

@Test("Detection only reads a prefix, so a huge paste stays cheap")
func detectionIsBounded() {
    let huge = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 40_000)
    let start = Date()
    #expect(detectCodeLanguage(huge) == nil)
    // Generous on purpose: this is a smoke test for "does it scan the whole 1.8
    // MB", not a benchmark. A full scan of this input takes well over a second.
    #expect(Date().timeIntervalSince(start) < 0.5)
}

// MARK: - The round trip invariant

@Test("Joining the tokens reproduces the input exactly, for every sample")
func highlightingIsLossless() {
    for (language, sample) in samples {
        let rebuilt = highlight(sample, as: language).map(\.text).joined()
        #expect(rebuilt == sample, "\(language.displayName) lost or duplicated characters")
    }
}

@Test("The round trip survives the ugly inputs: unterminated quotes and stray markers")
func highlightingIsLosslessOnBrokenInput() {
    // A preview is a truncated snippet, so half a string literal and half a
    // comment are normal, not exceptional.
    let broken = [
        "let name = \"unterminated",
        "/* an unclosed block comment",
        "value: 'still open\nnext: 2",
        "**bold that never closes and `code that never closes",
        "<div class=\"card",
        "emoji 🇮🇩 and an accent café inside a token",
        "\n\n\n",
        "   ",
        "-",
        "#",
    ]
    for text in broken {
        for language in CodeLanguage.allCases {
            let rebuilt = highlight(text, as: language).map(\.text).joined()
            #expect(rebuilt == text, "\(language.displayName) mangled \(text.count) characters")
        }
    }
}

@Test("An empty input produces no tokens at all")
func emptyHighlight() {
    for language in CodeLanguage.allCases {
        #expect(highlight("", as: language).isEmpty)
    }
}

@Test("Highlighting the same text twice gives the same tokens")
func highlightingIsStable() {
    // No caches, no shared state, no ordering that depends on a Set. If this
    // ever fails, a card would repaint differently on every scroll.
    for (language, sample) in samples {
        #expect(highlight(sample, as: language) == highlight(sample, as: language))
    }
}

// MARK: - Token kinds

@Test("Swift keywords, strings and types get their own kinds")
func swiftTokenKinds() {
    let tokens = highlight(swiftSample, as: .swift)
    #expect(tokens.contains(SyntaxToken(text: "func", kind: .keyword)))
    #expect(tokens.contains(SyntaxToken(text: "String", kind: .type)))
    #expect(tokens.contains { $0.kind == .string })
    #expect(tokens.contains { $0.kind == .number })
}

@Test("A JSON name before a colon is a key, the value beside it is a string")
func jsonKeysAreKeys() {
    let tokens = highlight(jsonSample, as: .json)
    #expect(tokens.contains(SyntaxToken(text: "\"id\"", kind: .key)))
    #expect(tokens.contains(SyntaxToken(text: "\"9f2c\"", kind: .string)))
    #expect(tokens.contains(SyntaxToken(text: "true", kind: .keyword)))
    #expect(tokens.contains { $0.kind == .number && $0.text == "12" })
}

@Test("A CSS property before a colon is a key")
func cssPropertiesAreKeys() {
    let tokens = highlight(cssSample, as: .css)
    // The dash is part of the identifier, otherwise this would be "background"
    // plus punctuation plus "color".
    #expect(tokens.contains(SyntaxToken(text: "background-color", kind: .key)))
}

@Test("YAML keys, comments and quoted values are separated")
func yamlTokenKinds() {
    let tokens = highlight("# the api tier\nname: \"clipd\"\nreplicas: 2\n", as: .yaml)
    #expect(tokens.contains(SyntaxToken(text: "name", kind: .key)))
    #expect(tokens.contains(SyntaxToken(text: "\"clipd\"", kind: .string)))
    #expect(tokens.contains(SyntaxToken(text: "2", kind: .number)))
    #expect(tokens.contains { $0.kind == .comment })
}

@Test("Markdown headings, inline code and links are marked")
func markdownTokenKinds() {
    let tokens = highlight(markdownSample, as: .markdown)
    #expect(tokens.contains { $0.kind == .keyword && $0.text.hasPrefix("# ") })
    #expect(tokens.contains(SyntaxToken(text: "[the notes]", kind: .emphasis)))
    #expect(tokens.contains(SyntaxToken(text: "(https://example.com/notes)", kind: .string)))
}

@Test("A shell comment and a variable are not the same as a command")
func shellTokenKinds() {
    let tokens = highlight("# deploy\necho \"$HOME/bin\" ${TAG}\n", as: .shell)
    #expect(tokens.contains { $0.kind == .comment && $0.text == "# deploy" })
    #expect(tokens.contains(SyntaxToken(text: "echo", kind: .keyword)))
    #expect(tokens.contains(SyntaxToken(text: "${TAG}", kind: .type)))
}

@Test("SQL keywords match whatever case they were typed in")
func sqlKeywordsAreCaseInsensitive() {
    let upper = highlight("SELECT id FROM history;", as: .sql)
    let lower = highlight("select id from history;", as: .sql)
    #expect(upper.contains(SyntaxToken(text: "SELECT", kind: .keyword)))
    #expect(lower.contains(SyntaxToken(text: "select", kind: .keyword)))
}

@Test("An HTML tag name and its attributes are told apart")
func htmlTokenKinds() {
    let tokens = highlight("<div class=\"card\">Hello</div>", as: .html)
    #expect(tokens.contains(SyntaxToken(text: "div", kind: .keyword)))
    #expect(tokens.contains(SyntaxToken(text: "class", kind: .key)))
    #expect(tokens.contains(SyntaxToken(text: "\"card\"", kind: .string)))
    #expect(tokens.contains(SyntaxToken(text: "Hello", kind: .plain)))
}

@Test("Neighbouring runs of the same kind are merged into one token")
func tokensAreMerged() {
    // A card should get a handful of attributed runs, not one per character.
    let tokens = highlight(swiftSample, as: .swift)
    for (a, b) in zip(tokens, tokens.dropFirst()) {
        #expect(a.kind != b.kind, "two \(a.kind.rawValue) tokens in a row were not merged")
    }
}

// MARK: - The preview

@Test("The code preview keeps its newlines instead of flattening them")
func previewKeepsNewlines() {
    let preview = makeCodePreview(swiftSample)
    #expect(preview.contains("\n"))
    #expect(preview.components(separatedBy: "\n").count == 5)
}

@Test("Shared leading indentation is removed but relative indentation is kept")
func previewDedents() {
    let nested = """
                if let item = history.first {
                    let name = item.text
                    return name
                }
        """
    let preview = makeCodePreview(nested)
    let lines = preview.components(separatedBy: "\n")
    #expect(lines[0] == "if let item = history.first {")
    // The inner lines keep the four spaces that make the block readable.
    #expect(lines[1] == "    let name = item.text")
    #expect(lines[3] == "}")
}

@Test("A blank line in the middle does not defeat the dedent")
func previewDedentsAroundBlankLines() {
    let text = "    first\n\n    second"
    #expect(makeCodePreview(text) == "first\n\nsecond")
}

@Test("Tabs become spaces so the card lines up in a monospaced font")
func previewExpandsTabs() {
    let preview = makeCodePreview("func a() {\n\tlet x = 1\n}")
    #expect(!preview.contains("\t"))
    #expect(preview.contains("    let x = 1"))
}

@Test("The line cap holds and says that something was cut")
func previewLineCap() {
    let long = (1...50).map { "line \($0)" }.joined(separator: "\n")
    let preview = makeCodePreview(long, maxLines: 6)
    let lines = preview.components(separatedBy: "\n")
    #expect(lines.count == 6)
    #expect(lines.first == "line 1")
    #expect(lines.last == "…")
}

@Test("The character cap holds even when the line count does not")
func previewCharCap() {
    let wide = (1...4).map { _ in String(repeating: "x", count: 400) }.joined(separator: "\n")
    let preview = makeCodePreview(wide, maxLines: 12, maxChars: 200)
    #expect(preview.count == 200)
    #expect(preview.hasSuffix("…"))
}

@Test("Leading and trailing blank lines are dropped, so the card starts at the code")
func previewTrimsBlankEdges() {
    #expect(makeCodePreview("\n\n  let x = 1\n\n\n") == "let x = 1")
}

@Test("Degenerate previews do not crash")
func previewDegenerateInputs() {
    #expect(makeCodePreview("") == "")
    #expect(makeCodePreview("\n\n\n") == "")
    #expect(makeCodePreview("   ") == "")
    #expect(makeCodePreview("one line", maxLines: 1) == "one line")
}

@Test("The preview is the thing that gets highlighted, and that is still lossless")
func previewThenHighlightRoundTrips() {
    for (language, sample) in samples {
        let preview = makeCodePreview(sample)
        #expect(highlight(preview, as: language).map(\.text).joined() == preview)
    }
}

// MARK: - The item

private func item(_ text: String) -> HistoryItem {
    HistoryItem(text: text, sourceBundleID: "com.example.app", sourceName: "Example",
                createdAt: Date(timeIntervalSince1970: 100))
}

@Test("A code item carries its language, a prose item does not")
func itemCarriesLanguage() {
    #expect(item(swiftSample).codeLanguage == .swift)
    #expect(item(jsonSample).codeLanguage == .json)
    #expect(item("Thanks, I will look at this tomorrow morning.").codeLanguage == nil)
}

@Test("A link item is never code, even when the URL is full of punctuation")
func linkItemIsNeverCode() {
    let link = item("https://example.com/a/b?x=1&y={2}")
    #expect(link.kind == .link)
    #expect(link.codeLanguage == nil)
}

@Test("An image item has no language")
func imageItemHasNoLanguage() {
    let image = HistoryItem(imageData: Data([1, 2, 3]), pixelWidth: 10, pixelHeight: 10,
                            sourceBundleID: nil, sourceName: nil, createdAt: Date())
    #expect(image.codeLanguage == nil)
}

@Test("The stored preview and content hash are untouched by the code feature")
func storedFieldsAreUnchanged() {
    // `preview` is written to SQLite and is what search matches on. Changing it
    // would need a migration and would break search on every existing row, for
    // no gain: the card renders from `text`, which is stored in full.
    let it = item(swiftSample)
    #expect(!it.preview.contains("\n"))
    #expect(it.preview.count <= 200)
    #expect(it.contentHash == swiftSample)
}

// MARK: - YAML against Markdown
//
// A `#` line is a heading in Markdown and a comment in YAML, so a config file
// that opens with comments fires both detectors. This was found in the running
// app, not in a test: a commented Kubernetes manifest was labelled Markdown.

@Test("A YAML manifest that opens with comment lines is YAML, not Markdown")
func commentedYAMLIsNotMarkdown() {
    let manifest = """
    # LOCAL STAND-IN for Amazon RDS
    # not a backup strategy, see docs
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: postgres
    spec:
      replicas: 1
      serviceName: postgres
    """
    #expect(detectCodeLanguage(manifest) == .yaml)
}

@Test("A docker compose file full of comments is still YAML")
func commentedComposeIsYAML() {
    let compose = """
    # development only
    services:
      api:
        image: node:20-alpine
        # the port the app listens on
        ports:
          - "3000:3000"
    """
    #expect(detectCodeLanguage(compose) == .yaml)
}

@Test("Real Markdown is still Markdown, even with a colon line in it")
func realMarkdownStillWins() {
    let doc = """
    # Release notes

    Version: 0.5.0 is out.

    - syntax colours
    - see [the repo](https://example.com)

    ```bash
    brew install clipd
    ```
    """
    #expect(detectCodeLanguage(doc) == .markdown)
}

@Test("A YAML file with no comments is unaffected by the comparison")
func plainYAMLUnchanged() {
    let plain = """
    services:
      api:
        image: node:20-alpine
        ports:
          - "3000:3000"
    """
    #expect(detectCodeLanguage(plain) == .yaml)
}
