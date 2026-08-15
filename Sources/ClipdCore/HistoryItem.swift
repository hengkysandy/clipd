import Foundation

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
