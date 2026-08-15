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

    // MARK: - Sync

    /// Every row including tombstones, as sync records.
    ///
    /// Tombstones are included on purpose. Without them the other Mac never
    /// learns about a delete and resurrects it on the next pass.
    func allRecords() throws -> [SyncRecord] {
        try db.query("SELECT id, updated_at, deleted_at, device_id FROM items", [])
            .compactMap { row in
                guard case .text(let idString)? = row["id"], let id = UUID(uuidString: idString),
                      case .int(let updated)? = row["updated_at"],
                      case .text(let device)? = row["device_id"] else { return nil }
                var deletedAt: Date?
                if case .int(let deleted)? = row["deleted_at"] {
                    deletedAt = Date(timeIntervalSince1970: Double(deleted) / 1000)
                }
                return SyncRecord(id: id,
                                  updatedAt: Date(timeIntervalSince1970: Double(updated) / 1000),
                                  deletedAt: deletedAt, deviceID: device)
            }
    }

    /// The full row, ready to be encrypted and uploaded.
    ///
    /// Framed as a 4 byte big endian JSON length, then the JSON metadata, then
    /// the raw image bytes. Rejected: base64 inside the JSON, which is what this
    /// replaced. Base64 inflates binary by a third, so a 2.7 MB screenshot cost
    /// a 3.76 MB upload and bought nothing.
    func payload(for id: UUID) throws -> Data? {
        let rows = try db.query("""
            SELECT id, kind, created_at, updated_at, deleted_at, device_id,
                   source_bundle, source_name, source_url, content_hash,
                   text_content, preview, char_count, px_width, px_height, blob_ref
            FROM items WHERE id = ?
            """, [.text(id.uuidString)])
        guard let row = rows.first else { return nil }

        var json: [String: Any] = [:]
        for (name, value) in row {
            switch value {
            case .text(let s): json[name] = s
            case .int(let n): json[name] = n
            case .blob, .null: break
            }
        }
        let meta = try JSONSerialization.data(withJSONObject: json)

        var out = Data()
        // Big endian because it is the usual wire order, so a future non-Mac
        // reader does not need to know how this machine stores integers.
        var header = UInt32(meta.count).bigEndian
        withUnsafeBytes(of: &header) { out.append(contentsOf: $0) }
        out.append(meta)
        // The image bytes still travel inside the same payload. Rejected:
        // a second object per image, which doubles the request count and makes
        // an item and its picture separately losable.
        if case .text(let ref)? = row["blob_ref"], let data = try? blobs.read(ref) {
            out.append(data)
        }
        return out
    }

    /// Writes a row that came from the other Mac.
    ///
    /// Reads both payload formats on purpose. The other Mac may still be running
    /// the old build, which uploaded plain JSON with the image base64 encoded
    /// under "blob_data". A payload whose first byte is `{` is that old format.
    /// Dropping it would strand a pair of Macs on different versions, each
    /// unable to read what the other uploads, so the old path stays until both
    /// ends are known to be new.
    func apply(payload: Data) throws {
        guard let firstByte = payload.first else { return }

        var meta = payload
        var imageData: Data?
        if firstByte != 0x7B {
            // New format: 4 byte big endian JSON length, the JSON, then the raw
            // image bytes if there are any.
            guard payload.count >= 4 else { return }
            let start = payload.startIndex
            let length = Int(payload[start ..< start + 4]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            // A length that runs past the end means a truncated or corrupt
            // payload. Return rather than slice out of bounds and crash.
            guard payload.count >= 4 + length else { return }
            meta = payload.subdata(in: (start + 4) ..< (start + 4 + length))
            let rest = payload.subdata(in: (start + 4 + length) ..< payload.endIndex)
            if !rest.isEmpty { imageData = rest }
        }

        guard let json = try JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            return
        }
        // Only the old format puts the image in the JSON.
        if imageData == nil, let base64 = json["blob_data"] as? String {
            imageData = Data(base64Encoded: base64)
        }
        var blobRef: SQLValue = .null
        if let data = imageData {
            blobRef = .text(try blobs.write(data, id: id))
        }
        func text(_ key: String) -> SQLValue {
            (json[key] as? String).map { SQLValue.text($0) } ?? .null
        }
        func int(_ key: String) -> SQLValue {
            (json[key] as? Int64).map { SQLValue.int($0) }
                ?? (json[key] as? Int).map { SQLValue.int(Int64($0)) } ?? .null
        }
        try db.run("""
            INSERT OR REPLACE INTO items
              (id, kind, created_at, updated_at, deleted_at, device_id,
               source_bundle, source_name, source_url, content_hash,
               text_content, preview, char_count, px_width, px_height,
               blob_ref, pinned)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
            """, [
                .text(id.uuidString), text("kind"), int("created_at"), int("updated_at"),
                int("deleted_at"), text("device_id"), text("source_bundle"),
                text("source_name"), text("source_url"), text("content_hash"),
                text("text_content"), text("preview"), int("char_count"),
                int("px_width"), int("px_height"), blobRef,
            ])
        try db.run("""
            INSERT INTO items_fts(rowid, text_content, preview)
            SELECT rowid, text_content, preview FROM items WHERE id = ?
            """, [.text(id.uuidString)])
    }

    /// Marks an item deleted because the other Mac deleted it.
    func applyTombstone(id: UUID, at date: Date) throws {
        try softDelete(id: id, at: date)
    }

    // MARK: - Pinboards

    func allPinboards() throws -> [Pinboard] {
        try db.query("""
            SELECT id, name, color, sort_order FROM pinboards
            WHERE deleted_at IS NULL ORDER BY sort_order ASC
            """, []).compactMap { row in
                guard case .text(let idString)? = row["id"], let id = UUID(uuidString: idString),
                      case .text(let name)? = row["name"],
                      case .text(let color)? = row["color"],
                      case .int(let order)? = row["sort_order"] else { return nil }
                return Pinboard(id: id, name: name, colorName: color, sortOrder: Int(order))
            }
    }

    @discardableResult
    func createPinboard(name: String) throws -> Pinboard {
        let existing = try allPinboards()
        let board = Pinboard(name: name,
                             colorName: nextColor(after: existing.map(\.colorName)),
                             sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("""
            INSERT INTO pinboards (id, name, color, sort_order, updated_at, deleted_at, device_id)
            VALUES (?,?,?,?,?,NULL,?)
            """, [.text(board.id.uuidString), .text(board.name), .text(board.colorName),
                  .int(Int64(board.sortOrder)), .int(millis), .text(deviceID)])
        return board
    }

    /// A tombstone, not a row removal, so a sync cannot resurrect the board.
    ///
    /// The memberships are tombstoned too, but the ITEMS are untouched. A board
    /// is a label, not a container, and losing history because you tidied up a
    /// board would be unforgivable.
    func deletePinboard(id: UUID) throws {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE pinboards SET deleted_at = ?, updated_at = ? WHERE id = ?",
                   [.int(millis), .int(millis), .text(id.uuidString)])
        try db.run("""
            UPDATE item_pinboards SET deleted_at = ?, updated_at = ? WHERE pinboard_id = ?
            """, [.int(millis), .int(millis), .text(id.uuidString)])
    }

    func renamePinboard(id: UUID, to name: String) throws {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE pinboards SET name = ?, updated_at = ? WHERE id = ?",
                   [.text(name), .int(millis), .text(id.uuidString)])
    }

    func membership() throws -> [UUID: Set<UUID>] {
        var out: [UUID: Set<UUID>] = [:]
        for row in try db.query("""
            SELECT item_id, pinboard_id FROM item_pinboards WHERE deleted_at IS NULL
            """, []) {
            guard case .text(let itemString)? = row["item_id"],
                  case .text(let boardString)? = row["pinboard_id"],
                  let item = UUID(uuidString: itemString),
                  let board = UUID(uuidString: boardString) else { continue }
            out[board, default: []].insert(item)
        }
        return out
    }

    func setMembership(item: UUID, board: UUID, on: Bool) throws {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("""
            INSERT OR REPLACE INTO item_pinboards
              (item_id, pinboard_id, updated_at, deleted_at, device_id)
            VALUES (?,?,?,?,?)
            """, [.text(item.uuidString), .text(board.uuidString), .int(millis),
                  on ? .null : .int(millis), .text(deviceID)])
    }

    /// Every item filed on any board. Retention must not expire these.
    func pinnedItemIDs() throws -> Set<UUID> {
        var out: Set<UUID> = []
        for row in try db.query("""
            SELECT DISTINCT item_id FROM item_pinboards WHERE deleted_at IS NULL
            """, []) {
            if case .text(let s)? = row["item_id"], let id = UUID(uuidString: s) {
                out.insert(id)
            }
        }
        return out
    }

    // MARK: - Board sync

    /// Boards as sync records, tombstones included, so the other Mac learns
    /// about a deleted board rather than resurrecting it.
    func boardRecords() throws -> [SyncRecord] {
        try db.query("SELECT id, updated_at, deleted_at, device_id FROM pinboards", [])
            .compactMap { row in
                guard case .text(let s)? = row["id"], let id = UUID(uuidString: s),
                      case .int(let updated)? = row["updated_at"],
                      case .text(let device)? = row["device_id"] else { return nil }
                var deletedAt: Date?
                if case .int(let d)? = row["deleted_at"] {
                    deletedAt = Date(timeIntervalSince1970: Double(d) / 1000)
                }
                return SyncRecord(id: id,
                                  updatedAt: Date(timeIntervalSince1970: Double(updated) / 1000),
                                  deletedAt: deletedAt, deviceID: device)
            }
    }

    /// A board plus its memberships, so the two cannot arrive separately.
    func boardPayload(for id: UUID) throws -> Data? {
        let rows = try db.query("""
            SELECT id, name, color, sort_order, updated_at, deleted_at, device_id
            FROM pinboards WHERE id = ?
            """, [.text(id.uuidString)])
        guard let row = rows.first else { return nil }
        var json: [String: Any] = [:]
        for (name, value) in row {
            switch value {
            case .text(let s): json[name] = s
            case .int(let n): json[name] = n
            case .blob, .null: break
            }
        }
        var members: [[String: Any]] = []
        for m in try db.query("""
            SELECT item_id, updated_at, deleted_at, device_id
            FROM item_pinboards WHERE pinboard_id = ?
            """, [.text(id.uuidString)]) {
            var entry: [String: Any] = [:]
            for (name, value) in m {
                switch value {
                case .text(let s): entry[name] = s
                case .int(let n): entry[name] = n
                case .blob, .null: break
                }
            }
            members.append(entry)
        }
        json["members"] = members
        return try JSONSerialization.data(withJSONObject: json)
    }

    func applyBoard(payload: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            return
        }
        func text(_ k: String) -> SQLValue { (json[k] as? String).map { SQLValue.text($0) } ?? .null }
        func int(_ k: String) -> SQLValue {
            (json[k] as? Int64).map { SQLValue.int($0) }
                ?? (json[k] as? Int).map { SQLValue.int(Int64($0)) } ?? .null
        }
        try db.run("""
            INSERT OR REPLACE INTO pinboards
              (id, name, color, sort_order, updated_at, deleted_at, device_id)
            VALUES (?,?,?,?,?,?,?)
            """, [.text(id.uuidString), text("name"), text("color"), int("sort_order"),
                  int("updated_at"), int("deleted_at"), text("device_id")])

        for entry in (json["members"] as? [[String: Any]] ?? []) {
            guard let itemString = entry["item_id"] as? String else { continue }
            func mText(_ k: String) -> SQLValue { (entry[k] as? String).map { SQLValue.text($0) } ?? .null }
            func mInt(_ k: String) -> SQLValue {
                (entry[k] as? Int64).map { SQLValue.int($0) }
                    ?? (entry[k] as? Int).map { SQLValue.int(Int64($0)) } ?? .null
            }
            try db.run("""
                INSERT OR REPLACE INTO item_pinboards
                  (item_id, pinboard_id, updated_at, deleted_at, device_id)
                VALUES (?,?,?,?,?)
                """, [.text(itemString), .text(id.uuidString), mInt("updated_at"),
                      mInt("deleted_at"), mText("device_id")])
        }
    }
}
