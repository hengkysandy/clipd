import Testing
import Foundation
@testable import ClipdCore

private func item(_ text: String, at seconds: TimeInterval = 0) -> HistoryItem {
    HistoryItem(text: text, sourceBundleID: "com.example.app",
                sourceName: "Example", createdAt: Date(timeIntervalSince1970: seconds))
}

@Test("Newest item comes first")
func newestFirst() {
    let history = History()
    _ = history.add(item("first", at: 100))
    _ = history.add(item("second", at: 200))
    #expect(history.items.map(\.text) == ["second", "first"])
}

@Test("Copying the same content twice does not duplicate it")
func dedup() {
    let history = History()
    #expect(history.add(item("same", at: 100)) == true)
    #expect(history.add(item("same", at: 200)) == false)
    #expect(history.items.count == 1)
}

@Test("A repeat copy moves the existing item back to the top")
func repeatCopyBumps() {
    let history = History()
    _ = history.add(item("old", at: 100))
    _ = history.add(item("new", at: 200))
    _ = history.add(item("old", at: 300))
    #expect(history.items.map(\.text) == ["old", "new"])
}

@Test("Search matches all tokens in any order, case insensitively")
func searchTokens() {
    let history = History()
    _ = history.add(item("arn:aws:ecs:ap-southeast-3:cluster/prod", at: 100))
    _ = history.add(item("hello world", at: 200))
    #expect(history.search("aws ecs").map(\.text).count == 1)
    #expect(history.search("ECS AWS").map(\.text).count == 1)
    #expect(history.search("aws nomatch").isEmpty)
}

@Test("An empty search returns everything, newest first")
func emptySearchReturnsAll() {
    let history = History()
    _ = history.add(item("a", at: 100))
    _ = history.add(item("b", at: 200))
    #expect(history.search("").map(\.text) == ["b", "a"])
    #expect(history.search("   ").map(\.text) == ["b", "a"])
}

@Test("Preview collapses newlines and is truncated")
func previewIsFlatAndShort() {
    let long = String(repeating: "x", count: 500)
    let it = item("line one\nline two\n\n" + long)
    #expect(!it.preview.contains("\n"))
    #expect(it.preview.count <= 200)
}

@Test("Removing the most recent item works and is safe when empty")
func removeMostRecent() {
    let history = History()
    // Degenerate case first: removing from an empty history must not crash.
    history.removeMostRecent()
    _ = history.add(item("a", at: 100))
    _ = history.add(item("b", at: 200))
    history.removeMostRecent()
    #expect(history.items.map(\.text) == ["a"])
}
