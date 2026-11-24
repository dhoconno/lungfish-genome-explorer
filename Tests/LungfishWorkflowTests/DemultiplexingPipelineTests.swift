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
            // A custom dual kit at Both Ends with no sample sheet is searched at the read ends and needs no opt-in
            // (BIO-DUAL-ANCHOR item 6). Its barcodes are their own reverse complements, so the swapped read is also the
            // other strand, and testACustomDualPairIsFoundOnlyWholeAtTheReadEndsOnEitherStrand pins the orientation.
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
            // The pair sits 52 bases from the start of each read and 47 from the end, inside the ONT wrapper, and the lines
            // are anchored at the read ends, so the distances name the wrapper: 53 x 48 x 2 = 5,088 lines, under the cap of
            // 6,000, and no opt-in (BIO-DUAL-ANCHOR items 5 and 6, test vii). Cutadapt spends about 145 s on the lines.
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 16,
                maxDistanceFrom5Prime: ontLeft.count,
                maxDistanceFrom3Prime: ontRight.count,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual([ontLeft.count, ontRight.count], [52, 47])
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

    /// The pair D01 of BIO-DUAL-ANCHOR Q1, whose barcodes are not their own reverse complements, as a custom dual kit.
    private static let anchorI7 = "TGGGCGAA"
    private static let anchorI5 = "AGGAGTTA"
    private static let anchorInsert = "GATTACAGGTCATCGATCAGTTCAGCATGCAAGTC"
    private static var anchorKit: BarcodeKitDefinition {
        BarcodeKitDefinition(
            id: "custom-dual-d01", displayName: "Dual D01", vendor: "custom", isDualIndexed: true, pairingMode: .fixedDual,
            barcodes: [BarcodeEntry(id: "D01", i7Sequence: anchorI7, i5Sequence: anchorI5)]
        )
    }

    /// A custom dual pair whose barcodes are not their own reverse complements, at Both Ends with no sample sheet, is found
    /// only whole at the two ends of a read, on either strand of the molecule (BIO-DUAL-ANCHOR items 1 and 2, test ii, Q1).
    /// A read with the i7 at the start and only 3 bases of the i5 at the end, a read with the pair inside it, and a read
    /// with the pair swapped, which is no strand of the molecule, stay unassigned, with the opt-in and without it. At the
    /// base the lines had no anchor, so cutadapt placed those reads too, and preflight refused the run with no opt-in.
    func testACustomDualPairIsFoundOnlyWholeAtTheReadEndsOnEitherStrand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (i7, i5, insert) = (Self.anchorI7, Self.anchorI5, Self.anchorInsert)
        let forward = i7 + insert + i5
        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                forward,                                      // the pair at the read ends
                PlatformAdapters.reverseComplement(forward),  // the other strand, rc(i5) ... rc(i7)
                i7 + insert + String(i5.prefix(3)),           // 3 bases of the i5 at the end
                "CCGTTAGC" + forward + "GCTAACGG",            // the pair inside the read
                i5 + insert + i7,                             // the pair swapped, no strand of the molecule
            ],
            to: inputFASTQ
        )
        for keepsUncheckedSamples in [true, false] {
            let setting = keepsUncheckedSamples ? "with Keep Unchecked Samples" : "with no opt-in"
            let result = try await DemultiplexingPipeline().run(
                config: DemultiplexConfig(
                    inputURL: inputFASTQ,
                    barcodeKit: Self.anchorKit,
                    outputDirectory: dir.appendingPathComponent("demux-\(keepsUncheckedSamples)", isDirectory: true),
                    barcodeLocation: .bothEnds,
                    errorRate: 0.15,
                    minimumOverlap: 3,
                    trimBarcodes: true,
                    threads: 1,
                    keepsUncheckedSamples: keepsUncheckedSamples
                ),
                progress: { _, _ in }
            )
            XCTAssertEqual(result.manifest.inputReadCount, 5, setting)
            XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["D01"], setting)
            XCTAssertEqual(result.manifest.barcodes.first?.readCount, 2, setting)
            XCTAssertEqual(result.manifest.unassigned.readCount, 3, setting)
        }
    }

    /// The 5' and 3' distances of a custom dual kit are searched as `N{a}` and `N{b}` wildcards at the read ends, one line
    /// for each pair of distances on each strand, 3 x 2 x 2 lines at 2 and 1 (BIO-DUAL-ANCHOR item 1, test iii). A read with
    /// 2 extra bases before the i7 and 1 after the i5 is placed, and so is a read of the other strand within the distances.
    /// A read with 3 extra bases before the i7 is not. At the base the distances were ignored.
    func testTheDistancesOfACustomDualKitAreSearchedAsWildcardsAtTheReadEnds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (i7, i5, insert) = (Self.anchorI7, Self.anchorI5, Self.anchorInsert)
        let (rcI7, rcI5) = (PlatformAdapters.reverseComplement(i7), PlatformAdapters.reverseComplement(i5))
        XCTAssertEqual([rcI7, rcI5], ["TTCGCCCA", "TAACTCCT"])
        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                "GC" + i7 + insert + i5 + "T",                                  // 2 bases before, 1 after
                "GT" + rcI5 + PlatformAdapters.reverseComplement(insert) + rcI7 + "A",  // the other strand, 2 and 1
                "GCA" + i7 + insert + i5,                                       // 3 bases before
            ],
            to: inputFASTQ
        )
        let config = DemultiplexConfig(
            inputURL: inputFASTQ,
            barcodeKit: Self.anchorKit,
            outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .bothEnds,
            errorRate: 0.0,
            minimumOverlap: 3,
            maxDistanceFrom5Prime: 2,
            maxDistanceFrom3Prime: 1,
            trimBarcodes: true,
            threads: 1
        )
        let work = dir.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let adapters = try await DemultiplexingPipeline().createAdapterConfiguration(for: config, workDirectory: work)
        let lines = try String(contentsOf: adapters.adapterFASTA, encoding: .utf8).split(separator: "\n").map(String.init)
        var expected: [String] = []
        for (suffix, front, back) in [("__lge_forward", i7, i5), ("__lge_reverse_complement", rcI5, rcI7)] {
            for a in 0...2 {
                for b in 0...1 {
                    let before = a > 0 ? "N{\(a)}" : ""
                    let after = b > 0 ? "N{\(b)}" : ""
                    expected += [">D01\(suffix)", "^\(before)\(front)...\(back)\(after)$"]
                }
            }
        }
        XCTAssertEqual(expected.count, 2 * 3 * 2 * 2)
        XCTAssertEqual(lines, expected)

        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
        XCTAssertEqual(result.manifest.inputReadCount, 3)
        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["D01"])
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 2)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
    }

    func testVirtualDemuxPreservesInterleavedPairingModeFromBundleMetadata() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "root")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        try writeFASTQ(
            sequences: [
                "ACGTAAAAAA",
                "ACGTCCCCCC",
                "ACGTGGGGGG",
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
            XCTFail("Demux should fail when a bundle cannot be published with its derived manifest.")
        } catch let error as DemultiplexError {
            guard case .bundleCreationFailed(let barcode, _) = error else {
                XCTFail("Expected bundleCreationFailed, got \(error)")
                return
            }
            XCTAssertEqual(barcode, "sample1")
            // The run writes into a staging folder and publishes only when every
            // bundle is finished, so the folder that holds the bundle's name is
            // left as it was and no bundle of the run lands without its manifest.
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: blockedBundleURL.path),
                [FASTQBundle.derivedManifestFilename],
                "the folder already in the output keeps only what it held"
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: outputDir.path),
                ["sample1.\(FASTQBundle.directoryExtension)"],
                "nothing of the failed run is left in the output, not even its staging folder"
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

    /// Symmetric long-read kits (ONT native barcoding) assign in pass 1 by
    /// either end and then keep only both-end reads. Reads that carried the
    /// barcode at one end used to be deleted with the per-barcode file, so
    /// they appeared in no output bundle and the manifest's input count
    /// shrank. They belong in `unassigned`, whole and untrimmed.
    func testSymmetricLongReadDemuxRoutesOneEndReadsToUnassignedInsteadOfDroppingThem() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let kit = BarcodeKitRegistry.ontNativeBarcoding24
        let barcode = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode13" }))
        let context = ONTNativeAdapterContext()
        let insert = String(repeating: "GATTACA", count: 20)
        let five = context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
        let three = context.threePrimeSpec(barcodeSequence: barcode.i7Sequence)
        let bothEnds = five + insert + three
        let fivePrimeOnly = five + insert
        let threePrimeOnly = insert + three
        let unbarcoded = insert
        try writeFASTQ(sequences: [bothEnds, fivePrimeOnly, threePrimeOnly, unbarcoded], to: inputFASTQ)

        let pipeline = DemultiplexingPipeline()
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                errorRate: 0.0,
                minimumOverlap: 20,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertTrue(result.manifest.parameters.requireBothEnds)
        XCTAssertEqual(result.manifest.inputReadCount, 4, "every input read is accounted for")
        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["barcode13"])
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 1)
        XCTAssertEqual(result.manifest.unassigned.readCount, 3)

        let unassignedBundle = try XCTUnwrap(result.unassignedBundleURL)
        XCTAssertEqual(unassignedBundle.lastPathComponent, "unassigned.lungfishfastq")
        let unassignedFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: unassignedBundle))
        var unassignedIDs: [String] = []
        var unassignedLengths: [String: Int] = [:]
        for try await record in FASTQReader(validateSequence: false).records(from: unassignedFASTQ) {
            unassignedIDs.append(record.identifier)
            unassignedLengths[record.identifier] = record.length
        }
        XCTAssertEqual(Set(unassignedIDs), ["read_1", "read_2", "read_3"], "one-end and unbarcoded reads land in unassigned")
        XCTAssertEqual(unassignedIDs.count, 3, "no read is duplicated")
        XCTAssertEqual(unassignedLengths["read_1"], fivePrimeOnly.count, "unassigned reads stay untrimmed")
        XCTAssertEqual(unassignedLengths["read_2"], threePrimeOnly.count, "unassigned reads stay untrimmed")
        XCTAssertEqual(unassignedLengths["read_3"], unbarcoded.count)
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

    // MARK: - Children of reads with placeholder scores (lane FLUIDIGM-CHILDREN F5, ruling BIO-FLUIDIGM-CHILDREN)

    /// A bundle whose derived manifest holds the placeholder mark and whose reads carry `I`. The mark is the only thing
    /// that makes it a marked source: its operation is a subsample and it holds no Fluidigm library prep, so the legacy
    /// clause of `FASTQQualityScoreOrigin` does not apply.
    private func makeMarkedSourceBundle(
        in tempDir: URL,
        name: String,
        sequences: [String]
    ) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writeFASTQ(sequences: sequences, to: bundleURL.appendingPathComponent("reads.fastq"))
        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: sequences.count)
        let manifest = FASTQDerivedBundleManifest(
            name: name,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fastq",
            payload: .full(fastqFilename: "reads.fastq"),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .empty,
            pairingMode: .singleEnd,
            qualityScoresArePlaceholders: true
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }

    /// Every child bundle in `outputDir`, by name without its extension, with its stored derived manifest.
    private func childManifests(in outputDir: URL) throws -> [String: FASTQDerivedBundleManifest] {
        var children: [String: FASTQDerivedBundleManifest] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        where url.pathExtension == FASTQBundle.directoryExtension {
            children[url.deletingPathExtension().lastPathComponent] = FASTQBundle.loadDerivedManifest(in: url)
        }
        return children
    }

    private func assertChildrenAreMarked(
        _ children: [String: FASTQDerivedBundleManifest],
        readCounts: [String: Int],
        route: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(children.keys), Set(readCounts.keys), "\(route) children", file: file, line: line)
        for (name, readCount) in readCounts {
            guard let manifest = children[name] else { continue }
            let stats = manifest.cachedStatistics
            XCTAssertEqual(
                manifest.qualityScoresArePlaceholders, true,
                "\(route) \(name), a child of placeholder reads carries the mark of its source", file: file, line: line
            )
            XCTAssertEqual(stats.readCount, readCount, "\(route) \(name) read count", file: file, line: line)
            XCTAssertEqual(stats.meanQuality, 0, "\(route) \(name) Mean Q of reads no instrument scored", file: file, line: line)
            XCTAssertEqual(stats.q20Percentage, 0, "\(route) \(name) Q20", file: file, line: line)
            XCTAssertEqual(stats.q30Percentage, 0, "\(route) \(name) Q30", file: file, line: line)
            XCTAssertTrue(
                stats.qualityScoreHistogram.isEmpty,
                "\(route) \(name) score histogram \(stats.qualityScoreHistogram)", file: file, line: line
            )
            XCTAssertTrue(
                stats.perPositionQuality.isEmpty,
                "\(route) \(name) \(stats.perPositionQuality.count) per-position quality summaries", file: file, line: line
            )
        }
    }

    /// FLUIDIGM-CHILDREN F5. Demultiplex Barcodes started on a bundle whose reads carry written scores stored the
    /// scores of the reads' `I` characters in each child, Mean Q 40.0 and Q20 and Q30 of 100 percent, with no mark.
    /// A child of marked reads stores the `withoutQualities` shape and the mark, on both Swift-native routes.
    func testAChildOfPlaceholderReadsIsMarked() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        // The exact bare-barcode route, one known barcode on two of three reads.
        let fld0001 = "GTATCGTCGT"
        let bareSource = try makeMarkedSourceBundle(
            in: tempDir,
            name: "counted-bare",
            sequences: [
                "AAAAA" + fld0001 + "CCCCCGGGGG",
                "TTTTT" + PlatformAdapters.reverseComplement(fld0001) + "GGGGGCCCCC",
                "AAAAAAAAAACCCCCCCCCC",
            ]
        )
        let bareOutput = tempDir.appendingPathComponent("bare-out", isDirectory: true)
        _ = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: bareSource,
                barcodeKit: BarcodeKitDefinition(
                    id: "custom-marked-subset",
                    displayName: "Custom Marked Subset",
                    vendor: "custom",
                    isDualIndexed: false,
                    pairingMode: .singleEnd,
                    barcodes: [BarcodeEntry(id: "FLD0001", i7Sequence: fld0001)]
                ),
                outputDirectory: bareOutput,
                barcodeLocation: .bothEnds,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                trimBarcodes: true,
                threads: 1,
                engine: .exactBareBarcode,
                rootBundleURL: bareSource,
                rootFASTQFilename: "reads.fastq"
            ),
            progress: { _, _ in }
        )
        assertChildrenAreMarked(
            try childManifests(in: bareOutput),
            readCounts: ["FLD0001": 2, "unassigned": 1],
            route: "exact bare-barcode route"
        )

        // The exact asymmetric route, one sample from a barcode pair on one of two reads.
        let forward = "ACGTACGT"
        let reverse = "TGCATGCA"
        let insert = "GATTACA"
        let pairSource = try makeMarkedSourceBundle(
            in: tempDir,
            name: "counted-pair",
            sequences: [
                forward + insert + PlatformAdapters.reverseComplement(reverse),
                "CCCCCCCCCCCCCCCCCCCCCCCC",
            ]
        )
        let pairOutput = tempDir.appendingPathComponent("pair-out", isDirectory: true)
        _ = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: pairSource,
                barcodeKit: BarcodeKitDefinition(
                    id: "exact-marked-pair",
                    displayName: "Exact Marked Pair",
                    vendor: "custom",
                    isDualIndexed: true,
                    pairingMode: .fixedDual,
                    barcodes: [BarcodeEntry(id: "PAIR1", i7Sequence: forward, i5Sequence: reverse)]
                ),
                outputDirectory: pairOutput,
                errorRate: 0.0,
                minimumOverlap: 4,
                trimBarcodes: true,
                threads: 1,
                sampleAssignments: [
                    FASTQSampleBarcodeAssignment(sampleID: "sample1", forwardSequence: forward, reverseSequence: reverse),
                ],
                rootBundleURL: pairSource,
                rootFASTQFilename: "reads.fastq",
                minimumInsert: insert.count
            ),
            progress: { _, _ in }
        )
        assertChildrenAreMarked(
            try childManifests(in: pairOutput),
            readCounts: ["sample1": 1, "unassigned": 1],
            route: "exact barcode-pair route"
        )
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
                "GTATCGTCGTGATTACC",
                "GTATCGTCGTGATTACG",
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
        XCTAssertEqual(result.manifest.barcodes.first(where: { $0.barcodeID == "FLD0001" })?.readCount, 3)
    }

    func testCutadaptFullOutputModeDoesNotBuildVirtualReadIDSidecars() async throws {
        let (tempDir, bundleURL, fastqURL) = try makeTempBundle(named: "input")
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        try writeFASTQ(
            sequences: [
                "GTATCGTCGTGATTACA",
                "GTATCGTCGTGATTACC",
                "GTATCGTCGTGATTACG",
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
        XCTAssertEqual(barcodeResult.readCount, 3)
        XCTAssertEqual(barcodeResult.baseCount, 21)
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
                runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview)
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
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview),
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

    // MARK: - A dual kit with no sample sheet, at one read end and on the other strand (DEMUX-DUAL-BARE-REVERSE)

    /// The lines `createAdapterConfiguration` hands to cutadapt for `config`, each with the name of the header above it.
    private func adapterLines(_ config: DemultiplexConfig, in dir: URL) async throws -> [(name: String, text: String)] {
        let work = dir.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let adapters = try await DemultiplexingPipeline().createAdapterConfiguration(for: config, workDirectory: work)
        var name = ""
        var lines: [(name: String, text: String)] = []
        for line in try String(contentsOf: adapters.adapterFASTA, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix(">") {
                name = String(line.dropFirst())
            } else {
                lines.append((name: name, text: String(line)))
            }
        }
        return lines
    }

    /// A custom dual-index definition with no sample sheet at 5' End or 3' End leaves one barcode of each pair free, so
    /// preflight refuses it before any tool runs, in words that name Both Ends and the two distances, and Both Ends still
    /// passes (BIO-BARE-REVERSE items 1 and 5 (ii), Q4). At the base both one-end runs passed preflight.
    func testACustomDualDefinitionWithNoSampleSheetIsRefusedAtOneReadEnd() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let csv = dir.appendingPathComponent("dual.csv")
        try "id,i7_sequence,i5_sequence\nD01,TGGGCGAA,AGGAGTTA\n".write(to: csv, atomically: true, encoding: .utf8)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: csv, name: "dual")
        XCTAssertEqual(kit.pairingMode, .fixedDual)
        XCTAssertEqual(kit.platform, .unknown)
        XCTAssertNil(kit.sourceKitID)
        let input = dir.appendingPathComponent("reads.fastq")
        try writeFASTQ(sequences: [Self.anchorI7 + Self.anchorInsert + Self.anchorI5], to: input)
        func config(_ location: BarcodeLocation) -> DemultiplexConfig {
            DemultiplexConfig(
                inputURL: input,
                barcodeKit: kit,
                outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
                barcodeLocation: location,
                threads: 1
            )
        }
        for location in [BarcodeLocation.fivePrime, .threePrime] {
            do {
                try await DemultiplexingPipeline().preflight(config: config(location))
                XCTFail("a custom dual definition at \(location) with no sample sheet leaves one barcode free")
            } catch DemultiplexError.dualKitNeedsBothEnds(let kitName) {
                XCTAssertEqual(kitName, kit.displayName)
                let words = DemultiplexError.dualKitNeedsBothEnds(kitName: kitName).errorDescription ?? ""
                XCTAssertTrue(words.contains("\"\(kit.displayName)\""), words)
                XCTAssertTrue(words.contains("Choose Both Ends (on the command line, --location bothends)"), words)
                XCTAssertEqual(words, "The kit \"\(kit.displayName)\" has its first index at the start of a read and its second at "
                               + "the end, so it can be searched only at Both Ends, and nothing was run. Choose Both Ends (on the "
                               + "command line, --location bothends) and run it again. If your barcodes sit some bases in from the "
                               + "read ends, also set 5' Distance and 3' Distance to that many bases (on the command line, "
                               + "--max-distance-5prime and --max-distance-3prime).")
                XCTAssertFalse(words.contains("reverse complement"), "Both Ends reads the secondary sequence either way (DEMUX-DUAL-FORM)")
            }
        }
        do {
            try await DemultiplexingPipeline().preflight(config: config(.bothEnds))
        } catch DemultiplexError.dualKitNeedsBothEnds(_) {
            XCTFail("Both Ends anchors both barcodes, so the definition is not refused for its location")
        }
        // A built-in kit keeps its words, which name no distance, since its indexes sit at the read ends.
        let builtIn = DemultiplexError.dualKitNeedsBothEnds(kitName: BarcodeKitRegistry.nexteraXTv2.displayName)
        XCTAssertFalse((builtIn.errorDescription ?? "").contains("Distance"), builtIn.errorDescription ?? "")
    }

    /// The other strand of a pair reads as the reverse complement of the pair as written. For `N701-S502` of the built-in
    /// `nextera-xt-v2` at Both Ends with no sample sheet the lines are `^TAAGGCGA...ATAGAGAG$` and `^CTCTCTAT...TCGCCTTA$`,
    /// and every pair has its two strands (BIO-BARE-REVERSE items 2 and 5 (i), Q2). At the base the second line was the swap
    /// `^ATAGAGAG...TAAGGCGA$`, which is no strand of the molecule.
    func testABuiltInDualKitSearchesTheReverseComplementOfEachPairAsItsOtherStrand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let kit = BarcodeKitRegistry.nexteraXTv2
        let lines = try await adapterLines(DemultiplexConfig(
            inputURL: dir.appendingPathComponent("reads.fastq"),
            barcodeKit: kit,
            outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .bothEnds,
            threads: 1
        ), in: dir)
        XCTAssertEqual(lines.filter { $0.name == "N701-S502" }.map { $0.text },
                       ["^TAAGGCGA...ATAGAGAG$", "^CTCTCTAT...TCGCCTTA$"])
        for barcode in kit.barcodes {
            let i7 = barcode.i7Sequence.uppercased()
            let i5 = try XCTUnwrap(barcode.i5Sequence).uppercased()
            let (rcI7, rcI5) = (PlatformAdapters.reverseComplement(i7), PlatformAdapters.reverseComplement(i5))
            XCTAssertEqual(lines.filter { $0.name == barcode.id }.map { $0.text }, ["^\(i7)...\(rcI5)$", "^\(i5)...\(rcI7)$"],
                           barcode.id)
        }
    }

    /// The sample-sheet route of a kit of single barcodes searched as pairs, the other caller of the linked writer, writes
    /// the other strand the same way, as the reverse complement of its forward line (BIO-BARE-REVERSE items 2 and 5 (iii)).
    /// At the base it wrote the swap `^rc(reverse)...forward$`.
    func testTheSampleSheetRouteSearchesTheReverseComplementOfEachPairAsItsOtherStrand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let kit = BarcodeKitRegistry.truseqSingleA
        XCTAssertEqual(kit.pairingMode, .singleEnd)
        let (forward, reverse) = (Self.anchorI7, Self.anchorI5)
        let (rcForward, rcReverse) = (PlatformAdapters.reverseComplement(forward), PlatformAdapters.reverseComplement(reverse))
        XCTAssertNotEqual(rcReverse, forward, "the pair is not its own other strand")
        let lines = try await adapterLines(DemultiplexConfig(
            inputURL: dir.appendingPathComponent("reads.fastq"),
            barcodeKit: kit,
            outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .bothEnds,
            symmetryMode: .asymmetric,
            threads: 1,
            sampleAssignments: [FASTQSampleBarcodeAssignment(sampleID: "S1", forwardSequence: forward, reverseSequence: reverse)]
        ), in: dir)
        XCTAssertEqual(lines.map { $0.name }, ["S1", "S1"])
        XCTAssertEqual(lines.map { $0.text }, ["^\(forward)...\(rcReverse)$", "^\(reverse)...\(rcForward)$"])
    }

    /// A sheet pair whose two barcodes are the same sequence reads `F ... rc(F)` on both strands, so its other strand is
    /// its forward line and one line is written (BIO-BARE-REVERSE item 2, the skip of `writeLinkedAdapterFASTA`). At the
    /// base the second line was the swap `^rc(F)...F$`.
    func testASheetPairThatIsItsOwnOtherStrandWritesOneLine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let barcode = Self.anchorI7
        XCTAssertNotEqual(PlatformAdapters.reverseComplement(barcode), barcode, "the barcode is not a palindrome")
        let lines = try await adapterLines(DemultiplexConfig(
            inputURL: dir.appendingPathComponent("reads.fastq"),
            barcodeKit: BarcodeKitRegistry.truseqSingleA,
            outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
            barcodeLocation: .bothEnds,
            symmetryMode: .asymmetric,
            threads: 1,
            sampleAssignments: [FASTQSampleBarcodeAssignment(sampleID: "S1", forwardSequence: barcode, reverseSequence: barcode)]
        ), in: dir)
        XCTAssertEqual(lines.map { $0.text }, ["^\(barcode)...\(PlatformAdapters.reverseComplement(barcode))$"])
    }

    /// With the lines of `nextera-xt-v2` at Both Ends, reads of `N701-S502` on either strand are placed in its sample and a
    /// read with the pair swapped, which is no strand of the molecule, stays unassigned (BIO-BARE-REVERSE item 5 (iv), Q3).
    /// At the base cutadapt left both reverse-strand reads unassigned and placed the swapped read.
    func testABuiltInDualKitPlacesReadsOfBothStrandsAndNotTheSwappedPair() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        // N701 and the reverse complement of S502, as the forward strand of the read carries them.
        let (i7, rcI5) = ("TAAGGCGA", "ATAGAGAG")
        let forward = i7 + Self.anchorInsert + rcI5
        let otherInsert = "CATGCGTAAACTGCTAGGTACTGACTGAACTGGAC"
        let inputFASTQ = dir.appendingPathComponent("input.fastq")
        try writeFASTQ(
            sequences: [
                forward,                                                            // the pair as written
                PlatformAdapters.reverseComplement(forward),                        // the other strand
                PlatformAdapters.reverseComplement(i7 + otherInsert + rcI5),        // the other strand, another insert
                rcI5 + Self.anchorInsert + i7,                                      // the pair swapped
            ],
            to: inputFASTQ
        )
        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: BarcodeKitRegistry.nexteraXTv2,
                outputDirectory: dir.appendingPathComponent("demux-out", isDirectory: true),
                barcodeLocation: .bothEnds,
                errorRate: 0.15,
                threads: 1,
                engine: .cutadapt
            ),
            progress: { _, _ in }
        )
        XCTAssertEqual(result.manifest.inputReadCount, 4)
        XCTAssertEqual(result.manifest.barcodes.map(\.barcodeID), ["N701-S502"])
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 3, "the pair as written and both reads of the other strand")
        XCTAssertEqual(result.manifest.unassigned.readCount, 1, "the swapped pair")
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
