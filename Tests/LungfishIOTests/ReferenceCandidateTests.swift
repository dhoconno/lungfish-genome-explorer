import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class ReferenceCandidateTests: XCTestCase {

    // MARK: - Display Name

    func testProjectReferenceDisplayName() {
        let manifest = ReferenceSequenceManifest(
            name: "Human GRCh38",
            createdAt: Date(),
            sourceFilename: "hg38.fasta",
            fastaFilename: "sequence.fasta"
        )
        let candidate = ReferenceCandidate.projectReference(
            url: URL(fileURLWithPath: "/project/refs/hg38.lungfishref"),
            manifest: manifest
        )
        XCTAssertEqual(candidate.displayName, "Human GRCh38")
    }

    func testGenomeBundleDisplayName() {
        let candidate = ReferenceCandidate.genomeBundleFASTA(
            fastaURL: URL(fileURLWithPath: "/project/downloads/genome.fasta"),
            bundleURL: URL(fileURLWithPath: "/project/downloads/genome.lungfishref"),
            displayName: "Macaca mulatta"
        )
        XCTAssertEqual(candidate.displayName, "Macaca mulatta")
    }

    func testStandaloneFASTADisplayName() {
        let candidate = ReferenceCandidate.standaloneFASTA(
            url: URL(fileURLWithPath: "/project/data/custom-reference.fasta")
        )
        XCTAssertEqual(candidate.displayName, "custom-reference")
    }

    // MARK: - FASTA URL

    func testProjectReferenceFastaURL() {
        let manifest = ReferenceSequenceManifest(
            name: "PhiX",
            createdAt: Date(),
            sourceFilename: "phix.fa",
            fastaFilename: "sequence.fasta"
        )
        let bundleURL = URL(fileURLWithPath: "/project/refs/phix.lungfishref")
        let candidate = ReferenceCandidate.projectReference(url: bundleURL, manifest: manifest)
        XCTAssertEqual(
            candidate.fastaURL.path,
            "/project/refs/phix.lungfishref/sequence.fasta"
        )
    }

    func testStandaloneFASTAFastaURL() {
        let url = URL(fileURLWithPath: "/project/data/ref.fasta")
        let candidate = ReferenceCandidate.standaloneFASTA(url: url)
        XCTAssertEqual(candidate.fastaURL, url)
    }

    func testProjectReferenceDisplayPathIsRelativeToProject() {
        let projectURL = URL(fileURLWithPath: "/project/example.lungfish", isDirectory: true)
        let manifest = ReferenceSequenceManifest(
            name: "NC_045512",
            createdAt: Date(),
            sourceFilename: "NC_045512.fasta",
            fastaFilename: "sequence.fasta"
        )
        let candidate = ReferenceCandidate.projectReference(
            url: projectURL.appendingPathComponent("Reference Sequences/NC_045512.lungfishref"),
            manifest: manifest
        )

        XCTAssertEqual(
            candidate.displayPath(relativeTo: projectURL),
            "Reference Sequences/NC_045512.lungfishref/sequence.fasta"
        )
    }

    // MARK: - Source Category

    func testSourceCategories() {
        let manifest = ReferenceSequenceManifest(
            name: "test", createdAt: Date(), sourceFilename: "t.fa", fastaFilename: "sequence.fasta"
        )
        XCTAssertEqual(
            ReferenceCandidate.projectReference(
                url: URL(fileURLWithPath: "/a"), manifest: manifest
            ).sourceCategory,
            .projectReferences
        )
        XCTAssertEqual(
            ReferenceCandidate.genomeBundleFASTA(
                fastaURL: URL(fileURLWithPath: "/b/genome.fa"),
                bundleURL: URL(fileURLWithPath: "/b"),
                displayName: "test"
            ).sourceCategory,
            .genomeBundles
        )
        XCTAssertEqual(
            ReferenceCandidate.standaloneFASTA(
                url: URL(fileURLWithPath: "/c")
            ).sourceCategory,
            .standaloneFASTAFiles
        )
    }

    // MARK: - Identifiable

    func testIdIsBasedOnFastaURL() {
        let url = URL(fileURLWithPath: "/project/data/ref.fasta")
        let candidate = ReferenceCandidate.standaloneFASTA(url: url)
        XCTAssertEqual(candidate.id, url.absoluteString)
    }

    // MARK: - Equatable

    func testEqualityBasedOnId() {
        let url = URL(fileURLWithPath: "/project/data/ref.fasta")
        let c1 = ReferenceCandidate.standaloneFASTA(url: url)
        let c2 = ReferenceCandidate.standaloneFASTA(url: url)
        XCTAssertEqual(c1, c2)
    }

    func testInequalityForDifferentURLs() {
        let c1 = ReferenceCandidate.standaloneFASTA(url: URL(fileURLWithPath: "/a.fasta"))
        let c2 = ReferenceCandidate.standaloneFASTA(url: URL(fileURLWithPath: "/b.fasta"))
        XCTAssertNotEqual(c1, c2)
    }

    // MARK: - ReferenceSequenceFolder Tests

    func testImportCreatesBundle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a source FASTA
        let sourceFASTA = tempDir.appendingPathComponent("test-ref.fasta")
        try ">seq1\nACGTACGT\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)

        // Create project directory
        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Import
        let bundleURL = try ReferenceSequenceFolder.importReference(
            from: sourceFASTA,
            into: projectDir,
            displayName: "Test Reference"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(bundleURL.lastPathComponent.hasSuffix(".lungfishref"))

        // Verify manifest
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        // Verify FASTA was copied
        let destFASTA = bundleURL.appendingPathComponent("sequence.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFASTA.path))
        let content = try String(contentsOf: destFASTA, encoding: .utf8)
        XCTAssertTrue(content.contains("ACGTACGT"))
    }

    func testImportIdempotent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFASTA = tempDir.appendingPathComponent("ref.fasta")
        try ">s1\nACGT\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let url1 = try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectDir)
        let url2 = try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectDir)
        XCTAssertEqual(url1, url2)
    }

    func testListReferencesSorted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        for name in ["Zeta", "Alpha", "Mu"] {
            let fasta = tempDir.appendingPathComponent("\(name).fasta")
            try ">seq\nACGT\n".write(to: fasta, atomically: true, encoding: .utf8)
            try ReferenceSequenceFolder.importReference(from: fasta, into: projectDir, displayName: name)
        }

        let refs = ReferenceSequenceFolder.listReferences(in: projectDir)
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0].manifest.name, "Alpha")
        XCTAssertEqual(refs[1].manifest.name, "Mu")
        XCTAssertEqual(refs[2].manifest.name, "Zeta")
    }

    func testScannerDiscoversFullReferenceBundlesInsideReferenceSequencesFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let referenceFolder = try ReferenceSequenceFolder.ensureFolder(in: projectDir)
        let bundleURL = referenceFolder.appendingPathComponent("FullGenome.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let fastaURL = genomeDir.appendingPathComponent("sequence.fa.gz")
        try ">chr1\nACGTACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try "chr1\t8\t6\t8\t9\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: "Full Genome Reference",
            identifier: "test.full-genome-reference",
            source: SourceInfo(organism: "Test organism", assembly: "TestAssembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 8,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 8, offset: 6, lineBases: 8, lineWidth: 9)
                ]
            )
        )
        try manifest.save(to: bundleURL)

        let candidates = ReferenceSequenceScanner.scanAll(in: projectDir)

        XCTAssertTrue(
            candidates.contains { candidate in
                candidate.sourceBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
                    && candidate.fastaURL.standardizedFileURL == fastaURL.standardizedFileURL
            },
            "Expected scanner to discover full .lungfishref bundles in Reference Sequences"
        )
    }

    func testEnsureFolderCreatesDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let folderURL = try ReferenceSequenceFolder.ensureFolder(in: projectDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))

        // Idempotent
        let folderURL2 = try ReferenceSequenceFolder.ensureFolder(in: projectDir)
        XCTAssertEqual(folderURL, folderURL2)
    }

    func testIsProjectReference() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let refFolder = try ReferenceSequenceFolder.ensureFolder(in: projectDir)
        let internalURL = refFolder.appendingPathComponent("test.fasta")
        let externalURL = URL(fileURLWithPath: "/tmp/external.fasta")

        XCTAssertTrue(ReferenceSequenceFolder.isProjectReference(internalURL, in: projectDir))
        XCTAssertFalse(ReferenceSequenceFolder.isProjectReference(externalURL, in: projectDir))
    }

    func testFastaURLReturnsNilForMissingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Import then delete the FASTA
        let sourceFASTA = tempDir.appendingPathComponent("ref.fasta")
        try ">s1\nACGT\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)
        let bundleURL = try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectDir)

        // Delete the copied FASTA
        let destFASTA = bundleURL.appendingPathComponent("sequence.fasta")
        try FileManager.default.removeItem(at: destFASTA)

        let result = ReferenceSequenceFolder.fastaURL(in: bundleURL)
        XCTAssertNil(result)
    }

    func testFastaURLRejectsTraversalManifestPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        let refFolder = try ReferenceSequenceFolder.ensureFolder(in: projectDir)
        let bundleURL = refFolder.appendingPathComponent("unsafe.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let outsideURL = refFolder.appendingPathComponent("outside.fasta")
        try ">outside\nACGT\n".write(to: outsideURL, atomically: true, encoding: .utf8)
        try writeReferenceManifest(
            ReferenceSequenceManifest(
                name: "Unsafe",
                createdAt: Date(),
                sourceFilename: "outside.fasta",
                fastaFilename: "../outside.fasta"
            ),
            to: bundleURL
        )

        XCTAssertNil(ReferenceSequenceFolder.fastaURL(in: bundleURL))
        XCTAssertTrue(ReferenceSequenceFolder.listReferences(in: projectDir).isEmpty)
        XCTAssertTrue(ReferenceSequenceScanner.scanAll(in: projectDir).allSatisfy {
            $0.fastaURL.standardizedFileURL != outsideURL.standardizedFileURL
        })

        let candidate = ReferenceCandidate.projectReference(
            url: bundleURL,
            manifest: ReferenceSequenceManifest(
                name: "Unsafe",
                createdAt: Date(),
                sourceFilename: "outside.fasta",
                fastaFilename: "../outside.fasta"
            )
        )
        XCTAssertNotEqual(candidate.fastaURL.standardizedFileURL, outsideURL.standardizedFileURL)
        XCTAssertTrue(candidate.fastaURL.standardizedFileURL.path.hasPrefix(bundleURL.standardizedFileURL.path))
    }

    func testListReferencesSkipsMalformedBundles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let refFolder = try ReferenceSequenceFolder.ensureFolder(in: projectDir)

        // Create a malformed bundle (directory with .lungfishref extension but no manifest)
        let badBundle = refFolder.appendingPathComponent("bad.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: badBundle, withIntermediateDirectories: true)

        // Create a good one
        let sourceFASTA = tempDir.appendingPathComponent("good.fasta")
        try ">s1\nACGT\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectDir, displayName: "Good")

        let refs = ReferenceSequenceFolder.listReferences(in: projectDir)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].manifest.name, "Good")
    }

    func testImportSanitizesNameWithSlashes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFASTA = tempDir.appendingPathComponent("ref.fasta")
        try ">s1\nACGT\n".write(to: sourceFASTA, atomically: true, encoding: .utf8)

        let projectDir = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let bundleURL = try ReferenceSequenceFolder.importReference(
            from: sourceFASTA,
            into: projectDir,
            displayName: "My/Ref:Name"
        )

        // The bundle name should not contain / or :
        XCTAssertFalse(bundleURL.lastPathComponent.contains("/"))
        XCTAssertFalse(bundleURL.lastPathComponent.contains(":"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
    }

    private func writeReferenceManifest(
        _ manifest: ReferenceSequenceManifest,
        to bundleURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("manifest.json"))
    }
}
