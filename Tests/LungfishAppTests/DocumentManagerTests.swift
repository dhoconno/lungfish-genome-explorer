// DocumentManagerTests.swift - Comprehensive tests for DocumentManager
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

// Disambiguate DocumentType: LungfishApp.DocumentType (file format type used by DocumentManager)
// vs LungfishCore.DocumentType (genomic document classification). We test the LungfishApp one.
private typealias AppDocumentType = LungfishApp.DocumentType

/// Comprehensive tests for DocumentManager, DocumentType, and DocumentLoadError.
///
/// Tests cover:
/// - DocumentType detection from file extensions
/// - DocumentType property behavior
/// - DocumentLoadError descriptions and content
/// - DocumentManager document loading from real temp files
/// - DocumentManager state management (close, active, register)
@MainActor
final class DocumentManagerTests: XCTestCase {

    // MARK: - Test Fixtures

    private var tempDir: URL!
    private var manager: DocumentManager!

    override func setUp() async throws {
        try await super.setUp()

        // Create a unique temp directory for each test
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Access the shared singleton and clear its state
        manager = DocumentManager.shared
        clearManagerState()
    }

    override func tearDown() async throws {
        // Clean up manager state
        clearManagerState()

        // Remove temp directory
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        manager = nil

        try await super.tearDown()
    }

    /// Resets DocumentManager to a clean state between tests.
    private func clearManagerState() {
        manager.closeActiveProject()

        // Close all documents
        let docs = manager.documents
        for doc in docs {
            manager.closeDocument(doc)
        }
        manager.activeDocument = nil
    }

    // MARK: - 1. DocumentType Detection Tests

    func testDetectFasta() {
        let extensions = ["fa", "fasta", "fna", "fas"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            let detected = AppDocumentType.detect(from: url)
            XCTAssertEqual(detected, .fasta, "Expected .fasta for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDetectFastq() {
        let extensions = ["fq", "fastq"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            let detected = AppDocumentType.detect(from: url)
            XCTAssertEqual(detected, .fastq, "Expected .fastq for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDetectGenBank() {
        let extensions = ["gb", "gbk", "genbank"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            let detected = AppDocumentType.detect(from: url)
            XCTAssertEqual(detected, .genbank, "Expected .genbank for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDetectGFF3() {
        let extensions = ["gff", "gff3"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            let detected = AppDocumentType.detect(from: url)
            XCTAssertEqual(detected, .gff3, "Expected .gff3 for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDetectBED() {
        let url = URL(fileURLWithPath: "/tmp/test.bed")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .bed)
    }

    func testDetectVCF() {
        let url = URL(fileURLWithPath: "/tmp/test.vcf")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .vcf)
    }

    func testDetectBAM() {
        let extensions = ["bam", "cram", "sam"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            let detected = AppDocumentType.detect(from: url)
            XCTAssertEqual(detected, .bam, "Expected .bam for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDetectLungfishProject() {
        let url = URL(fileURLWithPath: "/tmp/myproject.lungfish")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .lungfishProject)
    }

    func testDetectGzipCompressed() {
        // .fasta.gz should strip .gz and detect .fasta
        let url = URL(fileURLWithPath: "/tmp/test.fasta.gz")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .fasta, "Expected .fasta for .fasta.gz but got \(String(describing: detected))")

        // .fq.gz should strip .gz and detect .fastq
        let fqURL = URL(fileURLWithPath: "/tmp/reads.fq.gz")
        let fqDetected = AppDocumentType.detect(from: fqURL)
        XCTAssertEqual(fqDetected, .fastq, "Expected .fastq for .fq.gz but got \(String(describing: fqDetected))")

        // .vcf.gz should strip .gz and detect .vcf
        let vcfURL = URL(fileURLWithPath: "/tmp/variants.vcf.gz")
        let vcfDetected = AppDocumentType.detect(from: vcfURL)
        XCTAssertEqual(vcfDetected, .vcf, "Expected .vcf for .vcf.gz but got \(String(describing: vcfDetected))")
    }

    func testDetectUnknown() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertNil(detected, "Expected nil for unknown extension .xyz but got \(String(describing: detected))")
    }

    func testDetectEmptyExtension() {
        let url = URL(fileURLWithPath: "/tmp/noextension")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertNil(detected, "Expected nil for file with no extension but got \(String(describing: detected))")
    }

    func testDetectCaseInsensitive() {
        // Extensions should be lowercased for comparison
        let url = URL(fileURLWithPath: "/tmp/test.FASTA")
        let detected = AppDocumentType.detect(from: url)
        XCTAssertEqual(detected, .fasta, "Detection should be case-insensitive")

        let gbURL = URL(fileURLWithPath: "/tmp/test.GBK")
        let gbDetected = AppDocumentType.detect(from: gbURL)
        XCTAssertEqual(gbDetected, .genbank, "Detection should be case-insensitive for GenBank")
    }

    // MARK: - 2. DocumentType Property Tests

    func testIsDirectoryFormat() {
        // Only .lungfishProject should return true
        XCTAssertTrue(AppDocumentType.lungfishProject.isDirectoryFormat,
                       ".lungfishProject should be a directory format")

        // All other types should return false
        let nonDirectoryTypes: [AppDocumentType] = [.fasta, .fastq, .genbank, .gff3, .bed, .vcf, .bam]
        for type in nonDirectoryTypes {
            XCTAssertFalse(type.isDirectoryFormat,
                           "\(type.rawValue) should NOT be a directory format")
        }
    }

    func testExtensionsCompleteness() {
        // Every DocumentType case must have at least one extension
        for type in AppDocumentType.allCases {
            XCTAssertFalse(type.extensions.isEmpty,
                           "\(type.rawValue) must have at least one file extension")
        }
    }

    func testAllCasesPresent() {
        // Verify we have all expected cases
        let expectedCases: Set<AppDocumentType> = [
            .fasta, .fastq, .genbank, .gff3, .bed, .vcf, .bam, .lungfishProject, .lungfishReferenceBundle
        ]
        let actualCases = Set(AppDocumentType.allCases)
        XCTAssertEqual(actualCases, expectedCases, "DocumentType should have exactly the expected cases")
    }

    func testSupportedExtensions() {
        // DocumentManager.supportedExtensions should aggregate all type extensions
        let supported = DocumentManager.supportedExtensions

        // Verify it contains extensions from each type
        XCTAssertTrue(supported.contains("fa"), "supportedExtensions should include 'fa'")
        XCTAssertTrue(supported.contains("fasta"), "supportedExtensions should include 'fasta'")
        XCTAssertTrue(supported.contains("fq"), "supportedExtensions should include 'fq'")
        XCTAssertTrue(supported.contains("gb"), "supportedExtensions should include 'gb'")
        XCTAssertTrue(supported.contains("gff3"), "supportedExtensions should include 'gff3'")
        XCTAssertTrue(supported.contains("bed"), "supportedExtensions should include 'bed'")
        XCTAssertTrue(supported.contains("vcf"), "supportedExtensions should include 'vcf'")
        XCTAssertTrue(supported.contains("bam"), "supportedExtensions should include 'bam'")
        XCTAssertTrue(supported.contains("lungfish"), "supportedExtensions should include 'lungfish'")

        // Verify total count matches sum of all type extensions
        let expectedCount = AppDocumentType.allCases.reduce(0) { $0 + $1.extensions.count }
        XCTAssertEqual(supported.count, expectedCount,
                       "supportedExtensions count should equal the sum of all type extensions")
    }

    func testExtensionsHaveNoDuplicatesAcrossTypes() {
        // Each extension should belong to exactly one DocumentType
        var seen: [String: AppDocumentType] = [:]
        for type in AppDocumentType.allCases {
            for ext in type.extensions {
                if let existing = seen[ext] {
                    XCTFail("Extension '\(ext)' is claimed by both \(existing.rawValue) and \(type.rawValue)")
                }
                seen[ext] = type
            }
        }
    }

    // MARK: - 3. DocumentLoadError Tests

    func testErrorDescriptions() {
        // All error cases should produce non-nil, non-empty descriptions
        let errors: [DocumentLoadError] = [
            .unsupportedFormat("xyz"),
            .fileNotFound(URL(fileURLWithPath: "/tmp/missing.fa")),
            .parseError("unexpected token"),
            .accessDenied(URL(fileURLWithPath: "/tmp/secret.fa"))
        ]

        for error in errors {
            let description = error.errorDescription
            XCTAssertNotNil(description, "\(error) should have an errorDescription")
            XCTAssertFalse(description!.isEmpty, "\(error) should have a non-empty errorDescription")
        }
    }

    func testUnsupportedFormatError() {
        let error = DocumentLoadError.unsupportedFormat("xyz")
        let description = error.errorDescription!
        XCTAssertTrue(description.contains("xyz"),
                       "Unsupported format error should contain the extension string. Got: \(description)")
        XCTAssertTrue(description.lowercased().contains("unsupported"),
                       "Error message should indicate the format is unsupported. Got: \(description)")
    }

    func testFileNotFoundError() {
        let url = URL(fileURLWithPath: "/tmp/genome.fasta")
        let error = DocumentLoadError.fileNotFound(url)
        let description = error.errorDescription!
        XCTAssertTrue(description.contains("genome.fasta"),
                       "File not found error should contain the file name. Got: \(description)")
    }

    func testParseError() {
        let reason = "unexpected EOF at line 42"
        let error = DocumentLoadError.parseError(reason)
        let description = error.errorDescription!
        XCTAssertTrue(description.contains(reason),
                       "Parse error should contain the reason. Got: \(description)")
    }

    func testAccessDeniedError() {
        let url = URL(fileURLWithPath: "/tmp/protected.gb")
        let error = DocumentLoadError.accessDenied(url)
        let description = error.errorDescription!
        XCTAssertTrue(description.contains("protected.gb"),
                       "Access denied error should contain the file name. Got: \(description)")
    }

    func testDocumentLoadErrorConformsToLocalizedError() {
        // Verify that localizedDescription works through the LocalizedError protocol
        let error = DocumentLoadError.parseError("bad data")
        let localized = error.localizedDescription
        XCTAssertTrue(localized.contains("bad data"),
                       "localizedDescription should use errorDescription. Got: \(localized)")
    }

    // MARK: - 4. DocumentManager Loading Tests

    func testLoadFASTADocument() async throws {
        let fastaURL = tempDir.appendingPathComponent("test.fa")
        let content = ">seq1 test sequence one\nATCGATCGATCG\n>seq2 test sequence two\nGCTAGCTAGCTA\n"
        try content.write(to: fastaURL, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: fastaURL)

        XCTAssertEqual(document.type, .fasta)
        XCTAssertEqual(document.name, "test.fa")
        XCTAssertEqual(document.sequences.count, 2, "Should load 2 sequences from FASTA")
        XCTAssertEqual(document.sequences[0].name, "seq1")
        XCTAssertEqual(document.sequences[1].name, "seq2")
        XCTAssertEqual(document.sequences[0].length, 12)
        XCTAssertEqual(document.sequences[0].asString(), "ATCGATCGATCG")
        XCTAssertTrue(document.annotations.isEmpty, "FASTA should not produce annotations")
    }

    func testLoadGenBankDocument() async throws {
        let gbURL = tempDir.appendingPathComponent("test.gb")
        // GenBank format requires precise column alignment
        let content = [
            "LOCUS       TestSeq                   20 bp    DNA     linear   UNK 01-JAN-2024",
            "DEFINITION  Test sequence for unit tests.",
            "ACCESSION   TEST001",
            "VERSION     TEST001.1",
            "FEATURES             Location/Qualifiers",
            "     gene            1..10",
            "                     /gene=\"testGene\"",
            "     CDS             5..15",
            "                     /gene=\"testCDS\"",
            "                     /product=\"test protein\"",
            "ORIGIN",
            "        1 atcgatcgat cgatcgatcg",
            "//",
        ].joined(separator: "\n")
        try content.write(to: gbURL, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: gbURL)

        XCTAssertEqual(document.type, .genbank)
        XCTAssertEqual(document.name, "test.gb")
        XCTAssertGreaterThanOrEqual(document.sequences.count, 1, "Should load at least 1 sequence from GenBank")
        XCTAssertEqual(document.sequences[0].name, "TestSeq")
        XCTAssertEqual(document.sequences[0].length, 20)

        // GenBank files produce feature annotations
        XCTAssertGreaterThanOrEqual(document.annotations.count, 2,
                                     "Should load at least 2 annotations (gene + CDS)")

        // Verify annotation types
        let annotationTypes = document.annotations.map { $0.type }
        XCTAssertTrue(annotationTypes.contains(.gene), "Annotations should include a gene feature")
        XCTAssertTrue(annotationTypes.contains(.cds), "Annotations should include a CDS feature")
    }

    func testLoadGFF3Document() async throws {
        let gffURL = tempDir.appendingPathComponent("test.gff3")
        let content = "##gff-version 3\nchr1\t.\tgene\t100\t500\t.\t+\t.\tID=gene1;Name=TestGene\nchr1\t.\tCDS\t200\t400\t.\t+\t0\tID=cds1;Parent=gene1\n"
        try content.write(to: gffURL, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: gffURL)

        XCTAssertEqual(document.type, .gff3)
        XCTAssertEqual(document.name, "test.gff3")
        XCTAssertTrue(document.sequences.isEmpty, "GFF3 should not produce sequences")
        XCTAssertEqual(document.annotations.count, 2, "Should load 2 annotations from GFF3")

        // Verify first annotation
        let geneAnnotation = document.annotations.first { $0.name == "TestGene" }
        XCTAssertNotNil(geneAnnotation, "Should have an annotation named 'TestGene'")
        XCTAssertEqual(geneAnnotation?.type, .gene)
        XCTAssertEqual(geneAnnotation?.strand, .forward)
    }

    func testLoadBEDDocument() async throws {
        let bedURL = tempDir.appendingPathComponent("test.bed")
        let content = "chr1\t100\t500\tgene1\t100\t+\nchr1\t1000\t2000\tgene2\t200\t-\nchr2\t500\t800\tgene3\t300\t+\n"
        try content.write(to: bedURL, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: bedURL)

        XCTAssertEqual(document.type, .bed)
        XCTAssertEqual(document.name, "test.bed")
        XCTAssertTrue(document.sequences.isEmpty, "BED should not produce sequences")
        XCTAssertEqual(document.annotations.count, 3, "Should load 3 annotations from BED")

        // Verify annotation names and strands
        let names = document.annotations.map { $0.name }
        XCTAssertTrue(names.contains("gene1"), "Should have annotation named 'gene1'")
        XCTAssertTrue(names.contains("gene2"), "Should have annotation named 'gene2'")
        XCTAssertTrue(names.contains("gene3"), "Should have annotation named 'gene3'")
    }

    func testLoadVCFDocument() async throws {
        let vcfURL = tempDir.appendingPathComponent("test.vcf")
        let content = "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\trs12345\tA\tG\t30\tPASS\t.\nchr1\t200\t.\tATCG\tA\t25\tPASS\t.\n"
        try content.write(to: vcfURL, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: vcfURL)

        XCTAssertEqual(document.type, .vcf)
        XCTAssertEqual(document.name, "test.vcf")
        XCTAssertTrue(document.sequences.isEmpty, "VCF should not produce sequences")
        XCTAssertEqual(document.annotations.count, 2, "Should load 2 variant annotations from VCF")
    }

    func testLoadFileNotFound() async {
        let missingURL = tempDir.appendingPathComponent("does_not_exist.fa")

        do {
            _ = try await manager.loadDocument(at: missingURL)
            XCTFail("Loading a missing file should throw")
        } catch let error as DocumentLoadError {
            if case .fileNotFound(let url) = error {
                XCTAssertEqual(url.lastPathComponent, "does_not_exist.fa")
            } else {
                XCTFail("Expected .fileNotFound but got \(error)")
            }
        } catch {
            XCTFail("Expected DocumentLoadError.fileNotFound but got \(type(of: error)): \(error)")
        }
    }

    func testLoadUnsupportedFormat() async throws {
        let unknownURL = tempDir.appendingPathComponent("data.xyz")
        try "some data".write(to: unknownURL, atomically: true, encoding: .utf8)

        do {
            _ = try await manager.loadDocument(at: unknownURL)
            XCTFail("Loading an unsupported format should throw")
        } catch let error as DocumentLoadError {
            if case .unsupportedFormat(let ext) = error {
                XCTAssertEqual(ext, "xyz", "Should report the unsupported extension")
            } else {
                XCTFail("Expected .unsupportedFormat but got \(error)")
            }
        } catch {
            XCTFail("Expected DocumentLoadError.unsupportedFormat but got \(type(of: error)): \(error)")
        }
    }

    func testLoadBAMThrows() async throws {
        // BAM files are imported as alignment tracks, not loaded as standalone documents
        let bamURL = tempDir.appendingPathComponent("test.bam")
        try Data([0x00]).write(to: bamURL)

        do {
            _ = try await manager.loadDocument(at: bamURL)
            XCTFail("Loading a BAM file should throw unsupportedFormat")
        } catch let error as DocumentLoadError {
            if case .unsupportedFormat(let message) = error {
                XCTAssertTrue(message.contains("alignment tracks"),
                               "BAM error should direct users to import menu. Got: \(message)")
            } else {
                XCTFail("Expected .unsupportedFormat for BAM but got \(error)")
            }
        } catch {
            // Other errors (like parse errors) are also acceptable since BAM is binary
            // The important thing is that it does not succeed
        }
    }

    func testLoadDocumentAddsToDocumentsList() async throws {
        let fastaURL = tempDir.appendingPathComponent("added.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(manager.documents.count, 0, "Should start with no documents")

        _ = try await manager.loadDocument(at: fastaURL)

        XCTAssertEqual(manager.documents.count, 1, "Should have 1 document after loading")
    }

    func testLoadDocumentSetsActiveDocument() async throws {
        let fastaURL = tempDir.appendingPathComponent("active.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        XCTAssertNil(manager.activeDocument, "Active document should be nil initially")

        let document = try await manager.loadDocument(at: fastaURL)

        XCTAssertNotNil(manager.activeDocument, "Active document should be set after loading")
        XCTAssertEqual(manager.activeDocument?.id, document.id,
                       "Active document should be the newly loaded document")
    }

    func testLoadDocumentPostsNotification() async throws {
        let fastaURL = tempDir.appendingPathComponent("notif.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let expectation = expectation(
            forNotification: DocumentManager.documentLoadedNotification,
            object: manager
        )

        _ = try await manager.loadDocument(at: fastaURL)

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testCreateProjectClearsExistingDocumentState() async throws {
        let fastaURL = tempDir.appendingPathComponent("existing.fa")
        try ">seq1\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        _ = try await manager.loadDocument(at: fastaURL)

        let project = try manager.createProject(
            at: tempDir.appendingPathComponent("FreshProject"),
            name: "Fresh Project"
        )

        XCTAssertEqual(manager.activeProject?.url, project.url)
        XCTAssertTrue(manager.documents.isEmpty, "Creating a project should reset prior loaded documents")
        XCTAssertNil(manager.activeDocument, "Creating an empty project should clear the active document")
    }

    func testOpenProjectReplacesStandaloneDocumentsWithProjectDocuments() async throws {
        let fastaURL = tempDir.appendingPathComponent("standalone.fa")
        try ">standalone\nATCG\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        _ = try await manager.loadDocument(at: fastaURL)

        let projectURL = tempDir.appendingPathComponent("SwitchProject.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Switch Project")
        try project.addSequence(makeSequence(name: "project_seq", bases: "GATTACA"))
        try project.save()

        _ = try manager.openProject(at: projectURL)

        XCTAssertEqual(manager.activeProject?.url, projectURL)
        XCTAssertEqual(manager.documents.count, 1, "Opening a project should replace standalone documents")
        XCTAssertEqual(manager.activeDocument?.sequences.first?.name, "project_seq")
        XCTAssertFalse(manager.documents.contains(where: { $0.url == fastaURL }))
    }

    func testLoadDocumentForProjectReturnsProjectActiveDocumentInsteadOfStaleFirstDocument() async throws {
        let staleURL = tempDir.appendingPathComponent("stale.fa")
        try ">stale\nATCG\n".write(to: staleURL, atomically: true, encoding: .utf8)
        _ = try await manager.loadDocument(at: staleURL)

        let projectURL = tempDir.appendingPathComponent("ProjectLoad.lungfish")
        let project = try ProjectFile.create(at: projectURL, name: "Project Load")
        try project.addSequence(makeSequence(name: "fresh_project_seq", bases: "AACCGGTT"))
        try project.save()

        let returned = try await manager.loadDocument(at: projectURL)

        XCTAssertEqual(returned.id, manager.activeDocument?.id)
        XCTAssertEqual(returned.sequences.first?.name, "fresh_project_seq")
        XCTAssertEqual(manager.documents.count, 1)
        XCTAssertFalse(manager.documents.contains(where: { $0.url == staleURL }))
    }

    // MARK: - 5. DocumentManager State Tests

    func testCloseDocumentRemovesFromList() async throws {
        // Load two documents
        let url1 = tempDir.appendingPathComponent("doc1.fa")
        try ">seq1\nATCG\n".write(to: url1, atomically: true, encoding: .utf8)
        let url2 = tempDir.appendingPathComponent("doc2.fa")
        try ">seq2\nGCTA\n".write(to: url2, atomically: true, encoding: .utf8)

        let doc1 = try await manager.loadDocument(at: url1)
        _ = try await manager.loadDocument(at: url2)

        XCTAssertEqual(manager.documents.count, 2)

        manager.closeDocument(doc1)

        XCTAssertEqual(manager.documents.count, 1, "Should have 1 document after closing one")
        XCTAssertFalse(manager.documents.contains(where: { $0.id == doc1.id }),
                        "Closed document should not be in the list")
    }

    func testCloseDocumentUpdatesActive() async throws {
        // Load two documents: doc1 first, then doc2 becomes active
        let url1 = tempDir.appendingPathComponent("first.fa")
        try ">seq1\nATCG\n".write(to: url1, atomically: true, encoding: .utf8)
        let url2 = tempDir.appendingPathComponent("second.fa")
        try ">seq2\nGCTA\n".write(to: url2, atomically: true, encoding: .utf8)

        _ = try await manager.loadDocument(at: url1)
        let doc2 = try await manager.loadDocument(at: url2)

        // doc2 is now active (last loaded becomes active)
        XCTAssertEqual(manager.activeDocument?.id, doc2.id)

        // Close the active document
        manager.closeDocument(doc2)

        // Active should switch to the remaining document (documents.first)
        XCTAssertNotNil(manager.activeDocument,
                         "Active should switch to remaining document when active is closed")
        XCTAssertEqual(manager.documents.count, 1)
        XCTAssertEqual(manager.activeDocument?.id, manager.documents.first?.id)
    }

    func testCloseLastDocumentSetsActiveNil() async throws {
        let url = tempDir.appendingPathComponent("only.fa")
        try ">seq1\nATCG\n".write(to: url, atomically: true, encoding: .utf8)

        let doc = try await manager.loadDocument(at: url)

        XCTAssertNotNil(manager.activeDocument)

        manager.closeDocument(doc)

        XCTAssertTrue(manager.documents.isEmpty, "Documents list should be empty")
        XCTAssertNil(manager.activeDocument,
                      "Active document should be nil when the last document is closed")
    }

    func testCloseNonActiveDocumentKeepsActive() async throws {
        let url1 = tempDir.appendingPathComponent("keep.fa")
        try ">seq1\nATCG\n".write(to: url1, atomically: true, encoding: .utf8)
        let url2 = tempDir.appendingPathComponent("close_me.fa")
        try ">seq2\nGCTA\n".write(to: url2, atomically: true, encoding: .utf8)

        let doc1 = try await manager.loadDocument(at: url1)
        let doc2 = try await manager.loadDocument(at: url2)

        // doc2 is active. Close doc1 (not active).
        XCTAssertEqual(manager.activeDocument?.id, doc2.id)

        manager.closeDocument(doc1)

        XCTAssertEqual(manager.activeDocument?.id, doc2.id,
                       "Active document should not change when a non-active document is closed")
        XCTAssertEqual(manager.documents.count, 1)
    }

    func testSetActiveDocumentPostsNotification() async throws {
        let url = tempDir.appendingPathComponent("notify.fa")
        try ">seq1\nATCG\n".write(to: url, atomically: true, encoding: .utf8)

        let doc = try await manager.loadDocument(at: url)

        let expectation = expectation(
            forNotification: DocumentManager.activeDocumentChangedNotification,
            object: manager
        )

        manager.setActiveDocument(doc)

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testSetActiveDocumentToNilPostsNotification() async throws {
        let url = tempDir.appendingPathComponent("nilactive.fa")
        try ">seq1\nATCG\n".write(to: url, atomically: true, encoding: .utf8)
        _ = try await manager.loadDocument(at: url)

        let expectation = expectation(
            forNotification: DocumentManager.activeDocumentChangedNotification,
            object: manager
        )

        manager.setActiveDocument(nil)

        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertNil(manager.activeDocument)
    }

    func testRegisterDocumentAddsToList() {
        let url = URL(fileURLWithPath: "/tmp/registered.fa")
        let document = LoadedDocument(url: url, type: .fasta)

        XCTAssertEqual(manager.documents.count, 0)

        manager.registerDocument(document)

        XCTAssertEqual(manager.documents.count, 1)
        XCTAssertEqual(manager.documents.first?.id, document.id)
        XCTAssertEqual(manager.documents.first?.url, url)
    }

    func testRegisterDocumentSkipsDuplicate() {
        let url = URL(fileURLWithPath: "/tmp/duplicate.fa")
        let document1 = LoadedDocument(url: url, type: .fasta)
        let document2 = LoadedDocument(url: url, type: .fasta)

        manager.registerDocument(document1)
        manager.registerDocument(document2)

        // registerDocument checks by URL, so the second registration with the same URL is skipped
        XCTAssertEqual(manager.documents.count, 1,
                       "Should not register a document with the same URL twice")
        XCTAssertEqual(manager.documents.first?.id, document1.id,
                       "Should keep the first registered document")
    }

    func testRegisterDifferentURLsAllowed() {
        let url1 = URL(fileURLWithPath: "/tmp/first.fa")
        let url2 = URL(fileURLWithPath: "/tmp/second.fa")
        let doc1 = LoadedDocument(url: url1, type: .fasta)
        let doc2 = LoadedDocument(url: url2, type: .fasta)

        manager.registerDocument(doc1)
        manager.registerDocument(doc2)

        XCTAssertEqual(manager.documents.count, 2,
                       "Documents with different URLs should both be registered")
    }

    // MARK: - 6. LoadedDocument Tests

    func testLoadedDocumentProperties() {
        let url = URL(fileURLWithPath: "/tmp/myfile.fasta")
        let document = LoadedDocument(url: url, type: .fasta)

        XCTAssertEqual(document.url, url)
        XCTAssertEqual(document.name, "myfile.fasta")
        XCTAssertEqual(document.type, .fasta)
        XCTAssertTrue(document.sequences.isEmpty, "New document should have no sequences")
        XCTAssertTrue(document.annotations.isEmpty, "New document should have no annotations")
        XCTAssertNotEqual(document.id, UUID(), "Document should have a valid UUID")
    }

    func testLoadedDocumentIdentity() {
        let url = URL(fileURLWithPath: "/tmp/test.fa")
        let doc1 = LoadedDocument(url: url, type: .fasta)
        let doc2 = LoadedDocument(url: url, type: .fasta)

        XCTAssertNotEqual(doc1.id, doc2.id,
                          "Two LoadedDocument instances should have different UUIDs")
    }

    // MARK: - 7. Notification Tests

    func testDocumentLoadedNotificationName() {
        let name = DocumentManager.documentLoadedNotification
        XCTAssertEqual(name.rawValue, "DocumentManagerDocumentLoaded")
    }

    func testActiveDocumentChangedNotificationName() {
        let name = DocumentManager.activeDocumentChangedNotification
        XCTAssertEqual(name.rawValue, "DocumentManagerActiveDocumentChanged")
    }

    func testProjectOpenedNotificationName() {
        let name = DocumentManager.projectOpenedNotification
        XCTAssertEqual(name.rawValue, "DocumentManagerProjectOpened")
    }

    // MARK: - 8. Multiple Document Workflow Tests

    func testLoadMultipleDocumentsSequentially() async throws {
        let url1 = tempDir.appendingPathComponent("multi1.fa")
        try ">seq1\nATCG\n".write(to: url1, atomically: true, encoding: .utf8)

        let url2 = tempDir.appendingPathComponent("multi2.gff3")
        try "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t+\t.\tID=g1;Name=Gene1\n"
            .write(to: url2, atomically: true, encoding: .utf8)

        let url3 = tempDir.appendingPathComponent("multi3.bed")
        try "chr1\t100\t500\tregion1\t0\t+\n"
            .write(to: url3, atomically: true, encoding: .utf8)

        _ = try await manager.loadDocument(at: url1)
        _ = try await manager.loadDocument(at: url2)
        let doc3 = try await manager.loadDocument(at: url3)

        XCTAssertEqual(manager.documents.count, 3, "Should have 3 documents loaded")

        // Active should be the last loaded
        XCTAssertEqual(manager.activeDocument?.id, doc3.id,
                       "Active document should be the last loaded")

        // Verify each document has the correct type
        let types = manager.documents.map { $0.type }
        XCTAssertTrue(types.contains(.fasta))
        XCTAssertTrue(types.contains(.gff3))
        XCTAssertTrue(types.contains(.bed))
    }

    func testCloseAllDocuments() async throws {
        // Load several documents
        for i in 0..<3 {
            let url = tempDir.appendingPathComponent("closeme\(i).fa")
            try ">seq\(i)\nATCG\n".write(to: url, atomically: true, encoding: .utf8)
            _ = try await manager.loadDocument(at: url)
        }

        XCTAssertEqual(manager.documents.count, 3)

        // Close them all one by one
        while let doc = manager.documents.first {
            manager.closeDocument(doc)
        }

        XCTAssertTrue(manager.documents.isEmpty)
        XCTAssertNil(manager.activeDocument)
    }

    // MARK: - 9. Edge Cases

    func testLoadEmptyFASTAFile() async throws {
        let url = tempDir.appendingPathComponent("empty.fa")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: url)

        // An empty FASTA file should produce no sequences
        XCTAssertTrue(document.sequences.isEmpty, "Empty FASTA should produce no sequences")
    }

    func testLoadFASTAWithSingleSequence() async throws {
        let url = tempDir.appendingPathComponent("single.fa")
        try ">only_one\nATCGATCGATCG\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try await manager.loadDocument(at: url)

        XCTAssertEqual(document.sequences.count, 1)
        XCTAssertEqual(document.sequences.first?.name, "only_one")
        XCTAssertEqual(document.sequences.first?.length, 12)
    }

    func testDocumentManagerIsSingleton() {
        let instance1 = DocumentManager.shared
        let instance2 = DocumentManager.shared
        XCTAssertTrue(instance1 === instance2, "DocumentManager.shared should return the same instance")
    }

    func testPasteboardTypes() {
        let types = DocumentManager.pasteboardTypes
        XCTAssertFalse(types.isEmpty, "Should have at least one pasteboard type")
        XCTAssertTrue(types.contains(.fileURL), "Should support file URL pasteboard type")
    }

    private func makeSequence(name: String, bases: String) throws -> Sequence {
        try Sequence(name: name, alphabet: .dna, bases: bases)
    }
}
