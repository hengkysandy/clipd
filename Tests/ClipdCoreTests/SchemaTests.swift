import Testing
@testable import ClipdCore

@Test("Migrations are numbered from 1 with no gaps and no repeats")
func migrationsAreWellOrdered() {
    let versions = Schema.migrations.map(\.version)
    #expect(versions == Array(1...versions.count))
}

@Test("Every migration carries at least one statement")
func migrationsAreNotEmpty() {
    for migration in Schema.migrations {
        #expect(!migration.statements.isEmpty)
    }
}

@Test("latestVersion matches the highest migration")
func latestVersionIsConsistent() {
    #expect(Schema.latestVersion == Schema.migrations.map(\.version).max())
}

@Test("A fresh database runs every migration")
func freshDatabaseRunsEverything() {
    #expect(Schema.migrations(after: 0).count == Schema.migrations.count)
}

@Test("An up to date database runs none")
func upToDateRunsNothing() {
    #expect(Schema.migrations(after: Schema.latestVersion).isEmpty)
}

@Test("A partly migrated database runs only what it is missing")
func partialMigration() {
    let pending = Schema.migrations(after: 1)
    #expect(pending.allSatisfy { $0.version > 1 })
    #expect(pending.count == Schema.migrations.count - 1)
}

@Test("A version from the future runs nothing rather than crashing")
func futureVersionIsSafe() {
    // Degenerate case: the user downgraded the app. Running nothing is wrong
    // but survivable; crashing on launch is not.
    #expect(Schema.migrations(after: 999).isEmpty)
}

@Test("Every table carries the four sync columns")
func everyTableIsSyncReady() {
    // Sync ships in v1.1 and must need no migration. If a table is added
    // later without these, that promise is quietly broken.
    let sql = Schema.migrations.flatMap(\.statements).joined(separator: "\n")
    for table in ["items", "pinboards", "item_pinboards"] {
        let create = sql
            .split(separator: ";")
            .first { $0.contains("CREATE TABLE \(table)") }
        #expect(create != nil, "no CREATE TABLE for \(table)")
        guard let create else { continue }
        for column in ["updated_at", "deleted_at", "device_id"] {
            #expect(create.contains(column), "\(table) is missing \(column)")
        }
    }
}

@Test("The FTS5 table exists, because search depends on it")
func hasFullTextSearch() {
    let sql = Schema.migrations.flatMap(\.statements).joined(separator: "\n")
    #expect(sql.contains("USING fts5"))
}

// MARK: - Migration 3, item titles

/// The migration under test, or a failure with a useful message.
private func migrationThree() throws -> Migration {
    try #require(Schema.migrations.first { $0.version == 3 },
                 "migration 3 is missing, so no database would ever grow a title column")
}

@Test("Migration 3 adds the title column to items")
func migrationThreeAddsTheTitleColumn() throws {
    let three = try migrationThree()
    #expect(three.statements.contains { $0.contains("ALTER TABLE items ADD COLUMN title TEXT") })
}

@Test("Migration 3 rebuilds the search index with three columns")
func migrationThreeRebuildsTheIndexWithTitle() throws {
    let three = try migrationThree()
    // FTS5 has no ALTER TABLE ADD COLUMN, so indexing the title means dropping
    // the table and creating it again. If this ever turns into an ALTER, the
    // migration will fail on a real database rather than here.
    #expect(three.statements.contains { $0.contains("DROP TABLE IF EXISTS items_fts") })
    let create = three.statements.first { $0.contains("CREATE VIRTUAL TABLE items_fts") }
    #expect(create?.contains("fts5(text_content, preview, title)") == true,
            "the rebuilt index must carry all three columns, or titles are not searchable")
}

@Test("Migration 3 repopulates the index from every live row")
func migrationThreeRepopulatesLiveRowsOnly() throws {
    let three = try migrationThree()
    let fill = try #require(three.statements.first { $0.contains("INSERT INTO items_fts") })
    // The rebuild runs on databases already holding months of real history on
    // two Macs. An index that comes out empty means every one of those items is
    // silently unfindable, with nothing on screen to say so.
    #expect(fill.contains("FROM items"))
    #expect(fill.contains("SELECT rowid, text_content, preview, title"))
    // Tombstones are kept in `items` so a sync cannot resurrect them, and they
    // must stay out of the index. Migration 2 already draws this line and this
    // one has to draw it in the same place.
    #expect(fill.contains("deleted_at IS NULL"))
}

@Test("Migration 3 drops, creates and only then fills the index")
func migrationThreeOrdersItsStatements() throws {
    let three = try migrationThree()
    let drop = try #require(three.statements.firstIndex { $0.contains("DROP TABLE IF EXISTS items_fts") })
    let create = try #require(three.statements.firstIndex { $0.contains("CREATE VIRTUAL TABLE items_fts") })
    let fill = try #require(three.statements.firstIndex { $0.contains("INSERT INTO items_fts") })
    let alter = try #require(three.statements.firstIndex { $0.contains("ADD COLUMN title") })
    #expect(drop < create)
    #expect(create < fill)
    // The column has to exist before the SELECT that reads it, or the whole
    // migration rolls back and the app cannot open its own database.
    #expect(alter < fill)
}

@Test("Migration 2 is left alone, so a database already on version 2 is not rebuilt twice")
func migrationTwoIsUnchanged() throws {
    let two = try #require(Schema.migrations.first { $0.version == 2 })
    // Version 2 must keep describing the two column index it actually created.
    // Editing an already applied migration changes nothing on the Macs that ran
    // it and only makes this file lie about what is on disk.
    #expect(two.statements.contains { $0.contains("fts5(text_content, preview)") })
    #expect(!two.statements.contains { $0.contains("title") })
}
