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

            // External content: the index stores no copy of the text, it points
            // at items. Rejected: a standalone fts5 table, which would hold a
            // second plaintext copy of everything and double the database.
            """
            CREATE VIRTUAL TABLE items_fts USING fts5(
              text_content, preview,
              content='items', content_rowid='rowid'
            )
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
