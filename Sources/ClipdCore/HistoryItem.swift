import Foundation
import CryptoKit

/// What a card shows in its header.
public enum ItemKind: String, Equatable, Sendable {
    case text
    case link
    case image
}

public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ItemKind
    /// The text payload. Empty for images.
    public let text: String
    /// The image payload, already compressed. Empty for text.
    ///
    /// In memory for now. Measured: a full screen retina grab is PNG at about
    /// 2.8 MB, so the storage plan moves these to encrypted files on disk and
    /// keeps only a path here.
    public let imageData: Data?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public let preview: String
    /// The language when this item is code, nil when it is prose, a link or an
    /// image. The card colours its body only when this is set.
    ///
    /// Computed here rather than stored in SQLite on purpose. It is derived
    /// from `text`, which is already stored in full, so persisting it would add
    /// a column and a migration to save one cheap scan of 2000 characters per
    /// row. Detection is also the part most likely to be tuned later, and a
    /// stored value would freeze every old row at whatever the rules were on
    /// the day it was copied.
    public let codeLanguage: CodeLanguage?
    /// A name the user gave this item, nil when they have not named it.
    ///
    /// Stored, unlike `codeLanguage`, because it cannot be derived from
    /// anything. It is searched alongside the content, so naming an item is a
    /// way of making it findable by a word that is not in it at all.
    ///
    /// Empty and whitespace-only titles are normalised to nil at every entry
    /// point, so "has a title" is one question with one answer everywhere
    /// rather than a check for nil in some places and for empty in others.
    public let title: String?
    public let sourceBundleID: String?
    public let sourceName: String?
    public let createdAt: Date
    public let contentHash: String

    /// What the card shows as its name, and what search matches first.
    public var displayTitle: String? { title }

    // MARK: - Text

    public init(id: UUID = UUID(), text: String, sourceBundleID: String?,
                sourceName: String?, createdAt: Date, title: String? = nil) {
        self.id = id
        self.text = text
        self.title = HistoryItem.normalisedTitle(title)
        self.imageData = nil
        self.pixelWidth = nil
        self.pixelHeight = nil
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.contentHash = text
        let kind = HistoryItem.detectKind(text)
        self.kind = kind
        self.preview = HistoryItem.makePreview(text)
        // A bare URL is never code. Skipping it also skips the whole scan for
        // the most common single line paste there is.
        self.codeLanguage = kind == .link ? nil : detectCodeLanguage(text)
    }

    // MARK: - Image

    public init(id: UUID = UUID(), imageData: Data, pixelWidth: Int, pixelHeight: Int,
                sourceBundleID: String?, sourceName: String?, createdAt: Date,
                title: String? = nil) {
        self.id = id
        self.text = ""
        self.title = HistoryItem.normalisedTitle(title)
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.kind = .image
        self.codeLanguage = nil
        // A content hash, not the bytes. Rejected: Data.hashValue, which is
        // seeded per process and so would not survive once these are persisted.
        self.contentHash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }.joined()
        // The preview doubles as the search text for an image, so typing
        // "image" finds them. Otherwise images would be unreachable by search.
        self.preview = "Image \(pixelWidth) x \(pixelHeight)"
    }

    /// Blank is not a title.
    ///
    /// A rename dialog left empty, or filled with spaces, means "no name", not
    /// a name made of nothing. Normalising here rather than at each call site
    /// is what lets every other place ask `title == nil` and be right.
    /// Bounded at 200 characters because the header shows one line, and a
    /// pasted paragraph in the title field would otherwise be stored forever.
    public static func normalisedTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }

    /// A single URL and nothing else reads as a link. Anything with whitespace
    /// is prose that happens to contain a URL, which is still text.
    static func detectKind(_ text: String) -> ItemKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return .text }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return .text }
        return .link
    }

    /// One line, bounded length. A card cannot show a 3 MB paste and trying to
    /// render one makes the panel stutter.
    static func makePreview(_ text: String) -> String {
        flattenedBody(text, limit: 200)
    }
}

/// The text of an item, flattened to one paragraph and bounded.
///
/// One flattening rule with two callers and two limits, rather than two copies
/// that drift. `HistoryItem.preview` uses 200 because it is stored on every row
/// and searched; a card asks for more because it has more room, and asking the
/// stored column instead was what left a third of every long card blank.
///
/// The input is cut before the replacing starts. Flattening a 3 MB paste per
/// visible card on every scroll would stutter the panel, and no card can show
/// more than a few hundred characters anyway. Twice the limit is enough slack
/// for the trimming that follows.
public func flattenedBody(_ text: String, limit: Int) -> String {
    let flat = String(text.prefix(limit * 2))
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(flat.prefix(limit))
}
