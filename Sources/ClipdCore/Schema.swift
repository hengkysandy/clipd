/// The database schema, as an ordered list of migrations.
///
/// Core owns this and never executes it. That is deliberate: it means the
/// schema, the ordering rules and the sync-readiness checks are all testable in
/// milliseconds with no database, no file and no dependency.
///
/// Rejected: a single CREATE-if-not-exists blob. It cannot express a change to
/// an existing table, so the first schema change would have needed this anyway.
public struct Migration: Equatable, Sendable {
    public let version: Int
    public let statements: [String]

    public init(version: Int, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

public enum Schema {
    public static let migrations: [Migration] = [
        Migration(version: 1, statements: [
            """
            CREATE TABLE items (
              id            TEXT PRIMARY KEY NOT NULL,
              kind          TEXT NOT NULL,
              created_at    INTEGER NOT NULL,
              updated_at    INTEGER NOT NULL,
              deleted_at    INTEGER,
              device_id     TEXT NOT NULL,
              source_bundle TEXT,
              source_name   TEXT,
              source_url    TEXT,
              content_hash  TEXT NOT NULL,
              text_content  TEXT,
              preview       TEXT NOT NULL,
              char_count    INTEGER,
              px_width      INTEGER,
              px_height     INTEGER,
              blob_ref      TEXT,
              pinned        INTEGER NOT NULL DEFAULT 0
            )
            """,
            // Dedup looks up by hash on every single copy, so it must be indexed.
            "CREATE INDEX idx_items_hash ON items(content_hash)",
            // The panel lists newest first and skips tombstones.
            "CREATE INDEX idx_items_created ON items(deleted_at, created_at DESC)",

            """
            CREATE TABLE pinboards (
              id         TEXT PRIMARY KEY NOT NULL,
              name       TEXT NOT NULL,
              color      TEXT NOT NULL,
              sort_order INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted_at INTEGER,
              device_id  TEXT NOT NULL
            )
            """,

            // A real table, not an array column on items. Two Macs filing the
            // same item onto two different pinboards must merge to both rather
            // than one overwriting the other.
            """
            CREATE TABLE item_pinboards (
              item_id     TEXT NOT NULL,
              pinboard_id TEXT NOT NULL,
              updated_at  INTEGER NOT NULL,
              deleted_at  INTEGER,
              device_id   TEXT NOT NULL,
              PRIMARY KEY (item_id, pinboard_id)
            )
            """,
            "CREATE INDEX idx_item_pinboards_board ON item_pinboards(pinboard_id, deleted_at)",

            // Standalone, NOT external content. See migration 2 for why.
            """
            CREATE VIRTUAL TABLE items_fts USING fts5(text_content, preview)
            """,
        ]),

        Migration(version: 2, statements: [
            // Rebuild the search index as a standalone table.
            //
            // Version 1 declared it with content='items', which is FTS5's
            // external content mode. In that mode you must never INSERT or
            // DELETE the index directly; you use the special 'delete' command
            // with the original column values, or triggers. Doing it directly
            // corrupts the index, and SQLite then reports "database disk image
            // is malformed" on the next write.
            //
            // Measured: a sync test hit exactly that. A standalone table costs
            // a second copy of the text, which the original comment rejected on
            // size grounds. That reasoning was wrong twice over: the copy lives
            // inside the SQLCipher database so it is not plaintext, images are
            // not indexed at all, and correctness beats a few hundred kilobytes.
            //
            // This migration also repairs any database already corrupted by the
            // version 1 index.
            "DROP TABLE IF EXISTS items_fts",
            "CREATE VIRTUAL TABLE items_fts USING fts5(text_content, preview)",
            """
            INSERT INTO items_fts(rowid, text_content, preview)
            SELECT rowid, text_content, preview FROM items WHERE deleted_at IS NULL
            """,
        ]),
    ]

    public static var latestVersion: Int {
        migrations.map(\.version).max() ?? 0
    }

    /// What still needs running, given the version already applied.
    public static func migrations(after version: Int) -> [Migration] {
        migrations.filter { $0.version > version }
    }
}
