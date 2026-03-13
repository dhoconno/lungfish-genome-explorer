import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexingPipelineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempBundle(
        named name: String = "input",
        fastqFilename: String = "reads.fastq"
    ) throws -> (tempDir: URL, bundleURL: URL, fastqURL: URL) {
        let tempDir = try makeTempDir()
        let bundleURL = tempDir.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent(fastqFilename)
        return (tempDir, bundleURL, fastqURL)
    }

    private func writeFASTQ(sequences: [String], to url: URL) throws {
        var lines: [String] = []
        lines.reserveCapacity(sequences.count * 4)
        for (idx, sequence) in sequences.enumerated() {
            lines.append("@read_\(idx)")
            lines.append(sequence)
            lines.append("+")
            lines.append(String(repeating: "I", count: sequence.count))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - NativeTool.cutadapt Registration

    func testCutadaptRegistered() {
        XCTAssertEqual(NativeTool.cutadapt.executableName, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.relativeExecutablePath, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.sourcePackage, "cutadapt")
        XCTAssertEqual(NativeTool.cutadapt.license, "MIT License")
        XCTAssertFalse(NativeTool.cutadapt.isBBToolsShellScript)
        XCTAssertFalse(NativeTool.cutadapt.isHtslib)
    }

    func testCutadaptInBundledVersions() {
        XCTAssertEqual(NativeToolRunner.bundledVersions["cutadapt"], "4.9")
    }

    func testCutadaptInCaseIterable() {
        XCTAssertTrue(NativeTool.allCases.contains(.cutadapt))
    }

    func testCutadaptExecutableSmokeTest() async throws {
        let runner = NativeToolRunner.shared
        let path = try await runner.findTool(.cutadapt)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: path.path),
            "cutadapt should resolve to an executable: \(path.path)"
        )

        let result = try await runner.run(.cutadapt, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "cutadapt --version should succeed")
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.contains("4."), "Expected cutadapt version output, got: \(output)")
    }

    // MARK: - DemultiplexConfig

    func testDemultiplexConfigDefaults() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.truseqSingleA,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertEqual(config.barcodeLocation, .bothEnds)
        XCTAssertEqual(config.errorRate, 0.10, accuracy: 0.001)
        XCTAssertEqual(config.minimumOverlap, 5)
        XCTAssertTrue(config.trimBarcodes)
        XCTAssertEqual(config.threads, 4)
    }

    // MARK: - DemultiplexError

    func testDemultiplexErrorDescriptions() {
        let errors: [DemultiplexError] = [
            .inputFileNotFound(URL(fileURLWithPath: "/tmp/test.fastq")),
            .cutadaptFailed(exitCode: 1, stderr: "error message"),
            .noBarcodes,
            .combinatorialRequiresSampleAssignments,
            .outputParsingFailed("bad json"),
            .bundleCreationFailed(barcode: "D701", underlying: "test error"),
            .noOutputResults,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
        }
    }

    // MARK: - Pipeline Instantiation

    func testPipelineCanBeInstantiated() {
        let pipeline = DemultiplexingPipeline()
        XCTAssertNotNil(pipeline)
    }

    func testCanonicalAdapterNameStripsCutadaptDuplicateSuffixes() {
        let pipeline = DemultiplexingPipeline()
        XCTAssertEqual(pipeline.canonicalAdapterName("bc1002--bc1070;1"), "bc1002--bc1070")
        XCTAssertEqual(pipeline.canonicalAdapterName("bc1002--bc1070;2"), "bc1002--bc1070")
        XCTAssertEqual(pipeline.canonicalAdapterName("bc1002--bc1070"), "bc1002--bc1070")
        XCTAssertEqual(pipeline.canonicalAdapterName("sample;rev"), "sample;rev")
    }

    // MARK: - DemultiplexConfig Custom Location

    func testDemultiplexConfigBothEndsLocation() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.truseqSingleA,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            barcodeLocation: .bothEnds,
            errorRate: 0.2,
            minimumOverlap: 5,
            trimBarcodes: false,
            unassignedDisposition: .discard,
            threads: 8
        )

        XCTAssertEqual(config.barcodeLocation, .bothEnds)
        XCTAssertEqual(config.errorRate, 0.2, accuracy: 0.001)
        XCTAssertEqual(config.minimumOverlap, 5)
        XCTAssertFalse(config.trimBarcodes)
        XCTAssertEqual(config.threads, 8)
    }

    // MARK: - resolvedAdapterContext

    func testResolvedAdapterContextDefaultsToKit() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.ontNativeBarcoding24,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertNil(config.adapterContext)
        XCTAssertTrue(config.resolvedAdapterContext is ONTNativeAdapterContext)
    }

    func testResolvedAdapterContextUsesOverride() {
        let override = IlluminaTruSeqAdapterContext()
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.ontNativeBarcoding24,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            adapterContext: override
        )

        XCTAssertNotNil(config.adapterContext)
        // Override should win over kit default (ONTNative → IlluminaTruSeq)
        XCTAssertTrue(config.resolvedAdapterContext is IlluminaTruSeqAdapterContext)
    }

    func testSymmetryModeDefaultsFromPairingMode() {
        // ONT native → symmetric
        let ontConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.ontNativeBarcoding24,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        XCTAssertEqual(ontConfig.symmetryMode, .symmetric)

        // Illumina fixedDual → asymmetric
        let illConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.truseqHTDual,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        XCTAssertEqual(illConfig.symmetryMode, .asymmetric)

        // ONT rapid → singleEnd
        let rapidConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.ontRapidBarcoding12,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        XCTAssertEqual(rapidConfig.symmetryMode, .singleEnd)
    }

    func testSymmetryModeCanBeOverridden() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.ontNativeBarcoding24,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            symmetryMode: .asymmetric
        )
        XCTAssertEqual(config.symmetryMode, .asymmetric)
    }

    func testFixedDualLinkedAdaptersMatchBothOrientations() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                "ACGTACGTAAAAAATGCATGCA",   // i7 ... i5
                "TGCATGCATTTTTTACGTACGT",   // i5 ... i7 (swapped orientation)
                "GGGGGGGGCCCCCCCC",         // unassigned
            ],
            to: inputFASTQ
        )

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitDefinition(
            id: "fixed-dual-test",
            displayName: "Fixed Dual Test",
            vendor: "custom",
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                BarcodeEntry(id: "P01", i7Sequence: "ACGTACGT", i5Sequence: "TGCATGCA"),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 8,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 3)
        XCTAssertEqual(result.manifest.barcodes.count, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.barcodeID, "P01")
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 2)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
    }

    func testVirtualDemuxPreservesInterleavedPairingModeFromBundleMetadata() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeFASTQ(
            sequences: [
                "ACGTAAAAAA",
                "GGGGGGGGGG",
            ],
            to: fastqURL
        )

        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(
                    isClumpified: false,
                    isCompressed: false,
                    pairingMode: .interleaved,
                    originalFilenames: [fastqURL.lastPathComponent]
                )
            ),
            for: fastqURL
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitDefinition(
            id: "single-test",
            displayName: "Single Test",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: bundleURL,
                barcodeKit: kit,
                outputDirectory: outputDir,
                errorRate: 0.0,
                minimumOverlap: 4,
                trimBarcodes: true,
                threads: 1,
                rootBundleURL: bundleURL,
                rootFASTQFilename: fastqURL.lastPathComponent
            ),
            progress: { _, _ in }
        )

        let derivedManifests = result.outputBundleURLs.compactMap(FASTQBundle.loadDerivedManifest(in:))
        XCTAssertEqual(derivedManifests.count, 1)
        XCTAssertEqual(derivedManifests.first?.pairingMode, .interleaved)
    }

    func testVirtualSymmetricDemuxCachesStatisticsFromCanonicalTrimmedSequence() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let kit = BarcodeKitRegistry.ontNativeBarcoding24
        guard let barcode = kit.barcodes.first(where: { $0.id == "barcode13" }) else {
            XCTFail("Expected barcode13 in ONT native kit")
            return
        }

        let context = ONTNativeAdapterContext()
        let insert = "GATTACA"
        let sequence =
            context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
            + insert
            + context.threePrimeSpec(barcodeSequence: barcode.i7Sequence)

        try writeFASTQ(sequences: [sequence], to: fastqURL)

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: bundleURL,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 20,
                trimBarcodes: true,
                threads: 1,
                rootBundleURL: bundleURL,
                rootFASTQFilename: fastqURL.lastPathComponent
            ),
            progress: { _, _ in }
        )

        guard let barcodeBundle = result.outputBundleURLs.first(where: { $0.lastPathComponent == "barcode13.lungfishfastq" }) else {
            XCTFail("Expected barcode13 output bundle")
            return
        }
        guard let manifest = FASTQBundle.loadDerivedManifest(in: barcodeBundle) else {
            XCTFail("Expected derived manifest in barcode13 bundle")
            return
        }

        let previewURL = barcodeBundle.appendingPathComponent("preview.fastq.gz")
        let previewLines = try String(contentsOf: previewURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(previewLines.count, 2)

        let previewLength = previewLines[1].count
        XCTAssertLessThan(previewLength, sequence.count)
        XCTAssertEqual(manifest.cachedStatistics.readCount, 1)
        XCTAssertEqual(manifest.cachedStatistics.meanReadLength, Double(previewLength), accuracy: 0.001)
        XCTAssertEqual(manifest.cachedStatistics.minReadLength, previewLength)
        XCTAssertEqual(manifest.cachedStatistics.maxReadLength, previewLength)
        XCTAssertEqual(manifest.cachedStatistics.readLengthHistogram, [previewLength: 1])
    }

    // MARK: - Poly-G Trim Config

    func testPolyGTrimDefaultsFromPlatform() {
        let illuminaKit = BarcodeKitDefinition(
            id: "test-illumina",
            displayName: "Test Illumina",
            vendor: "illumina",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        // Illumina platform defaults to poly-G trim quality 20
        XCTAssertEqual(config.polyGTrimQuality, 20)
    }

    func testPolyGTrimNilForONT() {
        let ontKit = BarcodeKitDefinition(
            id: "test-ont",
            displayName: "Test ONT",
            vendor: "oxford_nanopore",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: ontKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        XCTAssertNil(config.polyGTrimQuality)
    }

    func testPolyGTrimExplicitOverride() {
        let ontKit = BarcodeKitDefinition(
            id: "test-ont",
            displayName: "Test ONT",
            vendor: "oxford_nanopore",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )
        // Force poly-G trimming even on ONT (unusual but user-configurable)
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: ontKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            polyGTrimQuality: 15
        )
        XCTAssertEqual(config.polyGTrimQuality, 15)
    }

    func testPolyGTrimElementDefaults() {
        let elementKit = BarcodeKitDefinition(
            id: "test-element",
            displayName: "Test Element",
            vendor: "element",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: elementKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        XCTAssertEqual(config.polyGTrimQuality, 20)
    }

    // MARK: - P0 Regression Tests (Phase 1)

    /// Adapter FASTA content would be non-empty for all built-in kits.
    /// Validates that every kit's adapter context produces valid linked specs
    /// and that no barcode sequence is empty.
    func testAdapterFASTAContentNonEmptyForAllKits() {
        let kits = BarcodeKitRegistry.builtinKits()

        for kit in kits {
            // Skip combinatorial kits — they require explicit sample assignments
            if kit.pairingMode == .combinatorialDual { continue }

            let context = kit.adapterContext
            for barcode in kit.barcodes {
                XCTAssertFalse(
                    barcode.i7Sequence.isEmpty,
                    "Barcode \(barcode.id) in kit \(kit.displayName) should have non-empty i7 sequence"
                )

                // For long-read platforms, test linked spec
                if kit.platform.readsCanBeReverseComplemented {
                    let spec = context.linkedSpec(barcodeSequence: barcode.i7Sequence)
                    XCTAssertFalse(
                        spec.isEmpty,
                        "Linked spec should not be empty for \(kit.displayName) barcode \(barcode.id)"
                    )
                    // Verify no empty segments around the ... separator
                    let parts = spec.components(separatedBy: "...")
                    for (idx, part) in parts.enumerated() {
                        XCTAssertFalse(
                            String(part).trimmingCharacters(in: .whitespaces).isEmpty,
                            "Linked spec part \(idx) should not be empty for \(kit.displayName) \(barcode.id)"
                        )
                    }
                }
            }
        }
    }

    /// DemultiplexError.emptyAdapterSequences has a description.
    func testEmptyAdapterSequencesErrorDescription() {
        let error = DemultiplexError.emptyAdapterSequences(kitName: "Test Kit")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Test Kit") ?? false)
    }

    /// Resolved adapter context returns correct type per kit platform.
    func testResolvedAdapterContextForAllBuiltinKits() {
        let kits = BarcodeKitRegistry.builtinKits()
        for kit in kits {
            let config = DemultiplexConfig(
                inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
                barcodeKit: kit,
                outputDirectory: URL(fileURLWithPath: "/tmp/output")
            )
            let ctx = config.resolvedAdapterContext
            switch kit.vendor {
            case "oxford-nanopore":
                switch kit.kitType {
                case .rapidBarcoding:
                    XCTAssertTrue(ctx is ONTRapidAdapterContext,
                                  "ONT rapid kit \(kit.id) should have ONTRapidAdapterContext")
                default:
                    // nativeBarcoding, pcrBarcoding, sixteenS all use ONTNativeAdapterContext
                    XCTAssertTrue(ctx is ONTNativeAdapterContext,
                                  "ONT kit \(kit.id) (type: \(kit.kitType)) should have ONTNativeAdapterContext")
                }
            case "illumina":
                XCTAssertTrue(ctx is IlluminaTruSeqAdapterContext || ctx is IlluminaNexteraAdapterContext,
                              "Illumina kit \(kit.id) should have Illumina adapter context")
            case "pacbio":
                XCTAssertTrue(ctx is PacBioAdapterContext || ctx is PacBioM13AdapterContext,
                              "PacBio kit \(kit.id) should have PacBio adapter context")
            default:
                break
            }
        }
    }

    // MARK: - P1 Tests (Phase 2)

    /// Combinatorial dual kits without sample assignments should throw.
    func testCombinatorialDualWithoutAssignmentsThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(sequences: ["ACGTACGTACGTACGT"], to: inputFASTQ)

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitDefinition(
            id: "combo-test",
            displayName: "Combinatorial Test",
            vendor: "custom",
            isDualIndexed: true,
            pairingMode: .combinatorialDual,
            barcodes: [
                BarcodeEntry(id: "F01", i7Sequence: "ACGTACGT"),
                BarcodeEntry(id: "R01", i7Sequence: "TGCATGCA"),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        do {
            _ = try await pipeline.run(
                config: DemultiplexConfig(
                    inputURL: inputFASTQ,
                    barcodeKit: kit,
                    outputDirectory: outputDir,
                    threads: 1
                ),
                progress: { _, _ in }
            )
            XCTFail("Should have thrown for combinatorial kit without assignments")
        } catch let error as DemultiplexError {
            switch error {
            case .combinatorialRequiresSampleAssignments:
                break // Expected
            default:
                XCTFail("Expected combinatorialRequiresSampleAssignments, got \(error)")
            }
        }
    }

    // MARK: - P2 Tests

    /// Poly-G trim config produces correct effective quality value.
    func testPolyGTrimConfigFlowsToEffectiveRate() {
        let illuminaKit = BarcodeKitDefinition(
            id: "test-illumina-polyg",
            displayName: "Test Illumina PolyG",
            vendor: "illumina",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )

        // Default: Illumina gets polyG = 20
        let defaultConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        XCTAssertEqual(defaultConfig.polyGTrimQuality, 20)

        // Explicit override
        let overrideConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            polyGTrimQuality: 30
        )
        XCTAssertEqual(overrideConfig.polyGTrimQuality, 30)

        // Explicit nil disables
        let disabledConfig = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            polyGTrimQuality: 0
        )
        XCTAssertEqual(disabledConfig.polyGTrimQuality, 0)
    }

    /// Cross-platform error rate: effectiveErrorRate uses max of kit and source platform.
    func testEffectiveErrorRateCrossPlatform() {
        let illuminaKit = BarcodeKitDefinition(
            id: "test-cross-plat",
            displayName: "Cross Platform Test",
            vendor: "illumina",
            barcodes: [BarcodeEntry(id: "BC01", i7Sequence: "ACGT")]
        )

        // No source platform: uses kit error rate as-is
        let config1 = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            errorRate: 0.1
        )
        XCTAssertEqual(config1.effectiveErrorRate, 0.1, accuracy: 0.001)

        // Same platform: no adjustment
        let config2 = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/input.fastq"),
            barcodeKit: illuminaKit,
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            errorRate: 0.1,
            sourcePlatform: .illumina
        )
        XCTAssertEqual(config2.effectiveErrorRate, 0.1, accuracy: 0.001)
    }
}
