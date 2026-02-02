// ProjectFileTests.swift - Tests for Lungfish project file format
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
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
            atPath: projectDir.appendingPathComponent("project.db").path
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
