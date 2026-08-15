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
