import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class FASTAOperationCatalogTests: XCTestCase {
    func testCatalogOnlyReturnsFASTACompatibleOperations() {
        let ids = Set(FASTAOperationCatalog.availableOperationKinds().map(\.rawValue))

        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.searchMotif.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.orient.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.adapterTrim.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.primerRemoval.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.demultiplex.rawValue))
        XCTAssertTrue(ids.contains(FASTQDerivativeOperationKind.humanReadScrub.rawValue))
        XCTAssertFalse(ids.contains(FASTQDerivativeOperationKind.qualityTrim.rawValue))
    }

    func testDialogStateLimitsFASTACompatibleToolsToTheSelectedCategory() throws {
        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">seq1\nAACCGGTT\n"],
            suggestedName: "seq1",
            projectURL: nil
        )
        let searchState = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [bundleURL]
        )
        let mappingState = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [bundleURL]
        )
        let classificationState = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [bundleURL]
        )

        XCTAssertTrue(searchState.isFASTAInputMode)
        XCTAssertEqual(
            Set(searchState.sidebarItems.map(\.id)),
            Set([
                FASTQOperationToolID.subsampleByProportion.rawValue,
                FASTQOperationToolID.subsampleByCount.rawValue,
                FASTQOperationToolID.extractReadsByID.rawValue,
                FASTQOperationToolID.extractReadsByMotif.rawValue,
                FASTQOperationToolID.selectReadsBySequence.rawValue,
            ])
        )
        XCTAssertEqual(
            Set(mappingState.sidebarItems.map(\.id)),
            Set([
                FASTQOperationToolID.minimap2.rawValue,
                FASTQOperationToolID.bwaMem2.rawValue,
                FASTQOperationToolID.bowtie2.rawValue,
                FASTQOperationToolID.bbmap.rawValue,
            ])
        )
        XCTAssertEqual(
            Set(classificationState.sidebarItems.map(\.id)),
            Set([
                FASTQOperationToolID.kraken2.rawValue,
                FASTQOperationToolID.esViritu.rawValue,
                FASTQOperationToolID.taxTriage.rawValue,
            ])
        )
        XCTAssertEqual(searchState.dialogTitle, "FASTQ/FASTA Operations")
    }

    func testDialogStateAllowsSelectingManagedFASTATools() throws {
        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">seq1\nAACCGGTT\n"],
            suggestedName: "seq1",
            projectURL: nil
        )
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [bundleURL]
        )

        state.selectTool(.adapterRemoval)
        XCTAssertEqual(state.selectedToolID, .adapterRemoval)

        state.selectTool(.minimap2)
        XCTAssertEqual(state.selectedToolID, .minimap2)

        state.selectTool(.spades)
        XCTAssertEqual(state.selectedToolID, .spades)

        state.selectTool(.kraken2)
        XCTAssertEqual(state.selectedToolID, .kraken2)
    }

    func testInputSequenceFormatResolvesReferenceBundleAsFASTA() throws {
        let bundleURL = try makeReferenceBundle(
            named: "lungfish-reference",
            fastaFilename: "genome/sequence.fa.gz"
        )

        XCTAssertEqual(FASTAOperationCatalog.inputSequenceFormat(for: bundleURL), .fasta)
    }

    func testTemporaryInputBundleNormalizesVisibleSelectionAndWritesCanonicalRootProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fasta-operation-provenance-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durableSource = root.appendingPathComponent("Savont results.fasta")
        try ">first\nAC\n>second\nTTAA\n".write(to: durableSource, atomically: true, encoding: .utf8)

        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">second\r\nTTAA", ">first\nAC\n"],
            suggestedName: "visible selection",
            projectURL: root,
            durableSourceURLs: [durableSource]
        )

        let payloadURL = bundleURL.appendingPathComponent("selection.fasta")
        XCTAssertEqual(try String(contentsOf: payloadURL, encoding: .utf8), ">second\nTTAA\n>first\nAC\n")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app selected fasta materialization")
        XCTAssertEqual(envelope.output?.path, payloadURL.path)
        XCTAssertEqual(envelope.output?.fileSize, UInt64(23))
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.resolvedDefaults["recordCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["baseCount"], .integer(6))
        XCTAssertEqual(envelope.options.explicit["selectedSequenceIDs"], .array([.string("second"), .string("first")]))
        XCTAssertEqual(envelope.options.explicit["selectedSequenceCount"], .integer(2))
        XCTAssertTrue(envelope.files.contains { $0.path == durableSource.path && $0.role == .input })
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
        XCTAssertEqual(
            envelope.steps.first?.argv,
            [
                "Lungfish Genome Explorer", "fasta-selection-materialization",
                "--source", durableSource.path,
                "--sequence-id", "second",
                "--sequence-id", "first",
                "--output", payloadURL.path,
            ]
        )
        XCTAssertEqual(
            envelope.steps.first?.durableReplayArgv,
            [
                "lungfish-cli", "extract", "contigs",
                "--contigs", durableSource.path,
                "--contig", "second",
                "--contig", "first",
                "--output", payloadURL.path,
            ]
        )
    }

    func testTemporaryInputBundleRecordsDurableBundleDirectoryWithManifestChecksumAndSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fasta-operation-directory-provenance-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durableBundle = root.appendingPathComponent("input.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: durableBundle, withIntermediateDirectories: true)
        try "payload".write(
            to: durableBundle.appendingPathComponent("sequence.fasta"),
            atomically: true,
            encoding: .utf8
        )

        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">selected\nACGT\n"],
            suggestedName: "selected",
            projectURL: root,
            durableSourceURLs: [durableBundle]
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        let descriptor = try XCTUnwrap(envelope.files.first { $0.path == durableBundle.path })
        XCTAssertEqual(descriptor.originPath, durableBundle.standardizedFileURL.path)
        XCTAssertEqual(descriptor.format, .unknown)
        XCTAssertNotNil(descriptor.checksumSHA256)
        XCTAssertEqual(descriptor.fileSize, UInt64(7))
    }

    func testTemporaryInputBundleUsesSessionTemporaryStorageInsteadOfProjectStorage() throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fasta-operation-project-\(UUID().uuidString).lungfish",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">selected\nACGT\n"],
            suggestedName: "selected",
            projectURL: projectURL
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        XCTAssertTrue(bundleURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(bundleURL.path.hasPrefix(ProjectTempDirectory.tempRoot(for: projectURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectTempDirectory.tempRoot(for: projectURL).path))
    }

    func testTemporaryInputBundleIsRegisteredBeforeItIsReturnedAndSupportsSynchronousTerminationCleanup() throws {
        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">selected\nACGT\n"],
            suggestedName: "selected",
            projectURL: nil
        )
        let temporaryRoot = bundleURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path))

        XCTAssertTrue(TempFileManager.shared.isSessionTempDirectoryRegistered(temporaryRoot))
        TempFileManager.shared.cleanupTempDirectorySynchronously(temporaryRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.path))
    }

    func testTemporaryInputBundleRemovesWholeSessionRootWhenMaterializationFails() throws {
        let systemTemp = FileManager.default.temporaryDirectory
        let before = try Set(
            FileManager.default.contentsOfDirectory(atPath: systemTemp.path)
                .filter { $0.hasPrefix("lungfish-fasta-ops-") }
        )

        XCTAssertThrowsError(
            try FASTAOperationCatalog.createTemporaryInputBundle(
                fastaRecords: [">selected\nACGT\n"],
                suggestedName: String(repeating: "x", count: 1_024),
                projectURL: nil
            )
        )

        let after = try Set(
            FileManager.default.contentsOfDirectory(atPath: systemTemp.path)
                .filter { $0.hasPrefix("lungfish-fasta-ops-") }
        )
        XCTAssertEqual(after, before)
    }

    private func makeReferenceBundle(
        named bundleName: String,
        fastaFilename: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "fasta-operation-catalog-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleURL = root.appendingPathComponent("\(bundleName).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
        try FileManager.default.createDirectory(
            at: fastaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ">contig1\nAACCGGTT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try "contig1\t8\t9\t8\t9\n".write(
            to: bundleURL.appendingPathComponent("\(fastaFilename).fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: bundleName,
            identifier: "org.lungfish.\(bundleName)",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: fastaFilename,
                indexPath: "\(fastaFilename).fai",
                totalLength: 8,
                chromosomes: []
            )
        )
        try manifest.save(to: bundleURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return bundleURL
    }
}
