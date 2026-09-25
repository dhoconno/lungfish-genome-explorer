-- Empty Lungfish project store (.project.db), schema version 1.
--
-- Mirrors ProjectStore.createTables() and setSchemaVersion() in
-- Sources/LungfishCore/Storage/ProjectStore.swift. The CLI has no command
-- that creates a project store, so build-demo-project.py writes this schema
-- with sqlite3 to make a store that ProjectFile.open accepts. Keep this file
-- in step with createTables() if the schema version changes.
PRAGMA foreign_keys = ON;
BEGIN;
CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        original_content BLOB NOT NULL,
        content_hash TEXT NOT NULL,
        alphabet TEXT NOT NULL DEFAULT 'dna',
        length INTEGER NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        modified_at TEXT NOT NULL DEFAULT (datetime('now')),
        metadata TEXT
    );
CREATE TABLE IF NOT EXISTS versions (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
        version_number INTEGER NOT NULL,
        parent_hash TEXT,
        content_hash TEXT NOT NULL,
        diff_data BLOB NOT NULL,
        message TEXT,
        author TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        metadata TEXT,
        UNIQUE(sequence_id, version_number),
        UNIQUE(sequence_id, content_hash)
    );
CREATE INDEX IF NOT EXISTS idx_versions_sequence
    ON versions(sequence_id, version_number ASC);
CREATE INDEX IF NOT EXISTS idx_versions_parent
    ON versions(parent_hash);
CREATE TABLE IF NOT EXISTS annotations (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
        type TEXT NOT NULL,
        name TEXT NOT NULL,
        start_position INTEGER NOT NULL,
        end_position INTEGER NOT NULL,
        strand TEXT DEFAULT '+',
        qualifiers TEXT,
        color TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        modified_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
CREATE INDEX IF NOT EXISTS idx_annotations_sequence
    ON annotations(sequence_id, start_position);
CREATE TABLE IF NOT EXISTS current_state (
        sequence_id TEXT PRIMARY KEY REFERENCES sequences(id) ON DELETE CASCADE,
        version_hash TEXT,
        version_index INTEGER NOT NULL DEFAULT 0
    );
CREATE TABLE IF NOT EXISTS project_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
CREATE TABLE IF NOT EXISTS edit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
        operation TEXT NOT NULL,
        position INTEGER,
        length INTEGER,
        bases TEXT,
        timestamp TEXT NOT NULL DEFAULT (datetime('now')),
        session_id TEXT
    );
PRAGMA user_version = 1;
COMMIT;
PRAGMA journal_mode = WAL;
