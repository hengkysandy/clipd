import Foundation
import ClipdCore

/// Maps HistoryItem to and from rows. Owns nothing else.
final class SQLiteStore {
    private let db: Database
    private let blobs: BlobStore
    private let deviceID: String

    init(database: Database, blobs: BlobStore, deviceID: String) {
        self.db = database
        self.blobs = blobs
        self.deviceID = deviceID
    }

    /// Newest first, tombstones excluded.
    func loadAll(limit: Int) throws -> [HistoryItem] {
        let rows = try db.query("""
            SELECT id, kind, created_at, source_bundle, source_name, source_url,
                   content_hash, text_content, preview, px_width, px_height, blob_ref
            FROM items
            WHERE deleted_at IS NULL
            ORDER BY created_at DESC
            LIMIT ?
            """, [.int(Int64(limit))])

        return rows.compactMap { row -> HistoryItem? in
            guard case .text(let idString)? = row["id"], let id = UUID(uuidString: idString),
                  case .text(let kind)? = row["kind"],
                  case .int(let created)? = row["created_at"] else { return nil }
            let createdAt = Date(timeIntervalSince1970: Double(created) / 1000)
            let bundle = row["source_bundle"].flatMap { if case .text(let s) = $0 { return s } else { return nil } }
            let name = row["source_name"].flatMap { if case .text(let s) = $0 { return s } else { return nil } }

            if kind == "image" {
                guard case .text(let ref)? = row["blob_ref"],
                      case .int(let w)? = row["px_width"],
                      case .int(let h)? = row["px_height"],
                      // A missing or unreadable blob means the row is useless.
                      // Skipping beats showing a card that cannot be pasted.
                      let data = try? blobs.read(ref) else { return nil }
                return HistoryItem(id: id, imageData: data,
                                   pixelWidth: Int(w), pixelHeight: Int(h),
                                   sourceBundleID: bundle, sourceName: name,
                                   createdAt: createdAt)
            }
            guard case .text(let text)? = row["text_content"] else { return nil }
            return HistoryItem(id: id, text: text, sourceBundleID: bundle,
                               sourceName: name, createdAt: createdAt)
        }
    }

    func insert(_ item: HistoryItem) throws {
        var blobRef: SQLValue = .null
        if item.kind == .image, let data = item.imageData {
            blobRef = .text(try blobs.write(data, id: item.id))
        }
        let millis = Int64(item.createdAt.timeIntervalSince1970 * 1000)
        try db.run("""
            INSERT OR REPLACE INTO items
              (id, kind, created_at, updated_at, deleted_at, device_id,
               source_bundle, source_name, source_url, content_hash,
               text_content, preview, char_count, px_width, px_height,
               blob_ref, pinned)
            VALUES (?,?,?,?,NULL,?,?,?,NULL,?,?,?,?,?,?,?,0)
            """, [
                .text(item.id.uuidString),
                .text(item.kind.rawValue),
                .int(millis),
                .int(millis),
                .text(deviceID),
                item.sourceBundleID.map { SQLValue.text($0) } ?? .null,
                item.sourceName.map { SQLValue.text($0) } ?? .null,
                .text(item.contentHash),
                item.kind == .image ? .null : .text(item.text),
                .text(item.preview),
                item.kind == .image ? .null : .int(Int64(item.text.count)),
                item.pixelWidth.map { SQLValue.int(Int64($0)) } ?? .null,
                item.pixelHeight.map { SQLValue.int(Int64($0)) } ?? .null,
                blobRef,
            ])
        try reindex(id: item.id)
    }

    /// A repeat copy. Bumps the sync clock without creating a second row.
    func touch(id: UUID, at date: Date) throws {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        try db.run("UPDATE items SET created_at = ?, updated_at = ? WHERE id = ?",
                   [.int(millis), .int(millis), .text(id.uuidString)])
    }

    /// The normal delete. A tombstone, so a sync cannot resurrect it.
    func softDelete(id: UUID, at date: Date) throws {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        try db.run("UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ?",
                   [.int(millis), .int(millis), .text(id.uuidString)])
        try db.run("DELETE FROM items_fts WHERE rowid IN (SELECT rowid FROM items WHERE id = ?)",
                   [.text(id.uuidString)])
    }

    /// For a secret caught late by the auto-clear rule. The payload must not
    /// survive in a soft deleted row, and must never reach R2.
    func hardDelete(id: UUID) throws {
        let rows = try db.query("SELECT blob_ref FROM items WHERE id = ?", [.text(id.uuidString)])
        if case .text(let ref)? = rows.first?["blob_ref"] {
            try? blobs.delete(ref)
        }
        try db.run("DELETE FROM items_fts WHERE rowid IN (SELECT rowid FROM items WHERE id = ?)",
                   [.text(id.uuidString)])
        try db.run("DELETE FROM items WHERE id = ?", [.text(id.uuidString)])
    }

    private func reindex(id: UUID) throws {
        try db.run("""
            INSERT INTO items_fts(rowid, text_content, preview)
            SELECT rowid, text_content, preview FROM items WHERE id = ?
            """, [.text(id.uuidString)])
    }

    /// Retention sweep. A tombstone, not a hard delete, so a v1.1 sync cannot
    /// resurrect an item this Mac expired. The blob goes immediately though:
    /// a tombstone that leaves a 2.8 MB encrypted screenshot on disk is not a
    /// delete in any sense the user would recognise.
    func expire(ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else { return }
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        for id in ids {
            let rows = try db.query("SELECT blob_ref FROM items WHERE id = ?",
                                    [.text(id.uuidString)])
            if case .text(let ref)? = rows.first?["blob_ref"] {
                try? blobs.delete(ref)
            }
            try db.run("""
                UPDATE items SET deleted_at = ?, updated_at = ?, blob_ref = NULL
                WHERE id = ?
                """, [.int(millis), .int(millis), .text(id.uuidString)])
            try db.run("""
                DELETE FROM items_fts
                WHERE rowid IN (SELECT rowid FROM items WHERE id = ?)
                """, [.text(id.uuidString)])
        }
    }

    /// Erase History. Removes every row and every blob outright.
    ///
    /// Hard delete, not tombstones. The user asked for the data to be gone, and
    /// leaving a tombstone for every item they just erased would ship their
    /// entire history shape to R2 in v1.1.
    func eraseAll() throws {
        let rows = try db.query("SELECT blob_ref FROM items WHERE blob_ref IS NOT NULL", [])
        for row in rows {
            if case .text(let ref)? = row["blob_ref"] { try? blobs.delete(ref) }
        }
        try db.execute("DELETE FROM items_fts")
        try db.execute("DELETE FROM items")
    }
}
