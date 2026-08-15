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
    public let sourceBundleID: String?
    public let sourceName: String?
    public let createdAt: Date
    public let contentHash: String

    // MARK: - Text

    public init(id: UUID = UUID(), text: String, sourceBundleID: String?,
                sourceName: String?, createdAt: Date) {
        self.id = id
        self.text = text
        self.imageData = nil
        self.pixelWidth = nil
        self.pixelHeight = nil
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.contentHash = text
        self.kind = HistoryItem.detectKind(text)
        self.preview = HistoryItem.makePreview(text)
    }

    // MARK: - Image

    public init(id: UUID = UUID(), imageData: Data, pixelWidth: Int, pixelHeight: Int,
                sourceBundleID: String?, sourceName: String?, createdAt: Date) {
        self.id = id
        self.text = ""
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.kind = .image
        // A content hash, not the bytes. Rejected: Data.hashValue, which is
        // seeded per process and so would not survive once these are persisted.
        self.contentHash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }.joined()
        // The preview doubles as the search text for an image, so typing
        // "image" finds them. Otherwise images would be unreachable by search.
        self.preview = "Image \(pixelWidth) x \(pixelHeight)"
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
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(200))
    }
}
