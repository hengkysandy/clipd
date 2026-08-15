import Foundation

/// What a card shows in its header. Deliberately small: the spec collapsed
/// link, rich text and file into text plus metadata, so this is a display
/// concern, not a storage one.
public enum ItemKind: String, Equatable, Sendable {
    case text
    case link
}

public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let preview: String
    public let sourceBundleID: String?
    public let sourceName: String?
    public let createdAt: Date
    /// Cheap dedup key. The storage plan replaces this with a real hash; for an
    /// in-memory skeleton the text itself is enough and avoids pulling CryptoKit
    /// into a pure module.
    public let contentHash: String

    public init(id: UUID = UUID(), text: String, sourceBundleID: String?,
                sourceName: String?, createdAt: Date) {
        self.id = id
        self.text = text
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.contentHash = text
        self.preview = HistoryItem.makePreview(text)
    }

    /// A single URL and nothing else reads as a link. Anything with whitespace
    /// is prose that happens to contain a URL, which is still text.
    public var kind: ItemKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace) else { return .text }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return .text }
        return .link
    }

    /// One line, bounded length. A card cannot show a 3 MB paste and trying to
    /// render one makes the panel stutter.
    static func makePreview(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(200))
    }
}
