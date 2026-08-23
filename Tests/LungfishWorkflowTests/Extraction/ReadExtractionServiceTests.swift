import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO

final class ReadExtractionServiceTests: XCTestCase {
    func testSamtoolsRegionsMergeAdjacentBlocksAndUseOneBasedInclusiveCoordinates() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "orf1ab",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 100, end: 120),
                AnnotationInterval(start: 120, end: 130),
                AnnotationInterval(start: 200, end: 210),
                AnnotationInterval(start: 205, end: 220)
            ]
        )

        XCTAssertEqual(
            ReadExtractionService.samtoolsRegions(for: annotation),
            ["chr1:101-130", "chr1:201-220"]
        )
    }

    func testSamtoolsRegionsReturnEmptyWhenChromosomeIsMissing() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "orf1ab",
            intervals: [AnnotationInterval(start: 100, end: 130)]
        )

        XCTAssertTrue(ReadExtractionService.samtoolsRegions(for: annotation).isEmpty)
    }

    func testCreateBundlePersistsExtractionPairingModeInFASTQMetadata() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("read-extract-bundle-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let r1 = root.appendingPathComponent("selected_R1.fastq")
        let r2 = root.appendingPathComponent("selected_R2.fastq")
        try "@read/1\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@read/2\nTGCA\n+\nIIII\n".write(to: r2, atomically: true, encoding: .utf8)

        let metadata = ExtractionMetadata(
            sourceDescription: "fixture",
            toolName: "test",
            extractionDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let service = ReadExtractionService()

        let bundleURL = try await service.createBundle(
            from: ExtractionResult(fastqURLs: [r1, r2], readCount: 1, pairedEnd: true),
            sourceName: "fixture",
            selectionDescription: "selected",
            metadata: metadata,
            in: root
        )

        let movedR1 = bundleURL.appendingPathComponent("selected_R1.fastq")
        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: movedR1))
        XCTAssertEqual(persisted.ingestion?.pairingMode, .pairedEnd)
        XCTAssertEqual(persisted.ingestion?.originalFilenames, ["selected_R1.fastq", "selected_R2.fastq"])
        XCTAssertEqual(persisted.downloadSource, "read-extraction")

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(provenance.workflowName, "Classifier Read Extraction")
        XCTAssertEqual(provenance.toolName, "test")
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.options.resolvedDefaults["readCount"], .integer(1))
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == movedR1.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == bundleURL.appendingPathComponent("extraction-metadata.json").path
                && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: bundleURL
                    .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                    .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
                    .path
            )
        )
    }

    // MARK: - FASTA payload bundles

    func testCreateBundleWithFASTAPayloadResolvesViaPrimarySequenceURL() async throws {
        // Regression: a FASTA-output classifier extraction produced a bundle with
        // no derived manifest, so FASTQBundle.resolvePrimarySequenceURL could not
        // find the payload and the sidebar could not open the bundle.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("read-extract-fasta-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fasta = root.appendingPathComponent("kraken2-concat.fasta")
        try ">read1\nACGTACGT\n>read2\nTTTTGGGG\n".write(to: fasta, atomically: true, encoding: .utf8)

        let service = ReadExtractionService()
        let bundleURL = try await service.createBundle(
            from: ExtractionResult(fastqURLs: [fasta], readCount: 2, pairedEnd: false),
            sourceName: "fixture",
            selectionDescription: "fasta-selection",
            metadata: ExtractionMetadata(sourceDescription: "fixture", toolName: "test"),
            in: root
        )

        let manifest = try XCTUnwrap(
            FASTQBundle.loadDerivedManifest(in: bundleURL),
            "FASTA-payload bundle must carry a derived manifest so it can be opened"
        )
        guard case .fullFASTA(let filename) = manifest.payload else {
            XCTFail("Expected .fullFASTA payload, got \(manifest.payload)")
            return
        }
        XCTAssertEqual(filename, "kraken2-concat.fasta")
        XCTAssertEqual(manifest.sequenceFormat, .fasta)

        let resolved = try XCTUnwrap(
            FASTQBundle.resolvePrimarySequenceURL(for: bundleURL),
            "FASTA-backed bundle must resolve a primary sequence URL"
        )
        XCTAssertEqual(resolved.lastPathComponent, "kraken2-concat.fasta")
    }

    func testCreateBundleWithFASTQPayloadDoesNotWriteADerivedManifest() async throws {
        // FASTQ bundles must keep working exactly as before: payload at top
        // level, resolved by resolvePrimaryFASTQURL, no derived manifest.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("read-extract-fastq-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fastq = root.appendingPathComponent("selected.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)

        let service = ReadExtractionService()
        let bundleURL = try await service.createBundle(
            from: ExtractionResult(fastqURLs: [fastq], readCount: 1, pairedEnd: false),
            sourceName: "fixture",
            selectionDescription: "fastq-selection",
            metadata: ExtractionMetadata(sourceDescription: "fixture", toolName: "test"),
            in: root
        )

        XCTAssertNil(
            FASTQBundle.loadDerivedManifest(in: bundleURL),
            "FASTQ payload bundles must remain manifest-free physical bundles"
        )
        XCTAssertEqual(
            FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)?.lastPathComponent,
            "selected.fastq"
        )
    }

    func testCreateBundleLeavesNoPartialBundleWhenAPayloadIsMissing() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("read-extract-partial-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Point at a payload that does not exist so the move step throws.
        let missing = root.appendingPathComponent("does-not-exist.fastq")

        let service = ReadExtractionService()
        do {
            _ = try await service.createBundle(
                from: ExtractionResult(fastqURLs: [missing], readCount: 1, pairedEnd: false),
                sourceName: "fixture",
                selectionDescription: "doomed",
                metadata: ExtractionMetadata(sourceDescription: "fixture", toolName: "test"),
                in: root
            )
            XCTFail("Expected createBundle to throw when the payload is missing")
        } catch {
            // expected
        }

        let leftovers = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == FASTQBundle.directoryExtension }
        XCTAssertTrue(
            leftovers.isEmpty,
            "A failed createBundle must not leave a partial bundle behind: \(leftovers.map(\.lastPathComponent))"
        )
    }

    // MARK: - ReadIDBAMExtractionConfig.flagFilter (pure, no I/O)

    private func makeBAMConfig(
        includeSecondary: Bool = false,
        excludeDuplicates: Bool = false
    ) -> ReadIDBAMExtractionConfig {
        ReadIDBAMExtractionConfig(
            bamURL: URL(fileURLWithPath: "/tmp/fake.bam"),
            readIDs: ["read1"],
            includeSecondary: includeSecondary,
            excludeDuplicates: excludeDuplicates,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            outputBaseName: "out"
        )
    }

    func testDefaultFlagFilterExcludesSecondaryAndSupplementaryOnly() {
        // Bio gate: -F 0x900 default, dedup OFF by default.
        XCTAssertEqual(makeBAMConfig().flagFilter, 0x900)
    }

    func testIncludeSecondaryDropsTheSecondarySupplementaryFilterBits() {
        XCTAssertEqual(makeBAMConfig(includeSecondary: true).flagFilter, 0)
    }

    func testExcludeDuplicatesAddsTheDuplicateFilterBit() {
        XCTAssertEqual(makeBAMConfig(excludeDuplicates: true).flagFilter, 0x900 | 0x400)
    }

    func testIncludeSecondaryAndExcludeDuplicatesCombinedFilter() {
        XCTAssertEqual(
            makeBAMConfig(includeSecondary: true, excludeDuplicates: true).flagFilter,
            0x400
        )
    }
}
