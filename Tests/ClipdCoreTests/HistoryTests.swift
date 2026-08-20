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

@Test("A bare URL is a link, prose containing one is not")
func kindDetection() {
    #expect(item("https://claude.ai/code/artifact/59a22b55").kind == .link)
    #expect(item("http://example.com").kind == .link)
    #expect(item("  https://example.com  ").kind == .link)
    // Prose that merely mentions a URL is still text.
    #expect(item("see https://example.com for details").kind == .text)
    #expect(item("plain words").kind == .text)
    #expect(item("ftp://example.com").kind == .text)
    // Degenerate cases must not crash or misclassify.
    #expect(item("").kind == .text)
    #expect(item("   ").kind == .text)
}

@Test("Remove by id deletes the right item, even while a search is filtering")
func removeByID() {
    let history = History()
    _ = history.add(item("keep one", at: 100))
    _ = history.add(item("delete me", at: 200))
    _ = history.add(item("keep two", at: 300))

    // The panel shows filtered results, so position on screen is not position
    // in history. Deleting by index would remove the wrong row here.
    let filtered = history.search("delete")
    #expect(filtered.count == 1)
    #expect(history.remove(id: filtered[0].id) == true)
    #expect(history.items.map(\.text) == ["keep two", "keep one"])
}

@Test("Removing an id that is not present is a no-op, not a crash")
func removeMissingID() {
    let history = History()
    _ = history.add(item("only", at: 100))
    #expect(history.remove(id: UUID()) == false)
    #expect(history.items.count == 1)
    // And on an empty history.
    let empty = History()
    #expect(empty.remove(id: UUID()) == false)
}

private func imageItem(_ bytes: [UInt8], w: Int = 2560, h: Int = 1664,
                       at seconds: TimeInterval = 0) -> HistoryItem {
    HistoryItem(imageData: Data(bytes), pixelWidth: w, pixelHeight: h,
                sourceBundleID: "com.apple.screencaptureui", sourceName: "Screenshot",
                createdAt: Date(timeIntervalSince1970: seconds))
}

@Test("An image item is kind image and previews its dimensions")
func imageKindAndPreview() {
    let it = imageItem([0x89, 0x50, 0x4E, 0x47])
    #expect(it.kind == .image)
    #expect(it.preview == "Image 2560 x 1664")
    #expect(it.text.isEmpty)
    #expect(it.imageData?.count == 4)
}

@Test("Identical images dedup, different images do not")
func imageDedup() {
    let history = History()
    #expect(history.add(imageItem([1, 2, 3], at: 100)) == true)
    // Same bytes, different dimensions recorded: still the same picture.
    #expect(history.add(imageItem([1, 2, 3], at: 200)) == false)
    #expect(history.add(imageItem([9, 9, 9], at: 300)) == true)
    #expect(history.items.count == 2)
}

@Test("Image content hash is stable across instances, not process seeded")
func imageHashIsStable() {
    // Rejected: Data.hashValue, which is seeded per process. This has to hold
    // once these are written to disk and read back.
    #expect(imageItem([1, 2, 3]).contentHash == imageItem([1, 2, 3]).contentHash)
    #expect(imageItem([1, 2, 3]).contentHash != imageItem([3, 2, 1]).contentHash)
}

@Test("Images are findable by search even though they have no text")
func imagesAreSearchable() {
    let history = History()
    _ = history.add(imageItem([1, 2, 3], at: 100))
    _ = history.add(item("some ordinary text", at: 200))
    #expect(history.search("image").count == 1)
    #expect(history.search("2560").count == 1)
    #expect(history.search("ordinary").count == 1)
}

@Test("Adding a new item reports an insert, not a touch")
func hooksOnInsert() {
    let history = History()
    var inserted: [String] = []
    var touched = 0
    history.onInsert = { inserted.append($0.text) }
    history.onTouch = { _, _ in touched += 1 }
    _ = history.add(item("first", at: 100))
    #expect(inserted == ["first"])
    #expect(touched == 0)
}

@Test("A repeat copy reports a touch, not a second insert")
func hooksOnTouch() {
    let history = History()
    var inserts = 0
    var touches = 0
    history.onInsert = { _ in inserts += 1 }
    history.onTouch = { _, _ in touches += 1 }
    _ = history.add(item("same", at: 100))
    _ = history.add(item("same", at: 200))
    // Two copies of the same thing must not become two rows.
    #expect(inserts == 1)
    #expect(touches == 1)
}

@Test("Both delete paths report a delete")
func hooksOnDelete() {
    let history = History()
    var deleted = 0
    history.onDelete = { _ in deleted += 1 }
    _ = history.add(item("a", at: 100))
    _ = history.add(item("b", at: 200))
    history.removeMostRecent()
    #expect(deleted == 1)
    _ = history.remove(id: history.items[0].id)
    #expect(deleted == 2)
}

@Test("Loading from disk does not fire the persistence hooks")
func loadDoesNotEcho() {
    let history = History()
    var inserts = 0
    history.onInsert = { _ in inserts += 1 }
    // These rows came FROM the database. Firing onInsert would write them
    // straight back, which is a write amplification loop on every launch.
    history.load([item("from disk", at: 100)])
    #expect(inserts == 0)
    #expect(history.items.count == 1)
}

// MARK: - Item titles
//
// The point of naming an item is finding it later by a word that is not in it.

@Test("Search finds an item by a word that is only in its title")
func searchMatchesTheTitle() {
    let history = History()
    history.add(HistoryItem(text: "ALTER TABLE items ADD COLUMN title TEXT",
                            sourceBundleID: nil, sourceName: nil, createdAt: Date(),
                            title: "clipd migration three"))
    #expect(history.search("migration").count == 1)
    // And the content still matches, so naming an item does not replace what
    // it is, it adds to it.
    #expect(history.search("ALTER").count == 1)
    // A token from the title and a token from the content, together.
    #expect(history.search("clipd column").count == 1)
    #expect(history.search("clipd nonsense").isEmpty)
}

@Test("An untitled item is unaffected by title search")
func untitledItemsStillSearchable() {
    let history = History()
    history.add(HistoryItem(text: "docker compose up", sourceBundleID: nil,
                            sourceName: nil, createdAt: Date()))
    #expect(history.search("docker").count == 1)
    #expect(history.search("compose up").count == 1)
}

@Test("A blank title is stored as no title at all")
func blankTitlesBecomeNil() {
    // Otherwise "has a name" is two questions, nil and empty, and every call
    // site gets to pick the wrong one.
    let date = Date()
    #expect(HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil,
                        createdAt: date, title: "").title == nil)
    #expect(HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil,
                        createdAt: date, title: "   \n\t ").title == nil)
    #expect(HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil,
                        createdAt: date, title: nil).title == nil)
}

@Test("A title is trimmed and bounded")
func titlesAreTrimmedAndBounded() {
    let date = Date()
    #expect(HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil,
                        createdAt: date, title: "  prod key  ").title == "prod key")
    // A pasted paragraph in the name field would otherwise be stored forever
    // and drawn into a header one line tall.
    let long = String(repeating: "a", count: 500)
    #expect(HistoryItem(text: "x", sourceBundleID: nil, sourceName: nil,
                        createdAt: date, title: long).title?.count == 200)
}

@Test("An image can be named too, and found by that name")
func imagesCanBeNamed() {
    let history = History()
    history.add(HistoryItem(imageData: Data([1, 2, 3]), pixelWidth: 10, pixelHeight: 10,
                            sourceBundleID: nil, sourceName: nil, createdAt: Date(),
                            title: "architecture diagram"))
    #expect(history.search("architecture").count == 1)
    // The preview still works, so the old way of finding an image is intact.
    #expect(history.search("image").count == 1)
}

@Test("A title does not change the content hash, so naming is not a new item")
func titlesDoNotAffectDedup() {
    // If the title fed the hash, naming an item would make it stop matching the
    // copy of the same text on the other Mac, and dedup would keep both.
    let date = Date()
    let named = HistoryItem(text: "same text", sourceBundleID: nil, sourceName: nil,
                            createdAt: date, title: "a name")
    let plain = HistoryItem(text: "same text", sourceBundleID: nil, sourceName: nil,
                            createdAt: date)
    #expect(named.contentHash == plain.contentHash)
}

@Test("The card body may ask for more text than the stored preview holds")
func bodyLimitIsTheCallersChoice() {
    let long = String(repeating: "abcde ", count: 200)   // 1200 characters
    #expect(flattenedBody(long, limit: 200).count == 200)
    #expect(flattenedBody(long, limit: 700).count == 700)
    // The stored preview keeps its own limit, because it is on every row and
    // is what search reads.
    let item = HistoryItem(text: long, sourceBundleID: nil, sourceName: nil,
                           createdAt: Date())
    #expect(item.preview.count == 200)
}

@Test("Flattening still collapses every kind of line break")
func flatteningIsUnchanged() {
    #expect(flattenedBody("a\r\nb\nc\td", limit: 100) == "a b c d")
    #expect(flattenedBody("  padded  ", limit: 100) == "padded")
}

@Test("A huge paste is cut before it is flattened, not after")
func hugePasteStaysCheap() {
    // 3 MB. If the replacing ran on the whole string this test would take
    // long enough to notice, which is the point: it runs per visible card.
    let huge = String(repeating: "x", count: 3_000_000)
    #expect(flattenedBody(huge, limit: 700).count == 700)
}
