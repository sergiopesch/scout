import CSQLite
import Foundation

enum SQLiteMigrations {
    static let currentVersion: Int64 = 1

    static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("BEGIN EXCLUSIVE")
        do {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS scout_schema_migrations (
                    version INTEGER PRIMARY KEY NOT NULL CHECK(version > 0),
                    applied_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID
                """
            )
            let existing = try database.querySingleInt(
                "SELECT MAX(version) FROM scout_schema_migrations"
            ) ?? 0
            let migrationCount = try database.querySingleInt(
                "SELECT COUNT(*) FROM scout_schema_migrations"
            ) ?? 0
            guard migrationCount == existing else {
                throw SQLiteEventStoreError.corruptEvent(
                    eventID: nil,
                    reason: "database migration history is not contiguous"
                )
            }
            guard existing <= currentVersion else {
                throw SQLiteEventStoreError.corruptEvent(
                    eventID: nil,
                    reason: "database schema version \(existing) is newer than supported \(currentVersion)"
                )
            }
            if existing < 1 {
                try applyVersionOne(database)
                let statement = try database.prepare(
                    "INSERT INTO scout_schema_migrations(version, applied_at_ms) VALUES(1, ?)"
                )
                defer { database.finalize(statement) }
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                try database.bind(now, to: 1, in: statement)
                _ = try database.step(statement)
            }
            // Reassert invariant triggers on every open. This repairs an
            // accidentally dropped trigger before the connection is exposed.
            try ensureAppendOnlyTriggers(database)
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private static func applyVersionOne(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE scout_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL,
                sequence INTEGER NOT NULL CHECK(sequence > 0),
                schema_major INTEGER NOT NULL CHECK(schema_major >= 0),
                schema_minor INTEGER NOT NULL CHECK(schema_minor >= 0),
                occurred_at_ms INTEGER NOT NULL,
                recorded_at_ms INTEGER NOT NULL,
                event_kind TEXT NOT NULL,
                previous_hash TEXT,
                integrity_hash TEXT NOT NULL,
                envelope BLOB NOT NULL,
                encoded_envelope BLOB NOT NULL,
                inserted_at_ms INTEGER NOT NULL,
                UNIQUE(session_id, sequence)
            );

            CREATE INDEX scout_events_session_sequence
                ON scout_events(session_id, sequence);

            CREATE TABLE scout_append_operations (
                idempotency_key TEXT PRIMARY KEY NOT NULL,
                request_hash TEXT NOT NULL,
                event_count INTEGER NOT NULL CHECK(event_count > 0),
                committed_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE scout_append_operation_events (
                idempotency_key TEXT NOT NULL,
                ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                event_id TEXT NOT NULL,
                PRIMARY KEY(idempotency_key, ordinal),
                UNIQUE(idempotency_key, event_id),
                FOREIGN KEY(idempotency_key)
                    REFERENCES scout_append_operations(idempotency_key)
                    ON UPDATE RESTRICT ON DELETE RESTRICT,
                FOREIGN KEY(event_id)
                    REFERENCES scout_events(event_id)
                    ON UPDATE RESTRICT ON DELETE RESTRICT
            ) WITHOUT ROWID;

            CREATE TRIGGER scout_migrations_reject_update
            BEFORE UPDATE ON scout_schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'scout_schema_migrations is append-only');
            END;

            CREATE TRIGGER scout_migrations_reject_delete
            BEFORE DELETE ON scout_schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'scout_schema_migrations is append-only');
            END
            """
        )
    }

    private static func ensureAppendOnlyTriggers(_ database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TRIGGER IF NOT EXISTS scout_events_reject_update
            BEFORE UPDATE ON scout_events
            BEGIN
                SELECT RAISE(ABORT, 'scout_events is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_events_reject_delete
            BEFORE DELETE ON scout_events
            BEGIN
                SELECT RAISE(ABORT, 'scout_events is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_operations_reject_update
            BEFORE UPDATE ON scout_append_operations
            BEGIN
                SELECT RAISE(ABORT, 'scout_append_operations is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_operations_reject_delete
            BEFORE DELETE ON scout_append_operations
            BEGIN
                SELECT RAISE(ABORT, 'scout_append_operations is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_operation_events_reject_update
            BEFORE UPDATE ON scout_append_operation_events
            BEGIN
                SELECT RAISE(ABORT, 'scout_append_operation_events is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_operation_events_reject_delete
            BEFORE DELETE ON scout_append_operation_events
            BEGIN
                SELECT RAISE(ABORT, 'scout_append_operation_events is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_migrations_reject_update
            BEFORE UPDATE ON scout_schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'scout_schema_migrations is append-only');
            END;

            CREATE TRIGGER IF NOT EXISTS scout_migrations_reject_delete
            BEFORE DELETE ON scout_schema_migrations
            BEGIN
                SELECT RAISE(ABORT, 'scout_schema_migrations is append-only');
            END
            """
        )
    }
}
