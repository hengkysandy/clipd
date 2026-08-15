import Foundation
import ClipdCore

/// Why a sync payload could not be read.
///
/// Two cases on purpose, because the caller should treat them differently.
/// `newerVersion` means the other Mac is ahead of this one and the right log
/// line is "payload written by a newer version of Clipd, update this Mac".
/// `malformed` means the bytes are damaged and retrying will not help.
/// Rejected: one generic error, which would have left the sync log unable to
/// tell a stale install apart from a corrupt object in the bucket.
enum PayloadFormatError: Error, Equatable {
    /// The payload carried the magic but a version byte this build does not know.
    case newerVersion(UInt8)
    /// Empty, truncated, or not a Clipd payload at all. The string is a fixed
    /// reason for the log. It never contains payload content.
    case malformed(String)
}

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
            SELECT \(Self.itemColumns)
            FROM items
            WHERE deleted_at IS NULL
            ORDER BY created_at DESC
            LIMIT ?
            """, [.int(Int64(limit))])

        return items(from: rows)
    }

    /// The columns every item query must select, so the row mapper always finds
    /// what it needs. One constant rather than the same list typed twice,
    /// because a column added in one place and missed in the other would show
    /// up as items silently disappearing from search only.
    private static let itemColumns = """
        id, kind, created_at, source_bundle, source_name, source_url,
        content_hash, text_content, preview, px_width, px_height, blob_ref
        """

    /// Rows to items. Shared by `loadAll` and `search` on purpose: an item found
    /// by search must come back with the same image, preview and source app as
    /// the same item shown in the list.
    private func items(from rows: [[String: SQLValue]]) -> [HistoryItem] {
        rows.compactMap { row -> HistoryItem? in
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

    // MARK: - Search

    /// Full text search over the WHOLE history, newest first, tombstones out.
    ///
    /// Why this exists: the panel filtered the newest 500 rows it happened to
    /// be holding in memory. With retention set to six months or a year a user
    /// has far more items than that, and everything older was simply not
    /// findable. The FTS5 index is already written on every insert and every
    /// delete, so nothing here costs anything that was not already being paid.
    ///
    /// Newest first, never by relevance. A clipboard history is a timeline, and
    /// ranking buries the thing you copied 30 seconds ago under an older but
    /// better scoring match. This is the same rule `History.search` follows.
    ///
    /// Returns an empty array, and never throws, when the index cannot answer.
    /// See the catch below for why.
    func search(_ query: String, limit: Int) throws -> [HistoryItem] {
        let phrases = Self.matchPhrases(for: query)
        // Nothing searchable was typed, so nothing matches. Rejected: returning
        // the whole history, which is what `History.search` does for an empty
        // query. It is right there because the panel calls it with an empty
        // field to mean "no filter". Here it would be wrong: a query of ":::"
        // is a filter the user typed, and answering it with every item they
        // ever copied looks like search quietly gave up.
        guard !phrases.isEmpty else { return [] }
        // A space between two phrases already means AND in FTS5. Writing AND
        // out is the same query and does not rely on that default.
        let match = phrases.joined(separator: " AND ")

        let rows: [[String: SQLValue]]
        do {
            // The index only narrows the rowids. Every value shown to the user
            // still comes from `items`, so a stale index entry can at worst let
            // a row through or hold one back. It can never put wrong text on a
            // card. Rejected: selecting the text out of `items_fts` itself,
            // which would show whatever the index happened to hold.
            //
            // `rowid IN (subquery)` rather than a join, because FTS5 only
            // accepts MATCH against the table name, not against an alias, and
            // the unaliased join form reads worse for no gain.
            rows = try db.query("""
                SELECT \(Self.itemColumns)
                FROM items
                WHERE rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)
                  AND deleted_at IS NULL
                ORDER BY created_at DESC
                LIMIT ?
                """, [.text(match), .int(Int64(limit))])
        } catch {
            // A damaged or out of date index must not take the panel down. This
            // project has already seen SQLite report "database disk image is
            // malformed" from an FTS5 misuse, and that happened on a keystroke
            // path: the user is typing, and every character runs this again.
            // An empty result list is a bad search. A thrown error mid-typing
            // is a broken app.
            //
            // The SQLite message is deliberately NOT logged. FTS5 syntax errors
            // quote the offending text back at you, and that text is whatever
            // the user pasted into the search field. The count of phrases is
            // enough to tell a syntax problem from a corrupt index.
            Diag.panel.error("search failed, returning no results, phrases \(phrases.count, privacy: .public)")
            return []
        }
        return items(from: rows)
    }

    /// Turns raw text typed by a user into a list of FTS5 phrases, one per
    /// token. Empty when nothing searchable is left.
    ///
    /// This is the part that has to be right. MATCH takes a query language, not
    /// a search string. A double quote, `*`, `-`, `^`, `:`, a bracket, or the
    /// bare words AND, OR, NOT and NEAR all mean something inside it. Clipboard
    /// text is full of those, so a query pasted from a shell command would
    /// either throw a syntax error or quietly search for something the user
    /// never asked for.
    ///
    /// So every token is wrapped as an FTS5 string literal. Inside a literal
    /// the double quote is the only special character, and doubling it escapes
    /// it. Everything else is handed to the tokeniser as plain text. The
    /// expression itself is then bound as a parameter, like every other
    /// statement in this file. Raw user text never reaches the SQL.
    ///
    /// The `*` sits OUTSIDE the closing quote on purpose. There it is the
    /// prefix operator, so typing "doc" finds "docker", the way the old
    /// in-memory substring scan did. Inside the quotes it would be a literal
    /// asterisk, which the tokeniser drops, and prefix matching would be lost.
    ///
    /// Rejected: stripping the special characters out of each token. That
    /// rewrites the query behind the user's back ("a-b" becomes "ab") and still
    /// leaves a bare AND or NEAR working as an operator.
    ///
    /// A token with no letter and no digit is dropped. The tokeniser produces
    /// no terms from one, and an empty phrase ANDed with the rest matches
    /// nothing at all, so keeping it would turn "docker :" into a search that
    /// can never hit anything.
    private static func matchPhrases(for query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .filter { token in token.contains(where: { $0.isLetter || $0.isNumber }) }
            .map { token in
                "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
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
    /// Moves an item back to the top of the history.
    ///
    /// `created_at` is the position in the timeline, so it takes the given date.
    /// `updated_at` is when this device changed the row, so it is always now,
    /// and the two are deliberately not the same value. Rejected: writing the
    /// given date into both, which is what this did. Dedup touches a survivor
    /// with a timestamp that is often OLDER than the row the other Mac holds, so
    /// the change lost the last writer wins comparison and never travelled. The
    /// far Mac then kept the item at its old position, where a retention sweep
    /// could expire something the near Mac had just refreshed.
    func touch(id: UUID, at date: Date) throws {
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE items SET created_at = ?, updated_at = ? WHERE id = ?",
                   [.int(millis), .int(now), .text(id.uuidString)])
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

    // MARK: - Payload format

    /// The four bytes every v2 and later payload starts with. ASCII "CLPD".
    static let payloadMagic = Data([0x43, 0x4C, 0x50, 0x44])

    /// The newest version this build can READ. Readers accept this and below.
    static let currentPayloadVersion: UInt8 = 2

    /// Whether this build WRITES the framed v2 format. Deliberately false.
    ///
    /// A format change has to ship in two steps: readers first, writers later.
    /// This build reads v0, v1 and v2, and keeps writing v1, so a Mac still on
    /// 0.3.0 can read everything this one uploads.
    ///
    /// This is not caution for its own sake. It was checked against the real
    /// 0.3.0 parser: it reads the "CLPD" magic as a 4 byte length, gets about
    /// 1.07 GB, fails its own bounds check and RETURNS. No throw, no log, no
    /// crash. Every item written by a v2 writer would silently never arrive on
    /// the older Mac, while sync went on reporting success. A silent failure
    /// that looks exactly like a working sync is the worst shape a bug can have.
    ///
    /// Flip this to true once both Macs have run a build with the v2 reader for
    /// long enough to be sure neither will be rolled back. It is a one line
    /// change and every v2 test already covers the reader.
    static let writesFramedPayload = false

    /// Reads any of the three payload shapes and returns the JSON metadata plus
    /// the raw image bytes, if the payload carried any.
    ///
    /// The three shapes are:
    ///
    ///   v0  raw JSON, image base64 encoded inside it under "blob_data"
    ///   v1  4 byte big endian JSON length, the JSON, then the raw image bytes
    ///   v2  magic "CLPD", a version byte, then the v1 framing
    ///
    /// Why the check below cannot confuse them:
    ///
    /// A v0 payload starts with `{`, byte 0x7B, because `JSONSerialization`
    /// writes an object with no leading whitespace and no byte order mark. No
    /// framed payload can start with 0x7B: v1 starts with the high byte of a
    /// length, and the JSON metadata is a few hundred bytes, so that high byte
    /// is 0. v2 starts with `C`, byte 0x43. So byte 0 alone separates v0 from
    /// the rest.
    ///
    /// The trap is v1 against v2, because a v1 length is four free bytes and
    /// could in principle spell "CLPD". That would mean a JSON metadata block of
    /// 0x434C5044 bytes, about 1.07 GB. The metadata holds only row fields, never
    /// the image, so it cannot get near that. Even so, "cannot in practice" is a
    /// weak rule to write a parser on, so the check does not rely on it. It also
    /// looks at byte 4. In v1 byte 4 is the first byte of the JSON, always `{`.
    /// In v2 byte 4 is the version byte. As long as no version number is ever
    /// 0x7B, that is 123, the pair (magic, byte 4) tells v1 and v2 apart exactly,
    /// with no appeal to how big a length is likely to be. Version 123 is
    /// therefore reserved and must never be used.
    ///
    /// Rejected: sniffing for valid JSON by trying to parse and falling back on
    /// failure. That turns every corrupt payload into a slow guess, and a v1
    /// payload whose image bytes happen to parse as JSON would be read wrong.
    private static func split(payload: Data) throws -> (meta: Data, image: Data?) {
        // Data slices keep the indices of the parent, so every offset below is
        // written relative to startIndex. Assuming 0 is a real index is the
        // classic way to crash on a sliced Data.
        let start = payload.startIndex
        guard !payload.isEmpty else {
            throw PayloadFormatError.malformed("payload is empty")
        }

        if payload[start] == 0x7B {
            // v0. The whole payload is the JSON, image included as base64.
            return (payload, nil)
        }

        // Both framed formats need at least a 4 byte prefix and one more byte
        // to disambiguate, so anything shorter is not a payload at all.
        guard payload.count >= 5 else {
            throw PayloadFormatError.malformed("payload is too short to be framed")
        }

        if payload.subdata(in: start ..< start + 4) == payloadMagic, payload[start + 4] != 0x7B {
            let version = payload[start + 4]
            guard version <= currentPayloadVersion else {
                throw PayloadFormatError.newerVersion(version)
            }
            // v0 and v1 never carried the magic, so a version below 2 here means
            // a corrupt payload rather than an older one.
            guard version == currentPayloadVersion else {
                throw PayloadFormatError.malformed("framed payload claims an impossible version")
            }
            return try frame(payload, jsonStartsAt: 9, lengthAt: 5)
        }

        // v1. Byte 4 must be `{` or this is not a payload we know.
        guard payload[start + 4] == 0x7B else {
            throw PayloadFormatError.malformed("payload matches no known format")
        }
        return try frame(payload, jsonStartsAt: 4, lengthAt: 0)
    }

    /// The shared tail of v1 and v2: a big endian length, the JSON, then the rest.
    private static func frame(_ payload: Data,
                              jsonStartsAt jsonOffset: Int,
                              lengthAt lengthOffset: Int) throws -> (meta: Data, image: Data?) {
        let start = payload.startIndex
        guard payload.count >= lengthOffset + 4 else {
            throw PayloadFormatError.malformed("payload ends inside its length field")
        }
        let lengthBytes = payload.subdata(in: (start + lengthOffset) ..< (start + lengthOffset + 4))
        let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        // A length that runs past the end means a truncated or corrupt payload.
        // Throw rather than slice out of bounds, which would crash the sync pass.
        guard payload.count >= jsonOffset + length else {
            throw PayloadFormatError.malformed("declared metadata length runs past the end")
        }
        let meta = payload.subdata(in: (start + jsonOffset) ..< (start + jsonOffset + length))
        let rest = payload.subdata(in: (start + jsonOffset + length) ..< payload.endIndex)
        return (meta, rest.isEmpty ? nil : rest)
    }

    /// The full row, ready to be encrypted and uploaded.
    ///
    /// Payload format v2. The byte layout is:
    ///
    ///     offset 0   4 bytes   magic "CLPD"
    ///     offset 4   1 byte    format version, currently 2
    ///     offset 5   4 bytes   JSON metadata length, big endian UInt32
    ///     offset 9   N bytes   the JSON metadata
    ///     offset 9+N rest      the raw image bytes, or nothing for a text item
    ///
    /// The magic and the version byte are the point of v2. The older formats had
    /// no version field, so a reader had to guess the shape from the first byte.
    /// Guessing does not extend to a third format and gives a receiver no way to
    /// say "this was written by a newer Clipd than me". Rejected: a JSON envelope
    /// with a "version" key wrapping the rest, which would put the image bytes
    /// back inside JSON and undo the whole reason v1 existed.
    ///
    /// Rejected for the image bytes: base64 inside the JSON, which is what v1
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
        // v1 framing today, v2 framing when the flag flips. See
        // `writesFramedPayload` for why this build still writes the old shape.
        if Self.writesFramedPayload {
            out.append(Self.payloadMagic)
            out.append(Self.currentPayloadVersion)
        }
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
    /// Reads all three payload formats on purpose. The user has two Macs and they
    /// will sit on different app versions for a while. A payload this build cannot
    /// read is an item that silently never arrives, so the older readers stay until
    /// both ends are known to be new.
    func apply(payload: Data) throws {
        let parsed = try Self.split(payload: payload)
        let meta = parsed.meta
        var imageData = parsed.image

        guard let json = try JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let idString = json["id"] as? String, let id = UUID(uuidString: idString) else {
            throw PayloadFormatError.malformed("metadata is not a JSON object with an id")
        }
        // Only v0 puts the image in the JSON.
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
