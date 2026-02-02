// EndToEndTests.swift - End-to-end functionality tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishUI

/// End-to-end tests verifying core functionality across modules
@MainActor
final class EndToEndTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishE2E-\(UUID().uuidString)")
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

    // MARK: - Full Workflow: Create Project, Add Sequence, Edit, Version, Save

    func testCompleteProjectWorkflow() throws {
        // 1. Create a new project
        let projectURL = tempDirectory.appendingPathComponent("TestProject.lungfish")
        let project = try ProjectFile.create(
            at: projectURL,
            name: "E2E Test Project",
            description: "Testing full workflow",
            author: "Test Suite"
        )

        XCTAssertEqual(project.name, "E2E Test Project")
        XCTAssertFalse(project.isDirty)

        // 2. Create and add a sequence
        let sequence = try Sequence(
            name: "test_gene",
            alphabet: .dna,
            bases: "ATGCGATCGATCGATCGATCGATCGATCGATCG"
        )
        let sequenceId = try project.addSequence(sequence)
        XCTAssertTrue(project.isDirty)

        // 3. Verify sequence was stored
        let sequences = try project.listSequences()
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "test_gene")
        XCTAssertEqual(sequences[0].length, 33)

        // 4. Add an annotation
        let annotationId = try project.addAnnotation(
            to: sequenceId,
            type: "gene",
            name: "myGene",
            range: 0..<30,
            strand: "+",
            qualifiers: ["product": "test protein"]
        )
        XCTAssertNotNil(annotationId)

        // 5. Edit the sequence (simulate insertion)
        let originalContent = try project.getSequenceContent(id: sequenceId)
        let diff = SequenceDiff.compute(from: originalContent, to: "ATGCGATCGGGGATCGATCGATCGATCGATCGATCG")
        try project.recordEdit(
            sequenceId: sequenceId,
            diff: diff,
            message: "Inserted GGG at position 9"
        )

        // 6. Verify version history
        let versions = try project.getVersionHistory(for: sequenceId)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].message, "Inserted GGG at position 9")

        // 7. Verify content changed
        let newContent = try project.getSequenceContent(id: sequenceId)
        XCTAssertEqual(newContent, "ATGCGATCGGGGATCGATCGATCGATCGATCGATCG")

        // 8. Checkout original version
        try project.checkoutVersion(sequenceId: sequenceId, versionIndex: 0)
        let v0Content = try project.getSequenceContent(id: sequenceId, atVersion: 0)
        XCTAssertEqual(v0Content, "ATGCGATCGATCGATCGATCGATCGATCGATCG")

        // 9. Save the project
        try project.save()
        XCTAssertFalse(project.isDirty)

        // 10. Reopen and verify persistence
        let reopened = try ProjectFile.open(at: projectURL)
        XCTAssertEqual(reopened.name, "E2E Test Project")

        let reopenedSequences = try reopened.listSequences()
        XCTAssertEqual(reopenedSequences.count, 1)

        let reopenedVersions = try reopened.getVersionHistory(for: sequenceId)
        XCTAssertEqual(reopenedVersions.count, 1)

        let reopenedAnnotations = try reopened.getAnnotations(for: sequenceId)
        XCTAssertEqual(reopenedAnnotations.count, 1)
        XCTAssertEqual(reopenedAnnotations[0].name, "myGene")
    }

    // MARK: - FASTA File Loading

    func testFASTALoading() async throws {
        // Create a FASTA file
        let fastaContent = """
        >seq1 First sequence
        ATCGATCGATCGATCGATCG
        ATCGATCGATCGATCGATCG
        >seq2 Second sequence
        GCTAGCTAGCTAGCTAGCTA
        """
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        // Load with FASTAReader
        let reader = try FASTAReader(url: fastaURL)
        let sequences = try await reader.readAll()

        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences[0].name, "seq1")
        XCTAssertEqual(sequences[0].length, 40)
        XCTAssertEqual(sequences[1].name, "seq2")
        XCTAssertEqual(sequences[1].length, 20)
    }

    // MARK: - GenBank Parsing with Annotations

    func testGenBankParsing() async throws {
        let genbankContent = """
        LOCUS       TEST_SEQ              100 bp    DNA     linear   UNK
        DEFINITION  Test sequence for E2E testing
        ACCESSION   TEST001
        VERSION     TEST001.1
        FEATURES             Location/Qualifiers
             gene            1..30
                             /gene="testGene"
                             /product="Test protein"
             CDS             10..90
                             /gene="testGene"
                             /codon_start=1
                             /product="Test protein"
        ORIGIN
                1 atgcgatcga tcgatcgatc gatcgatcga tcgatcgatc gatcgatcga
               61 tcgatcgatc gatcgatcga tcgatcgatc gatcgatcga
        //
        """
        let gbURL = tempDirectory.appendingPathComponent("test.gb")
        try genbankContent.write(to: gbURL, atomically: true, encoding: .utf8)

        let reader = try GenBankReader(url: gbURL)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.locus.name, "TEST_SEQ")
        XCTAssertEqual(record.accession, "TEST001")
        XCTAssertEqual(record.annotations.count, 2)

        // Check gene annotation
        let gene = record.annotations.first { $0.type == .gene }
        XCTAssertNotNil(gene)
        XCTAssertEqual(gene?.qualifiers["gene"]?.firstValue, "testGene")

        // Check CDS annotation
        let cds = record.annotations.first { $0.type == .cds }
        XCTAssertNotNil(cds)
        XCTAssertEqual(cds?.qualifiers["product"]?.firstValue, "Test protein")
    }

    // MARK: - Sequence Operations

    func testSequenceOperations() throws {
        // Create a DNA sequence
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATGCGATCGA")

        // Test reverse complement
        let revComp = seq.reverseComplement()
        XCTAssertNotNil(revComp)
        XCTAssertEqual(revComp?.asString(), "TCGATCGCAT")

        // Test length
        XCTAssertEqual(seq.length, 10)

        // Test asString
        XCTAssertEqual(seq.asString(), "ATGCGATCGA")

        // Test subsequence via subscript
        let subseq = seq[0..<5]
        XCTAssertEqual(subseq, "ATGCG")
    }

    // MARK: - Track Rendering Setup

    func testTrackRenderingSetup() throws {
        // Create a sequence for the track
        let sequence = try Sequence(
            name: "render_test",
            alphabet: .dna,
            bases: String(repeating: "ATCG", count: 250) // 1000 bp
        )

        // Create a sequence track
        let track = SequenceTrack(
            name: "Test Track",
            sequence: sequence
        )

        // Create a reference frame for rendering
        let frame = ReferenceFrame(
            chromosome: "render_test",
            chromosomeLength: 1000,
            widthInPixels: 700
        )

        // Verify track is ready
        XCTAssertEqual(track.name, "Test Track")
        XCTAssertNotNil(track.currentSequence)
        XCTAssertEqual(frame.chromosome, "render_test")
        XCTAssertEqual(frame.chromosomeLength, 1000)
    }

    // MARK: - Annotation Interval Operations

    func testAnnotationIntervalOperations() {
        // Create annotation intervals
        let interval1 = AnnotationInterval(start: 100, end: 200)
        let interval2 = AnnotationInterval(start: 150, end: 250)
        let interval3 = AnnotationInterval(start: 300, end: 400)

        // Test length
        XCTAssertEqual(interval1.length, 100)
        XCTAssertEqual(interval2.length, 100)
        XCTAssertEqual(interval3.length, 100)

        // Test basic properties
        XCTAssertEqual(interval1.start, 100)
        XCTAssertEqual(interval1.end, 200)
    }

    // MARK: - Version History Operations

    func testVersionHistoryOperations() throws {
        // Create a version history
        let history = VersionHistory(
            originalSequence: "AAAA",
            sequenceName: "version_test"
        )

        // Commit changes
        try history.commit(newSequence: "AABB", message: "First edit")
        try history.commit(newSequence: "AABBCC", message: "Second edit")
        try history.commit(newSequence: "AABBCCDD", message: "Third edit")

        XCTAssertEqual(history.versions.count, 3)
        XCTAssertEqual(history.currentVersionIndex, 3)

        // Navigate to previous version
        let v1 = try history.checkout(at: 1)
        XCTAssertEqual(v1, "AABB")

        // Navigate to original
        let v0 = try history.checkout(at: 0)
        XCTAssertEqual(v0, "AAAA")

        // Navigate to latest
        let v3 = try history.checkout(at: 3)
        XCTAssertEqual(v3, "AABBCCDD")
    }

    // MARK: - Edit Log

    func testEditLogOperations() throws {
        let projectURL = tempDirectory.appendingPathComponent("EditLogTest.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Edit Log Test")

        let sequence = try Sequence(name: "log_test", alphabet: .dna, bases: "ATCGATCG")
        let sequenceId = try project.addSequence(sequence)

        // Log multiple edits
        try project.logEdit(sequenceId: sequenceId, operation: "insert", position: 4, bases: "GGG")
        try project.logEdit(sequenceId: sequenceId, operation: "delete", position: 0, length: 2)
        try project.logEdit(sequenceId: sequenceId, operation: "replace", position: 5, length: 3, bases: "AAA")

        let edits = try project.getRecentEdits(sequenceId: sequenceId)
        XCTAssertEqual(edits.count, 3)

        // Verify order (most recent first)
        XCTAssertEqual(edits[0].operation, "replace")
        XCTAssertEqual(edits[1].operation, "delete")
        XCTAssertEqual(edits[2].operation, "insert")
    }

    // MARK: - Multi-Sequence Project

    func testMultiSequenceProject() throws {
        let projectURL = tempDirectory.appendingPathComponent("MultiSeq.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Multi-Sequence Test")

        // Add multiple sequences
        let seq1 = try Sequence(name: "chromosome1", alphabet: .dna, bases: String(repeating: "ATCG", count: 100))
        let seq2 = try Sequence(name: "chromosome2", alphabet: .dna, bases: String(repeating: "GCTA", count: 100))
        let seq3 = try Sequence(name: "plasmid", alphabet: .dna, bases: String(repeating: "AAGG", count: 50))

        let id1 = try project.addSequence(seq1)
        let id2 = try project.addSequence(seq2)
        let id3 = try project.addSequence(seq3)

        // Add annotations to different sequences
        try project.addAnnotation(to: id1, type: "gene", name: "gene1", range: 0..<100)
        try project.addAnnotation(to: id1, type: "gene", name: "gene2", range: 150..<250)
        try project.addAnnotation(to: id2, type: "CDS", name: "cds1", range: 50..<200)
        try project.addAnnotation(to: id3, type: "origin", name: "ori", range: 0..<50)

        // Verify sequences
        let sequences = try project.listSequences()
        XCTAssertEqual(sequences.count, 3)

        // Verify annotations per sequence
        let ann1 = try project.getAnnotations(for: id1)
        XCTAssertEqual(ann1.count, 2)

        let ann2 = try project.getAnnotations(for: id2)
        XCTAssertEqual(ann2.count, 1)

        let ann3 = try project.getAnnotations(for: id3)
        XCTAssertEqual(ann3.count, 1)

        // Save and reopen
        try project.save()
        let reopened = try ProjectFile.open(at: projectURL)

        let reopenedSeqs = try reopened.listSequences()
        XCTAssertEqual(reopenedSeqs.count, 3)
    }

    // MARK: - Sequence Diff Operations

    func testSequenceDiffOperations() throws {
        // Test insertion
        let insertDiff = SequenceDiff.compute(from: "AAAA", to: "AABBAA")
        XCTAssertFalse(insertDiff.isEmpty)

        let insertResult = try insertDiff.apply(to: "AAAA")
        XCTAssertEqual(insertResult, "AABBAA")

        // Test deletion
        let deleteDiff = SequenceDiff.compute(from: "AABBAA", to: "AAAA")
        let deleteResult = try deleteDiff.apply(to: "AABBAA")
        XCTAssertEqual(deleteResult, "AAAA")

        // Test substitution
        let subDiff = SequenceDiff.compute(from: "AAAA", to: "ABBA")
        let subResult = try subDiff.apply(to: "AAAA")
        XCTAssertEqual(subResult, "ABBA")

        // Test no change
        let noDiff = SequenceDiff.compute(from: "AAAA", to: "AAAA")
        XCTAssertTrue(noDiff.isEmpty)
    }

    // MARK: - File Format Detection

    func testFileFormatDetection() throws {
        // Test FASTA extension detection
        XCTAssertTrue(FASTAReader.supportedExtensions.contains("fa"))
        XCTAssertTrue(FASTAReader.supportedExtensions.contains("fasta"))
        XCTAssertTrue(FASTAReader.supportedExtensions.contains("fna"))

        // Test GenBank extension detection
        XCTAssertTrue(GenBankReader.supportedExtensions.contains("gb"))
        XCTAssertTrue(GenBankReader.supportedExtensions.contains("gbk"))
        XCTAssertTrue(GenBankReader.supportedExtensions.contains("genbank"))
    }

    // MARK: - Project Metadata

    func testProjectMetadata() throws {
        let projectURL = tempDirectory.appendingPathComponent("MetadataTest.lungfish")
        let project = try ProjectFile.create(
            at: projectURL,
            name: "Metadata Test",
            description: "Testing metadata persistence",
            author: "Test Author"
        )

        // Set custom metadata
        project.setCustomMetadata(key: "organism", value: "E. coli")
        project.setCustomMetadata(key: "strain", value: "K-12")
        project.setCustomMetadata(key: "lab", value: "Test Lab")

        // Verify metadata
        XCTAssertEqual(project.getCustomMetadata(key: "organism"), "E. coli")
        XCTAssertEqual(project.getCustomMetadata(key: "strain"), "K-12")
        XCTAssertEqual(project.getCustomMetadata(key: "lab"), "Test Lab")
        XCTAssertNil(project.getCustomMetadata(key: "nonexistent"))

        // Save and reopen
        try project.save()
        let reopened = try ProjectFile.open(at: projectURL)

        // Verify metadata persisted
        XCTAssertEqual(reopened.name, "Metadata Test")
        XCTAssertEqual(reopened.description, "Testing metadata persistence")
        XCTAssertEqual(reopened.author, "Test Author")
        XCTAssertEqual(reopened.getCustomMetadata(key: "organism"), "E. coli")
        XCTAssertEqual(reopened.getCustomMetadata(key: "strain"), "K-12")
    }
}
