import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexingPipelineTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexingPipelineTests-\(UUID().uuidString).lungfish", isDirectory: true)
        let dir = projectDir.appendingPathComponent("workspace", isDirectory: true)
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

    private func makeManagedTool(
        root: URL,
        environment: String,
        executable: String,
        script: String
    ) throws {
        let executableDir = root
            .appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)
        let executableURL = executableDir.appendingPathComponent(executable)
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
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

    func testCutadaptInManagedToolLock() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let cutadapt = try XCTUnwrap(lock.tools.first(where: { $0.id == "cutadapt" }))
        XCTAssertEqual(try XCTUnwrap(cutadapt.version), "5.2")
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
        let lock = try ManagedToolLock.loadFromBundle()
        let cutadapt = try XCTUnwrap(lock.tools.first(where: { $0.id == "cutadapt" }))
        XCTAssertTrue(output.contains(try XCTUnwrap(cutadapt.version)), "Expected cutadapt version output, got: \(output)")
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
            .exactBareBarcodeUnsupported,
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
        XCTAssertEqual(pipeline.canonicalAdapterName("32286-059_DP08__lge_forward"), "32286-059_DP08")
        XCTAssertEqual(pipeline.canonicalAdapterName("32286-059_DP08__lge_reverse_complement"), "32286-059_DP08")
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

    func testFluidigmDefaultsToSymmetricBareLongReadDemux() {
        let config = DemultiplexConfig(
            inputURL: URL(fileURLWithPath: "/tmp/test.fastq.gz"),
            barcodeKit: BarcodeKitRegistry.fluidigmAccessArray,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertEqual(config.symmetryMode, .symmetric)
        XCTAssertTrue(config.searchReverseComplement)
        XCTAssertTrue(config.resolvedAdapterContext is BareAdapterContext)
        XCTAssertEqual(config.effectiveMinimumOverlap, 6)
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
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

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

    func testCustomFixedDualKitMatchesObservedBarcodePairInsideONTWrapper() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let forward = "CTATACGTATATCTAT"
        let reverse = "CACTCACGTGTGATAT"
        let ontLeft = "TTACGTATTGCTAAGGTTAAAGAACGACTTCCATACTCGTGTGACAGCACCT"
        let ontRight = "AGGTGCTGTCACACAGTTGTGGAAGTAGGCTTCTTAACCTTAGCAAT"

        try writeFASTQ(
            sequences: [
                ontLeft + forward + "GATTACAGATTACAGATTACA" + reverse + ontRight,
                ontLeft + PlatformAdapters.reverseComplement(reverse) + "GATTACAGATTACAGATTACA"
                    + PlatformAdapters.reverseComplement(forward) + ontRight,
                ontLeft + "GGGGGGGGGGGGGGGG" + "GATTACA" + reverse + ontRight,
            ],
            to: inputFASTQ
        )

        let kit = BarcodeKitDefinition(
            id: "custom-fluidigm-pair",
            displayName: "Custom Fluidigm Pair",
            vendor: "custom",
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                BarcodeEntry(id: "32286-059_DP08", i7Sequence: forward, i5Sequence: reverse),
            ]
        )

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 16,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 3)
        XCTAssertEqual(result.manifest.barcodes.count, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.barcodeID, "32286-059_DP08")
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 2)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
        let nativeCommand = try XCTUnwrap(result.nativeCommand)
        XCTAssertTrue(nativeCommand.contains("--quiet"))
        XCTAssertTrue(nativeCommand.contains { $0.contains("{name}.fastq") })
        XCTAssertFalse(nativeCommand.contains { $0.contains("{name}.fastq.gz") })
    }

    func testVirtualDemuxPreservesInterleavedPairingModeFromBundleMetadata() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

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

    func testExactVirtualDemuxFailsClosedWhenDerivedManifestCannotBeWritten() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let forward = "ACGTACGT"
        let reverse = "TGCATGCA"
        let insert = "GATTACA"
        let sequence = forward + insert + PlatformAdapters.reverseComplement(reverse)
        try writeFASTQ(sequences: [sequence], to: fastqURL)

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let blockedBundleURL = outputDir
            .appendingPathComponent("sample1.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blockedBundleURL.appendingPathComponent(FASTQBundle.derivedManifestFilename),
            withIntermediateDirectories: true
        )

        let kit = BarcodeKitDefinition(
            id: "exact-derived-manifest-failure",
            displayName: "Exact Derived Manifest Failure",
            vendor: "custom",
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [
                BarcodeEntry(id: "PAIR1", i7Sequence: forward, i5Sequence: reverse),
            ]
        )

        do {
            _ = try await DemultiplexingPipeline().run(
                config: DemultiplexConfig(
                    inputURL: bundleURL,
                    barcodeKit: kit,
                    outputDirectory: outputDir,
                    errorRate: 0.0,
                    minimumOverlap: 4,
                    trimBarcodes: true,
                    threads: 1,
                    sampleAssignments: [
                        FASTQSampleBarcodeAssignment(
                            sampleID: "sample1",
                            forwardSequence: forward,
                            reverseSequence: reverse
                        ),
                    ],
                    rootBundleURL: bundleURL,
                    rootFASTQFilename: fastqURL.lastPathComponent,
                    minimumInsert: insert.count
                ),
                progress: { _, _ in }
            )
            XCTFail("Demux should fail when a required derived manifest cannot be saved.")
        } catch let error as DemultiplexError {
            guard case .bundleCreationFailed(let barcode, _) = error else {
                XCTFail("Expected bundleCreationFailed, got \(error)")
                return
            }
            XCTAssertEqual(barcode, "sample1")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: blockedBundleURL.path),
                "A demux bundle without its required derived manifest must be removed."
            )
        } catch {
            XCTFail("Expected DemultiplexError.bundleCreationFailed, got \(error)")
        }
    }

    func testVirtualSymmetricDemuxCachesStatisticsFromCanonicalTrimmedSequence() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

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

        let previewURL = barcodeBundle.appendingPathComponent("preview.fastq")
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

    func testSingleEndExplicitAssignmentsDoNotRequireBothEnds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitRegistry.ontNativeBarcoding24
        let barcode = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode13" }))
        let context = ONTNativeAdapterContext()
        let sequence = context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence) + "GATTACAGATTACA"
        try writeFASTQ(sequences: [sequence], to: inputFASTQ)

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                symmetryMode: .singleEnd,
                errorRate: 0.0,
                minimumOverlap: 20,
                trimBarcodes: true,
                threads: 1,
                sampleAssignments: [
                    FASTQSampleBarcodeAssignment(
                        sampleID: "sample13",
                        forwardBarcodeID: "barcode13"
                    )
                ]
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.barcodes.count, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.barcodeID, "sample13")
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 1)
        XCTAssertFalse(result.manifest.parameters.requireBothEnds)
        XCTAssertEqual(result.manifest.barcodeKit.barcodeType, BarcodeType.singleEnd)
        XCTAssertFalse(result.manifest.barcodeKit.isDualIndexed)
    }

    func testCustomBareBarcodeWindowDemuxFindsReverseComplementInOrientedReads() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let fld0001 = "GTATCGTCGT"
        let fld0001RC = PlatformAdapters.reverseComplement(fld0001)
        let fld0002 = "GTGTATGCGT"
        let fld0002RC = PlatformAdapters.reverseComplement(fld0002)
        let outerONTContext = "AAGGTTACACAAACCCTGGACAAGCAGCACCT"

        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                outerONTContext + String(repeating: "A", count: 24) + fld0001RC + "GATTACA",
                outerONTContext + String(repeating: "C", count: 38) + fld0002RC + "GATTACA",
                outerONTContext + String(repeating: "T", count: 90),
            ],
            to: inputFASTQ
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "FLD0001", i7Sequence: fld0001),
                BarcodeEntry(id: "FLD0002", i7Sequence: fld0002),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .fivePrime,
                errorRate: 0.15,
                minimumOverlap: 3,
                maxDistanceFrom5Prime: 100,
                trimBarcodes: true,
                searchReverseComplement: true,
                threads: 1,
                engine: .exactBareBarcode
            ),
            progress: { _, _ in }
        )

        XCTAssertNil(result.nativeCommand, "Exact bare-barcode demux should not invoke cutadapt")
        XCTAssertEqual(result.manifest.parameters.tool, "exact-bare-barcode-demux")
        XCTAssertEqual(result.manifest.inputReadCount, 3)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.readCount, 1)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0002" })?.readCount, 1)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)

        let fld0001Bundle = outputDir.appendingPathComponent("FLD0001.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let readIDs = try String(
            contentsOf: fld0001Bundle.appendingPathComponent("read-ids.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(readIDs.trimmingCharacters(in: .whitespacesAndNewlines), "read_0")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fld0001Bundle.appendingPathComponent("trim-positions.tsv").path),
            "Exact bare-barcode demux scans whole reads and preserves sequences instead of recording terminal trim offsets."
        )
    }

    func testExactBareBarcodeDemuxScansWholeReadAndPreservesSequence() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let fld0001 = "GTATCGTCGT"
        let fld0001RC = PlatformAdapters.reverseComplement(fld0001)
        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                "AAAAA" + fld0001 + "CCCCCGGGGG",
                "TTTTT" + fld0001RC + "GGGGGCCCCC",
                "AAAAAAAAAACCCCCCCCCC",
            ],
            to: inputFASTQ
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "FLD0001", i7Sequence: fld0001),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                trimBarcodes: true,
                threads: 1,
                engine: .exactBareBarcode
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.parameters.tool, "exact-bare-barcode-demux")
        XCTAssertFalse(result.manifest.parameters.trimBarcodes)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.readCount, 2)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)

        let fld0001FASTQ = outputDir
            .appendingPathComponent("FLD0001.\(FASTQBundle.directoryExtension)", isDirectory: true)
            .appendingPathComponent("FLD0001.fastq")
        let output = try String(contentsOf: fld0001FASTQ, encoding: .utf8)
        XCTAssertTrue(output.contains("AAAAA\(fld0001)CCCCCGGGGG"))
        XCTAssertTrue(output.contains("TTTTT\(fld0001RC)GGGGGCCCCC"))
    }

    func testExactBareBarcodeDemuxRecordsThreadCountInCommandLine() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let barcode = "GTATCGTCGT"
        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(sequences: ["AAAAA" + barcode + "CCCCCGGGGG"], to: inputFASTQ)

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [BarcodeEntry(id: "FLD0001", i7Sequence: barcode)]
        )

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                trimBarcodes: true,
                threads: 3,
                engine: .exactBareBarcode
            ),
            progress: { _, _ in }
        )

        let commandLine = try XCTUnwrap(result.manifest.parameters.commandLine)
        XCTAssertTrue(commandLine.contains("--threads 3"), commandLine)
    }

    func testExactBareBarcodeDemuxProcessesMultiFileBundleWithMultipleThreads() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let bundleURL = tempDir.appendingPathComponent("input.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let fld0001 = "GTATCGTCGT"
        let fld0002 = "CATACCTGAT"
        let chunkA = chunksDir.appendingPathComponent("a.fastq")
        let chunkB = chunksDir.appendingPathComponent("b.fastq")
        try """
        @a1
        AAAAA\(fld0001)CCCCC
        +
        IIIIIIIIIIIIIIIIIII
        @a2
        TTTTT\(fld0002)GGGGG
        +
        IIIIIIIIIIIIIIIIIII
        """.appending("\n").write(to: chunkA, atomically: true, encoding: .utf8)
        try """
        @b1
        CCCCC\(fld0001)AAAAA
        +
        IIIIIIIIIIIIIIIIIII
        @b2
        AAAAAAAAAACCCCCCCCCC
        +
        IIIIIIIIIIIIIIIIIIII
        """.appending("\n").write(to: chunkB, atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "files": [
            {
              "filename": "chunks/a.fastq",
              "originalPath": "/tmp/a.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            },
            {
              "filename": "chunks/b.fastq",
              "originalPath": "/tmp/b.fastq",
              "sizeBytes": 1,
              "isSymlink": false
            }
          ]
        }
        """.write(
            to: bundleURL.appendingPathComponent("source-files.json"),
            atomically: true,
            encoding: .utf8
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "FLD0001", i7Sequence: fld0001),
                BarcodeEntry(id: "FLD0002", i7Sequence: fld0002),
            ]
        )

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: bundleURL,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                trimBarcodes: true,
                unassignedDisposition: .keep,
                threads: 2,
                engine: .exactBareBarcode
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 4)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.readCount, 2)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0002" })?.readCount, 1)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)

        let fld0001ReadIDs = try String(
            contentsOf: outputDir
                .appendingPathComponent("FLD0001.\(FASTQBundle.directoryExtension)", isDirectory: true)
                .appendingPathComponent("read-ids.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(fld0001ReadIDs.trimmingCharacters(in: .whitespacesAndNewlines), "a1\nb1")

        let fld0001FASTQ = try String(
            contentsOf: outputDir
                .appendingPathComponent("FLD0001.\(FASTQBundle.directoryExtension)", isDirectory: true)
                .appendingPathComponent("FLD0001.fastq"),
            encoding: .utf8
        )
        XCTAssertTrue(fld0001FASTQ.range(of: "@a1")!.lowerBound < fld0001FASTQ.range(of: "@b1")!.lowerBound)
    }

    func testCustomBareBarcodeDefaultEngineUsesCutadapt() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                "GTATCGTCGTGATTACA",
                "AAAAAAAAAAGATTACA",
            ],
            to: inputFASTQ
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "FLD0001", i7Sequence: "GTATCGTCGT"),
            ]
        )

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 10,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.parameters.tool, "cutadapt")
        XCTAssertNotNil(result.nativeCommand)
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.readCount, 1)
    }

    func testCutadaptFullOutputModeDoesNotBuildVirtualReadIDSidecars() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "input")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        try writeFASTQ(
            sequences: [
                "GTATCGTCGTGATTACA",
                "AAAAAAAAAAGATTACA",
            ],
            to: fastqURL
        )

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-fluidigm-subset",
            displayName: "Custom Fluidigm Subset",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "FLD0001", i7Sequence: "GTATCGTCGT"),
            ]
        )

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: bundleURL,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 10,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        let outputBundleURL = try XCTUnwrap(result.outputBundleURLs.first)
        let barcodeResult = try XCTUnwrap(
            result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })
        )
        XCTAssertEqual(barcodeResult.readCount, 1)
        XCTAssertEqual(barcodeResult.baseCount, 7)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputBundleURL.appendingPathComponent("FLD0001.fastq.gz").path
            ),
            "Full-output demux bundles should keep cutadapt's materialized FASTQ payload."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputBundleURL.appendingPathComponent("read-ids.txt").path),
            "Materialized demux bundles should not build a full read-id sidecar."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputBundleURL.appendingPathComponent("orient-map.tsv").path),
            "Materialized demux bundles should not build a full orientation sidecar."
        )
        XCTAssertNil(
            FASTQBundle.loadDerivedManifest(in: outputBundleURL),
            "Materialized demux bundles should not be virtual derived bundles."
        )
    }

    func testCutadaptMaterializedEmptyFASTQOutputIsTreatedAsEmptyStatistics() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try Data().write(to: inputFASTQ)

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-single-empty",
            displayName: "Custom Single Empty",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "BC01", i7Sequence: "GTATCGTCGT"),
            ]
        )

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 10,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 0)
        XCTAssertEqual(result.manifest.barcodes.reduce(0) { $0 + $1.readCount }, 0)
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)
    }

    func testCutadaptMaterializedHeaderOnlySeqkitStatsForNonemptyOutputFailsInsteadOfZeroCounts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let runnerRoot = dir.appendingPathComponent("managed-tools", isDirectory: true)
        try makeManagedTool(
            root: runnerRoot,
            environment: "cutadapt",
            executable: "cutadapt",
            script: """
            #!/bin/sh
            case "$1" in
              --version|version)
                echo "cutadapt 5.2"
                exit 0
                ;;
            esac
            output_pattern=""
            json_path=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o)
                  output_pattern="$2"
                  shift 2
                  ;;
                --json)
                  json_path="$2"
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done
            sample_output=$(printf '%s' "$output_pattern" | sed 's/{name}/BC01/g')
            mkdir -p "$(dirname "$sample_output")"
            printf 'header-only stats fixture payload\\n' > "$sample_output"
            if [ -n "$json_path" ]; then
              printf '{}' > "$json_path"
            fi
            """
        )
        try makeManagedTool(
            root: runnerRoot,
            environment: "seqkit",
            executable: "seqkit",
            script: """
            #!/bin/sh
            case "$1" in
              version|--version)
                echo "seqkit v2.10.0"
                ;;
              stats)
                printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n'
                ;;
              *)
                echo "unexpected seqkit invocation: $*" >&2
                exit 1
                ;;
            esac
            """
        )

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(sequences: ["GTATCGTCGTGATTACA"], to: inputFASTQ)

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-single-empty-stats",
            displayName: "Custom Single Empty Stats",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "BC01", i7Sequence: "GTATCGTCGT"),
            ]
        )

        do {
            _ = try await DemultiplexingPipeline(
                runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot)
            ).run(
                config: DemultiplexConfig(
                    inputURL: inputFASTQ,
                    barcodeKit: customKit,
                    outputDirectory: outputDir,
                    barcodeLocation: .fivePrime,
                    errorRate: 0.0,
                    minimumOverlap: 10,
                    trimBarcodes: true,
                    threads: 1
                ),
                progress: { _, _ in }
            )
            XCTFail("Persistent header-only seqkit stats for a nonempty output must not be reported as zero reads")
        } catch let error as DemultiplexError {
            guard case .outputParsingFailed(let message) = error else {
                XCTFail("Expected outputParsingFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("seqkit stats produced no data row"))
            XCTAssertTrue(message.contains("BC01.fastq.gz"))
        }
    }

    func testCutadaptMaterializedStatsRetriesEmptySeqkitStdoutForNonemptyOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let runnerRoot = dir.appendingPathComponent("managed-tools", isDirectory: true)
        try makeManagedTool(
            root: runnerRoot,
            environment: "cutadapt",
            executable: "cutadapt",
            script: """
            #!/bin/sh
            case "$1" in
              --version|version)
                echo "cutadapt 5.2"
                exit 0
                ;;
            esac
            output_pattern=""
            json_path=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o)
                  output_pattern="$2"
                  shift 2
                  ;;
                --json)
                  json_path="$2"
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done
            sample_output=$(printf '%s' "$output_pattern" | sed 's/{name}/BC01/g')
            mkdir -p "$(dirname "$sample_output")"
            cat > "$sample_output" <<'FASTQ'
            @read_1
            GATTACA
            +
            IIIIIII
            FASTQ
            if [ -n "$json_path" ]; then
              printf '{}' > "$json_path"
            fi
            """
        )
        try makeManagedTool(
            root: runnerRoot,
            environment: "seqkit",
            executable: "seqkit",
            script: """
            #!/bin/sh
            case "$1" in
              version|--version)
                echo "seqkit v2.10.0"
                ;;
              stats)
                state="$(dirname "$0")/stats-attempts"
                if [ ! -f "$state" ]; then
                  printf 1 > "$state"
                  exit 0
                fi
                printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n'
                printf '%s\\tFASTQ\\tDNA\\t1\\t7\\t7\\t7.0\\t7\\n' "$3"
                ;;
              *)
                echo "unexpected seqkit invocation: $*" >&2
                exit 1
                ;;
            esac
            """
        )

        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(sequences: ["GTATCGTCGTGATTACA"], to: inputFASTQ)

        let outputDir = dir.appendingPathComponent("demux-out", isDirectory: true)
        let customKit = BarcodeKitDefinition(
            id: "custom-single-transient-empty-stats",
            displayName: "Custom Single Transient Empty Stats",
            vendor: "custom",
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: [
                BarcodeEntry(id: "BC01", i7Sequence: "GTATCGTCGT"),
            ]
        )

        let result = try await DemultiplexingPipeline(
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot),
            cutadaptVersionOverride: "5.2"
        ).run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: customKit,
                outputDirectory: outputDir,
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 10,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.manifest.inputReadCount, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 1)
        XCTAssertEqual(result.manifest.barcodes.first?.baseCount, 7)
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
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

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
