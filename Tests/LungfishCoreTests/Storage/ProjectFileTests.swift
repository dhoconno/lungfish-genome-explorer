// ProjectFileTests.swift - Tests for Lungfish project file format
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishCore

@MainActor
final class ProjectFileTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testRejectedMissingMetadataLeavesProjectUnchanged() throws {
        let url = tempDirectory.appendingPathComponent("Missing.lungfish")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("invented payload".utf8).write(to: url.appendingPathComponent("sample.txt"))
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testRejectedFutureFormatLeavesProjectUnchanged() throws {
        let url = tempDirectory.appendingPathComponent("Future.lungfish")
        _ = try ProjectFile.create(at: url, name: "Future")
        let metadataURL = url.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["formatVersion"] = "999.0"
        metadata["futureField"] = "preserve me"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertThrowsError(try ProjectFile.open(at: url, access: .readOnly))
        XCTAssertThrowsError(try ProjectFile.migrate(at: url))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testRejectedFutureSchemaLeavesProjectUnchanged() throws {
        let url = tempDirectory.appendingPathComponent("FutureSchema.lungfish")
        _ = try ProjectFile.create(at: url, name: "Future schema")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.appendingPathComponent(".project.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 999", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertThrowsError(try ProjectFile.open(at: url, access: .readOnly))
        XCTAssertThrowsError(try ProjectFile.migrate(at: url))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testRejectedCorruptWriterLockLeavesProjectUnchanged() throws {
        let url = tempDirectory.appendingPathComponent("Locked.lungfish")
        _ = try ProjectFile.create(at: url, name: "Locked")
        let lockURL = ProjectLockManager.lockURL(for: url)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid lock".utf8).write(to: lockURL)
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testReadOnlyOpenAndRejectedMutationsLeaveAllProjectBytesUnchanged() throws {
        let url = tempDirectory.appendingPathComponent("ReadOnly.lungfish")
        _ = try ProjectFile.create(at: url, name: "Read only")
        let before = try projectSnapshot(url)
        do {
            let project = try ProjectFile.open(at: url, access: .readOnly)
            XCTAssertEqual(project.accessMode, .readOnly)
            XCTAssertTrue(try project.listSequences().isEmpty)
            XCTAssertThrowsError(try project.save())
            XCTAssertThrowsError(try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT")))
        }
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testReadOnlyOpenIncludesCommittedWALWithoutChangingSource() throws {
        let url = tempDirectory.appendingPathComponent("LiveWAL.lungfish")
        let writer = try ProjectFile.create(at: url, name: "Live WAL")
        try writer.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT"))
        let before = try projectSnapshot(url)
        do {
            let reader = try ProjectFile.open(at: url, access: .readOnly)
            XCTAssertEqual(try reader.listSequences().map(\.name), ["invented"])
        }
        XCTAssertEqual(try projectSnapshot(url), before)
        withExtendedLifetime(writer) {}
    }

    func testExplicitMigrationRejectsReadOnlyAndCorruptLockWithoutMutation() throws {
        let url = tempDirectory.appendingPathComponent("MigrationLock.lungfish")
        _ = try ProjectFile.create(at: url, name: "Migration lock")
        let lockURL = ProjectLockManager.lockURL(for: url)
        try Data("invalid lock".utf8).write(to: lockURL)
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.migrate(at: url, access: .readOnly))
        XCTAssertThrowsError(try ProjectFile.migrate(at: url))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testOlderSchemaRequiresExplicitRecoverableMigration() throws {
        let url = tempDirectory.appendingPathComponent("OldSchema.lungfish")
        _ = try ProjectFile.create(at: url, name: "Old schema")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.appendingPathComponent(".project.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertThrowsError(try ProjectFile.open(at: url, access: .readOnly))
        XCTAssertEqual(try projectSnapshot(url), before)
        try ProjectFile.migrate(at: url)
        let opened = try ProjectFile.open(at: url, access: .readOnly)
        XCTAssertEqual(opened.name, "Old schema")
        let recoveryRoot = url.appendingPathComponent(".lungfish/migrations")
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("source.db")), before[".project.db"])
    }

    func testCreateCannotOverwriteExistingProject() throws {
        let url = tempDirectory.appendingPathComponent("Existing.lungfish")
        _ = try ProjectFile.create(at: url, name: "Existing")
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.create(at: url, name: "Replacement"))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testMissingDatabaseIsNeverCreatedByOpen() throws {
        let url = tempDirectory.appendingPathComponent("MissingDatabase.lungfish")
        _ = try ProjectFile.create(at: url, name: "Missing database")
        try FileManager.default.removeItem(at: url.appendingPathComponent(".project.db"))
        let before = try projectSnapshot(url)
        XCTAssertThrowsError(try ProjectFile.open(at: url))
        XCTAssertThrowsError(try ProjectFile.open(at: url, access: .readOnly))
        XCTAssertEqual(try projectSnapshot(url), before)
    }

    func testSharedWriterLeaseSurvivesClosingOneProjectHandle() throws {
        let url = tempDirectory.appendingPathComponent("SharedWriter.lungfish")
        var first: ProjectFile? = try ProjectFile.create(at: url, name: "Shared")
        XCTAssertNotNil(first)
        var second: ProjectFile? = try ProjectFile.open(at: url)
        first = nil
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: url))
        try second?.save()
        second = nil
        XCTAssertFalse(ProjectStore.ownsWriterLease(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: url).path))
    }

    private func projectSnapshot(_ url: URL) throws -> [String: Data] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: url.path)
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            let item = url.appendingPathComponent(path)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            return (path, values.isDirectory == true ? Data() : try Data(contentsOf: item))
        })
    }

    // MARK: - Project Creation Tests

    func testCreateProject() throws {
        let projectURL = tempDirectory.appendingPathComponent("TestProject")
        let project = try ProjectFile.create(
            at: projectURL,
            name: "Test Project",
            description: "A test project",
            author: "Test Author"
        )

        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.description, "A test project")
        XCTAssertEqual(project.author, "Test Author")
        XCTAssertFalse(project.isDirty)

        // Verify directory structure
        let projectDir = projectURL.appendingPathExtension("lungfish")
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectDir.appendingPathComponent(".project.db").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectDir.appendingPathComponent("metadata.json").path
        ))
    }

    func testOpenProject() throws {
        // Create a project
        let projectURL = tempDirectory.appendingPathComponent("OpenTest.lungfish")
        let original = try ProjectFile.create(
            at: projectURL,
            name: "Open Test",
            description: "Test opening",
            author: "Tester"
        )

        // Add a sequence
        let sequence = try Sequence(
            name: "test_seq",
            alphabet: .dna,
            bases: "ATCGATCGATCG"
        )
        try original.addSequence(sequence)
        try original.save()

        // Open the project
        let opened = try ProjectFile.open(at: projectURL)

        XCTAssertEqual(opened.name, "Open Test")
        XCTAssertEqual(opened.description, "Test opening")
        XCTAssertEqual(opened.author, "Tester")

        // Verify sequence was persisted
        let sequences = try opened.listSequences()
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "test_seq")
    }

    // MARK: - Sequence Operations Tests

    func testAddSequence() throws {
        let projectURL = tempDirectory.appendingPathComponent("SeqTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Sequence Test")

        let sequence = try Sequence(
            name: "my_sequence",
            alphabet: .dna,
            bases: "ATCGATCGATCG"
        )
        let sequenceId = try project.addSequence(sequence)

        XCTAssertNotNil(sequenceId)
        XCTAssertTrue(project.isDirty)

        let sequences = try project.listSequences()
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "my_sequence")
        XCTAssertEqual(sequences[0].length, 12)
    }

    func testAddSequenceWithHistory() throws {
        let projectURL = tempDirectory.appendingPathComponent("HistoryTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "History Test")

        // Create a sequence with version history
        let originalContent = "AAAA"
        let sequence = try Sequence(
            name: "versioned_seq",
            alphabet: .dna,
            bases: originalContent
        )

        let history = VersionHistory(
            originalSequence: originalContent,
            sequenceName: "versioned_seq"
        )
        try history.commit(newSequence: "AABB", message: "Change 1")
        try history.commit(newSequence: "AABBCC", message: "Change 2")

        let sequenceId = try project.addSequence(sequence, withHistory: history)

        // Verify history was preserved
        let versions = try project.getVersionHistory(for: sequenceId)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].message, "Change 1")
        XCTAssertEqual(versions[1].message, "Change 2")
    }

    func testAddSequenceWithHistoryUsesHistoryOriginalContentAndHashesIncrementally() throws {
        let projectURL = tempDirectory.appendingPathComponent("ImportedHistoryTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Imported History Test")

        let originalContent = "AAAA"
        let version1Content = "AABB"
        let version2Content = "AABBCC"

        let importedSequence = try Sequence(
            name: "imported_history_seq",
            alphabet: .dna,
            bases: version2Content
        )

        let history = VersionHistory(
            originalSequence: originalContent,
            sequenceName: "imported_history_seq"
        )
        try history.commit(newSequence: version1Content, message: "Change 1")
        try history.commit(newSequence: version2Content, message: "Change 2")

        let sequenceId = try project.addSequence(importedSequence, withHistory: history)

        let stored = try XCTUnwrap(project.getSequence(id: sequenceId))
        XCTAssertEqual(stored.originalContent, originalContent)
        XCTAssertEqual(stored.currentVersionIndex, history.currentVersionIndex)
        XCTAssertEqual(stored.currentVersionHash, Version.computeHash(version2Content))

        let versions = try project.getVersionHistory(for: sequenceId)
        XCTAssertEqual(versions.map(\.contentHash), [
            Version.computeHash(version1Content),
            Version.computeHash(version2Content),
        ])

        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 0), originalContent)
        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 1), version1Content)
        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 2), version2Content)

        XCTAssertThrowsError(try project.getSequenceContent(id: sequenceId, atVersion: 3)) { error in
            guard case ProjectStoreError.invalidVersionIndex(let index) = error else {
                XCTFail("Expected invalidVersionIndex, got \(error)")
                return
            }
            XCTAssertEqual(index, 3)
        }
    }

    func testGetSequenceContent() throws {
        let projectURL = tempDirectory.appendingPathComponent("ContentTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Content Test")

        let sequence = try Sequence(
            name: "content_seq",
            alphabet: .dna,
            bases: "ATCGATCG"
        )
        let sequenceId = try project.addSequence(sequence)

        let content = try project.getSequenceContent(id: sequenceId)
        XCTAssertEqual(content, "ATCGATCG")
    }

    func testRecordEdit() throws {
        let projectURL = tempDirectory.appendingPathComponent("EditTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Edit Test")

        let sequence = try Sequence(
            name: "edit_seq",
            alphabet: .dna,
            bases: "AAAA"
        )
        let sequenceId = try project.addSequence(sequence)

        // Record an edit
        let diff = SequenceDiff.compute(from: "AAAA", to: "AABB")
        try project.recordEdit(
            sequenceId: sequenceId,
            diff: diff,
            message: "Changed AA to BB"
        )

        // Verify version was recorded
        let versions = try project.getVersionHistory(for: sequenceId)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].message, "Changed AA to BB")

        // Verify content changed
        let content = try project.getSequenceContent(id: sequenceId)
        XCTAssertEqual(content, "AABB")
    }

    func testCheckoutVersion() throws {
        let projectURL = tempDirectory.appendingPathComponent("CheckoutTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Checkout Test")

        let sequence = try Sequence(
            name: "checkout_seq",
            alphabet: .dna,
            bases: "AAAA"
        )
        let sequenceId = try project.addSequence(sequence)

        // Make some edits
        let diff1 = SequenceDiff.compute(from: "AAAA", to: "BBBB")
        try project.recordEdit(sequenceId: sequenceId, diff: diff1)

        let diff2 = SequenceDiff.compute(from: "BBBB", to: "CCCC")
        try project.recordEdit(sequenceId: sequenceId, diff: diff2)

        // Checkout different versions
        try project.checkoutVersion(sequenceId: sequenceId, versionIndex: 0)
        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 0), "AAAA")

        try project.checkoutVersion(sequenceId: sequenceId, versionIndex: 1)
        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 1), "BBBB")

        try project.checkoutVersion(sequenceId: sequenceId, versionIndex: 2)
        XCTAssertEqual(try project.getSequenceContent(id: sequenceId, atVersion: 2), "CCCC")
    }

    // MARK: - Annotation Tests

    func testAddAnnotation() throws {
        let projectURL = tempDirectory.appendingPathComponent("AnnotationTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Annotation Test")

        let sequence = try Sequence(
            name: "annotated_seq",
            alphabet: .dna,
            bases: String(repeating: "ATCG", count: 100)
        )
        let sequenceId = try project.addSequence(sequence)

        let annotationId = try project.addAnnotation(
            to: sequenceId,
            type: "gene",
            name: "geneX",
            range: 10..<100,
            strand: "+",
            qualifiers: ["product": "Test protein"]
        )

        XCTAssertNotNil(annotationId)

        let annotations = try project.getAnnotations(for: sequenceId)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].name, "geneX")
        XCTAssertEqual(annotations[0].type, "gene")
    }

    // MARK: - Metadata Tests

    func testCustomMetadata() throws {
        let projectURL = tempDirectory.appendingPathComponent("MetadataTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Metadata Test")

        project.setCustomMetadata(key: "organism", value: "E. coli")
        project.setCustomMetadata(key: "strain", value: "K-12")

        XCTAssertEqual(project.getCustomMetadata(key: "organism"), "E. coli")
        XCTAssertEqual(project.getCustomMetadata(key: "strain"), "K-12")
        XCTAssertNil(project.getCustomMetadata(key: "nonexistent"))
        XCTAssertTrue(project.isDirty)
    }

    // MARK: - Edit Log Tests

    func testEditLog() throws {
        let projectURL = tempDirectory.appendingPathComponent("LogTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Log Test")

        let sequence = try Sequence(
            name: "logged_seq",
            alphabet: .dna,
            bases: "ATCG"
        )
        let sequenceId = try project.addSequence(sequence)

        try project.logEdit(
            sequenceId: sequenceId,
            operation: "insert",
            position: 2,
            bases: "GGG"
        )

        let edits = try project.getRecentEdits(sequenceId: sequenceId)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].operation, "insert")
        XCTAssertEqual(edits[0].position, 2)
        XCTAssertEqual(edits[0].bases, "GGG")
    }

    // MARK: - Persistence Tests

    func testSaveAndReload() throws {
        let projectURL = tempDirectory.appendingPathComponent("SaveTest.lungfish")

        // Create and populate project
        let project = try ProjectFile.create(
            at: projectURL,
            name: "Save Test",
            description: "Testing save/reload"
        )

        let sequence = try Sequence(
            name: "save_test_seq",
            alphabet: .dna,
            bases: "ATCGATCG"
        )
        let sequenceId = try project.addSequence(sequence)

        try project.addAnnotation(
            to: sequenceId,
            type: "CDS",
            name: "cds1",
            range: 0..<8
        )

        project.setCustomMetadata(key: "key1", value: "value1")

        try project.save()

        // Reload project
        let reloaded = try ProjectFile.open(at: projectURL)

        XCTAssertEqual(reloaded.name, "Save Test")
        XCTAssertEqual(reloaded.description, "Testing save/reload")

        let sequences = try reloaded.listSequences()
        XCTAssertEqual(sequences.count, 1)

        let annotations = try reloaded.getAnnotations(for: sequenceId)
        XCTAssertEqual(annotations.count, 1)

        XCTAssertEqual(reloaded.getCustomMetadata(key: "key1"), "value1")
    }

    func testProjectMetadataWritesAreAtomic() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/LungfishCore/Storage/ProjectFile.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("data.write(to: metadataURL, options: .atomic)"))
    }

    func testDirtyFlag() throws {
        let projectURL = tempDirectory.appendingPathComponent("DirtyTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Dirty Test")

        XCTAssertFalse(project.isDirty)

        // Add a sequence
        let sequence = try Sequence(name: "seq", alphabet: .dna, bases: "ATCG")
        try project.addSequence(sequence)

        XCTAssertTrue(project.isDirty)

        // Save
        try project.save()

        XCTAssertFalse(project.isDirty)

        // Modify again
        project.setCustomMetadata(key: "foo", value: "bar")

        XCTAssertTrue(project.isDirty)
    }
}
