// AlignmentDataProviderTests.swift - Tests for alignment data provider
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
@testable import LungfishIO
@testable import LungfishCore

final class AlignmentDataProviderTests: XCTestCase {

    func testFetchDepthUsesExplicitCustomIndex() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-depth-index")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        case " $* " in *" -q 7 -Q 12 -g 1796 -G 3332 -r chr1:1-1 -X /tmp/fake.bam /tmp/nonadjacent.csi "*) echo "chr1\t1\t2" ;; *) exit 9 ;; esac
        """)
        let provider = AlignmentDataProvider(alignmentPath: "/tmp/fake.bam", indexPath: "/tmp/nonadjacent.csi", samtoolsPath: script.path)
        let depth = try await provider.fetchDepth(chromosome: "chr1", start: 0, end: 1, minMapQ: 12, minBaseQ: 7, excludeFlags: 0xD04)
        XCTAssertEqual(depth.first?.depth, 2)
    }

    func testCancellationRelayTerminatesRunningSamtoolsProcess() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-cancellation")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        exec /bin/sleep 1000
        """)
        let installed = DispatchSemaphore(value: 0)
        let cancellation = SamtoolsCancellation(onInstall: { installed.signal() })
        let task = Task.detached {
            try AlignmentDataProvider.runSamtoolsProcess(
                samtoolsPath: script.path, arguments: [], timeout: 30, cancellation: cancellation
            )
        }
        XCTAssertEqual(installed.wait(timeout: .now() + 2), .success)
        cancellation.cancel()
        let result = try await task.value
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testBudgetedSketchReaderTerminatesProducerAndRetainsBoundedRecords() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-budgeted-stream")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        trap 'exit 0' TERM
        while :; do printf 'read\\t0\\tchr1\\t1\\t60\\t1M\\t*\\t0\\t0\\tA\\tI\\n'; done
        """)

        let result = try AlignmentDataProvider.runSamtoolsProcessBudgeted(
            samtoolsPath: script.path, arguments: ["view", "-X", "/tmp/evidence.bam", "/tmp/evidence.bam.bai", "chr1:1-1"],
            timeout: 5, maxRecords: 7, maxBytes: 2_048
        )

        XCTAssertTrue(result.terminatedForBudget)
        XCTAssertLessThanOrEqual(result.retainedRecordCount, 7)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 2_048)
        XCTAssertLessThanOrEqual(result.stdout.split(separator: "\n").count, 7)
    }

    func testBudgetedReaderKillsTermIgnoringNoisyChildByDeadline() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-budget-timeout")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let script = try makeFakeSamtools(in: tempDir, script: "#!/bin/sh\ntrap '' TERM\nwhile :; do printf 'unterminated-record'; printf 'noisy stderr' >&2; done\n")
        let started = Date()
        var childPID: pid_t?
        XCTAssertThrowsError(try AlignmentDataProvider.runSamtoolsProcessBudgeted(
            samtoolsPath: script.path, arguments: ["view", "-X", "/tmp/evidence.bam", "/tmp/evidence.bam.bai", "chr1:1-1"],
            timeout: 0.2, maxRecords: 10, maxBytes: 256,
            processStarted: { childPID = $0 }
        )) { error in
            XCTAssertEqual(error.localizedDescription, "samtools timed out")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        let pid = try XCTUnwrap(childPID)
        XCTAssertEqual(kill(pid, 0), -1, "Timed-out child must be reaped before returning")
    }

    // MARK: - Initialization

    func testProviderInitialization() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai",
            format: .bam,
            referenceFastaPath: nil
        )

        XCTAssertEqual(provider.alignmentPath, "/data/sample.bam")
        XCTAssertEqual(provider.indexPath, "/data/sample.bam.bai")
        XCTAssertEqual(provider.format, .bam)
        XCTAssertNil(provider.referenceFastaPath)
    }

    func testProviderInitializationCRAM() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.cram",
            indexPath: "/data/sample.cram.crai",
            format: .cram,
            referenceFastaPath: "/data/reference.fa"
        )

        XCTAssertEqual(provider.format, .cram)
        XCTAssertEqual(provider.referenceFastaPath, "/data/reference.fa")
    }

    func testProviderDefaultFormat() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/test.bam",
            indexPath: "/data/test.bam.bai"
        )

        XCTAssertEqual(provider.format, .bam)
        XCTAssertNil(provider.referenceFastaPath)
    }

    // MARK: - Sendable Conformance

    func testProviderIsSendable() {
        let provider = AlignmentDataProvider(
            alignmentPath: "/data/sample.bam",
            indexPath: "/data/sample.bam.bai"
        )

        // Verify Sendable by capturing in a Sendable closure
        let sendableCheck: @Sendable () -> String = {
            provider.alignmentPath
        }
        XCTAssertEqual(sendableCheck(), "/data/sample.bam")
    }

    @MainActor
    func testRunSamtoolsProcessWorkIsDetachedFromCallerExecutor() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-detached-samtools")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samtoolsURL = try makeFakeSamtools(
            in: tempDir,
            script: """
            #!/bin/sh
            if [ "$1" = "idxstats" ]; then
                sleep 1
                echo "chr1\t100\t2\t0"
                echo "fake stderr from idxstats" >&2
                exit 0
            fi
            echo "unexpected command: $*" >&2
            exit 9
            """
        )
        let provider = AlignmentDataProvider(
            alignmentPath: "/tmp/fake.bam",
            indexPath: "/tmp/fake.bam.bai",
            samtoolsPath: samtoolsURL.path
        )

        let start = Date()
        let task = Task { try await provider.fetchIdxstats() }
        await Task.yield()

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "Calling fetchIdxstats from MainActor must suspend quickly while samtools runs elsewhere"
        )
        let output = try await task.value
        XCTAssertEqual(output, "chr1\t100\t2\t0\n")
    }

    func testRunSamtoolsPreservesFailureStderr() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-failing-samtools")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samtoolsURL = try makeFakeSamtools(
            in: tempDir,
            script: """
            #!/bin/sh
            echo "idxstats exploded" >&2
            exit 7
            """
        )
        let provider = AlignmentDataProvider(
            alignmentPath: "/tmp/fake.bam",
            indexPath: "/tmp/fake.bam.bai",
            samtoolsPath: samtoolsURL.path
        )

        do {
            _ = try await provider.fetchIdxstats()
            XCTFail("Expected samtools failure")
        } catch AlignmentFetchError.samtoolsFailed(let message) {
            XCTAssertTrue(message.contains("idxstats exploded"))
        } catch {
            XCTFail("Expected AlignmentFetchError.samtoolsFailed, got \(error)")
        }
    }

    func testRunSamtoolsProcessTimeoutIsPreserved() throws {
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-timeout-samtools")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samtoolsURL = try makeFakeSamtools(
            in: tempDir,
            script: """
            #!/bin/sh
            sleep 5
            echo "late output"
            """
        )

        do {
            _ = try AlignmentDataProvider.runSamtoolsProcess(
                samtoolsPath: samtoolsURL.path,
                arguments: ["idxstats", "/tmp/fake.bam"],
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch AlignmentFetchError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected AlignmentFetchError.timeout, got \(error)")
        }
    }

    // MARK: - Invalid Region Handling

    func testFetchReadsInvalidEmptyChromosome() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "", start: 0, end: 100)
            XCTFail("Expected error for empty chromosome")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion(let region) = error {
                XCTAssertTrue(region.contains(":0-100"))
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsInvalidNegativeStart() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "chr1", start: -1, end: 100)
            XCTFail("Expected error for negative start")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion = error {
                // Expected
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsInvalidStartGreaterThanEnd() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReads(chromosome: "chr1", start: 200, end: 100)
            XCTFail("Expected error for start > end")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion = error {
                // Expected
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    func testFetchReadsZeroMaxReadsReturnsEmpty() async throws {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        // maxReads = 0 should return empty without running samtools
        let reads = try await provider.fetchReads(
            chromosome: "chr1", start: 0, end: 100, maxReads: 0
        )
        XCTAssertTrue(reads.isEmpty)
    }

    func testReadSketchSubsampleFractionOnlySamplesWhenOverTarget() {
        XCTAssertNil(AlignmentDataProvider.readSketchSubsampleFraction(totalReads: 2_500, targetReads: 2_500))
        XCTAssertNil(AlignmentDataProvider.readSketchSubsampleFraction(totalReads: 100, targetReads: 0))

        let fraction = AlignmentDataProvider.readSketchSubsampleFraction(totalReads: 10_000, targetReads: 2_500)
        XCTAssertEqual(fraction ?? 0, 0.25, accuracy: 0.000_001)

        let tinyFraction = AlignmentDataProvider.readSketchSubsampleFraction(totalReads: 10_000_000_000, targetReads: 1)
        XCTAssertEqual(tinyFraction ?? 0, 0.000_001, accuracy: 0.000_000_1)
    }

    func testFetchReadSketchValidatesRegionBeforeTargetLimit() async {
        let provider = AlignmentDataProvider(
            alignmentPath: "/nonexistent.bam",
            indexPath: "/nonexistent.bam.bai"
        )

        do {
            _ = try await provider.fetchReadSketch(chromosome: "", start: 0, end: 100, targetReads: 0)
            XCTFail("Expected invalid region error")
        } catch let error as AlignmentFetchError {
            if case .invalidRegion = error {
                // Expected
            } else {
                XCTFail("Expected .invalidRegion but got \(error)")
            }
        } catch {
            XCTFail("Expected AlignmentFetchError but got \(type(of: error))")
        }
    }

    // MARK: - AlignmentFetchError

    func testAlignmentFetchErrorSamtoolsNotFoundDescription() {
        let error = AlignmentFetchError.samtoolsNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("samtools"))
    }

    func testAlignmentFetchErrorSamtoolsFailedDescription() {
        let error = AlignmentFetchError.samtoolsFailed("file not found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("file not found"))
    }

    func testAlignmentFetchErrorInvalidRegionDescription() {
        let error = AlignmentFetchError.invalidRegion("chr1:-5-100")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("chr1:-5-100"))
    }

    func testAlignmentFetchErrorTimeoutDescription() {
        let error = AlignmentFetchError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }

    func testAllAlignmentFetchErrorCasesHaveDescriptions() {
        let errors: [AlignmentFetchError] = [
            .samtoolsNotFound,
            .samtoolsFailed("test"),
            .invalidRegion("test"),
            .timeout
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error case should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - SAMParser Integration (inline data, no samtools needed)

    func testSAMParserParsesAlignedReads() {
        let samLine = "read1\t99\tchr1\t100\t60\t75M\t=\t300\t275\tACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACG\t*\tRG:Z:sample1"
        let reads = SAMParser.parse(samLine)
        XCTAssertEqual(reads.count, 1)

        let read = reads[0]
        XCTAssertEqual(read.name, "read1")
        XCTAssertEqual(read.chromosome, "chr1")
        XCTAssertEqual(read.position, 99) // 0-based (100 - 1)
        XCTAssertEqual(read.mapq, 60)
    }

    func testSAMParserParsesReadGroups() {
        let headerText = """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:248956422
        @RG\tID:lane1\tSM:NA12878\tPL:ILLUMINA\tLB:lib1
        @RG\tID:lane2\tSM:NA12878\tPL:ILLUMINA\tLB:lib2
        @RG\tID:lane3\tSM:HG002\tPL:ILLUMINA\tLB:lib3
        """
        let readGroups = SAMParser.parseReadGroups(from: headerText)
        XCTAssertEqual(readGroups.count, 3)

        let samples = Set(readGroups.compactMap { $0.sample })
        XCTAssertTrue(samples.contains("NA12878"))
        XCTAssertTrue(samples.contains("HG002"))
    }

    func testSAMParserHandlesEmptyInput() {
        let reads = SAMParser.parse("")
        XCTAssertTrue(reads.isEmpty)
    }

    func testSAMParserReadGroupsEmptyHeader() {
        let readGroups = SAMParser.parseReadGroups(from: "")
        XCTAssertTrue(readGroups.isEmpty)
    }

    func testSAMParserReadGroupsNoRGLines() {
        let header = "@HD\tVN:1.6\n@SQ\tSN:chr1\tLN:248956422\n"
        let readGroups = SAMParser.parseReadGroups(from: header)
        XCTAssertTrue(readGroups.isEmpty)
    }

    // MARK: - Depth Parsing

    func testParseDepthOutputBasic() {
        let depthOutput = """
        chr1\t101\t20
        chr1\t102\t0
        chr1\t150\t7
        """
        let points = AlignmentDataProvider.parseDepthOutput(depthOutput)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0], DepthPoint(chromosome: "chr1", position: 100, depth: 20))
        XCTAssertEqual(points[1], DepthPoint(chromosome: "chr1", position: 101, depth: 0))
        XCTAssertEqual(points[2], DepthPoint(chromosome: "chr1", position: 149, depth: 7))
    }

    func testParseDepthOutputSkipsInvalidLines() {
        let depthOutput = """
        chr1\t100\t10
        bad-line
        chr1\tX\t4
        chr1\t120\tY
        chr2\t1\t9
        """
        let points = AlignmentDataProvider.parseDepthOutput(depthOutput)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], DepthPoint(chromosome: "chr1", position: 99, depth: 10))
        XCTAssertEqual(points[1], DepthPoint(chromosome: "chr2", position: 0, depth: 9))
    }

    func testParseDepthOutputEmpty() {
        XCTAssertTrue(AlignmentDataProvider.parseDepthOutput("").isEmpty)
        XCTAssertTrue(AlignmentDataProvider.parseDepthOutput("\n\n").isEmpty)
    }

    func testParseConsensusFASTA() {
        let fasta = """
        >chr1:1-10
        acgtNN
        tgca
        """
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGTNNTGCA")
        // Header ">chr1:1-10" → 1-based start 1 → 0-based start 0
        XCTAssertEqual(result.headerStart, 0)
    }

    func testParseConsensusFASTAHeaderWithLargeRegion() {
        let fasta = ">MN908947.3:5001-10000\nACGTACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGTACGT")
        // 1-based start 5001 → 0-based start 5000
        XCTAssertEqual(result.headerStart, 5000)
    }

    func testParseConsensusFASTANoRegionInHeader() {
        // A header without a region suffix denotes the whole contig, which
        // starts at the contig origin.
        let fasta = ">chr1\nACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGT")
        XCTAssertEqual(result.headerStart, 0)
    }

    func testParseConsensusFASTAWholeContigHeaderHasNoCoordinateSuffix() {
        // `samtools consensus` omits the ":start-end" suffix when the requested
        // region spans the entire contig, so a bare header must still resolve to
        // the contig origin rather than an absent coordinate.
        let fasta = ">NC_028478.1\nACGTACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGTACGT")
        XCTAssertEqual(result.headerStart, 0)
    }

    func testParseConsensusFASTAIgnoresColonInContigNameWithoutRange() {
        // A contig whose own name contains a colon must not be misread as a
        // coordinate range; without a "-" separator there is no region to parse.
        let fasta = ">HLA:A*01:01\nACGT\n"
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "ACGT")
        XCTAssertEqual(result.headerStart, 0)
    }

    func testParseConsensusFASTAPreservesDeletionMarkers() {
        let fasta = """
        >chr1:11-20
        AC*GT**TAA
        """
        let result = AlignmentDataProvider.parseConsensusFASTA(fasta)
        XCTAssertEqual(result.sequence, "AC*GT**TAA")
        XCTAssertEqual(result.sequence.count, 10)
        XCTAssertEqual(result.headerStart, 10)
    }

    func testParseConsensusFASTAEmpty() {
        let result = AlignmentDataProvider.parseConsensusFASTA("")
        XCTAssertTrue(result.sequence.isEmpty)
        XCTAssertNil(result.headerStart)
    }

    // MARK: - Evidence-Only Consensus

    func testConsensusNormalizerMasksSparseAndLowDepthCoordinates() throws {
        // Would fail if the normalizer ever emits a caller base where filtered
        // depth is missing or below the requested threshold.
        let request = AlignmentConsensusRequest(
            chromosome: "chrSynthetic", start: 10, end: 15,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                           excludedFlags: 0x904, readGroups: []),
            mode: .bayesian, useAmbiguity: false,
            insertionPolicy: .omit, deletionPolicy: .n
        )

        let result = try AlignmentConsensusNormalizer.normalize(
            caller: .init(sequence: "ACGTA", headerStart: 10),
            depth: [
                .init(chromosome: "chrSynthetic", position: 10, depth: 3),
                .init(chromosome: "chrSynthetic", position: 12, depth: 7),
                .init(chromosome: "chrSynthetic", position: 13, depth: 1),
            ],
            request: request
        )

        XCTAssertEqual(result.sequence, "ANGNN")
        XCTAssertEqual(result.referenceLength, 5)
        XCTAssertFalse(result.allLowDepth)
    }

    func testConsensusNormalizerAcceptsAllLowDepthResult() throws {
        // Would fail if all-N evidence-only consensus were incorrectly treated
        // as an empty or invalid result.
        let request = consensusRequest(start: 10, end: 15, minimumDepth: 3)

        let result = try AlignmentConsensusNormalizer.normalize(
            caller: .init(sequence: "ACGTA", headerStart: 10),
            depth: [],
            request: request
        )

        XCTAssertEqual(result.sequence, "NNNNN")
        XCTAssertTrue(result.allLowDepth)
    }

    func testConsensusNormalizerUsesCallerMinimumDepthFloorOfOne() throws {
        // Would fail if the normalizer treated a zero-depth coordinate as
        // adequately covered when the caller is invoked with its `-d 1` floor.
        let request = consensusRequest(start: 10, end: 15, minimumDepth: 0)

        let result = try AlignmentConsensusNormalizer.normalize(
            caller: .init(sequence: "ACGTA", headerStart: 10),
            depth: [],
            request: request
        )

        XCTAssertEqual(result.sequence, "NNNNN")
        XCTAssertTrue(result.allLowDepth)
    }

    func testConsensusNormalizerAlignsCallerUsingHeaderStart() throws {
        // Would fail if the caller's header coordinate were ignored and its
        // bases were shifted into the requested interval.
        let request = consensusRequest(start: 10, end: 15, minimumDepth: 1)

        let result = try AlignmentConsensusNormalizer.normalize(
            caller: .init(sequence: "TACGTA", headerStart: 9),
            depth: (10..<15).map { .init(chromosome: "chrSynthetic", position: $0, depth: 1) },
            request: request
        )

        XCTAssertEqual(result.sequence, "ACGTA")
    }

    func testConsensusNormalizerAcceptsWholeContigCallerWithBareHeader() throws {
        // Reproduces the EsViritu whole-contig failure: `samtools consensus`
        // emits ">NC_028478.1" with no coordinate suffix for a full-contig
        // region, which must still project onto the requested interval.
        let request = consensusRequest(start: 0, end: 5, minimumDepth: 1)
        let caller = AlignmentDataProvider.parseConsensusFASTA(">chrSynthetic\nACGTA\n")

        let result = try AlignmentConsensusNormalizer.normalize(
            caller: caller,
            depth: (0..<5).map { .init(chromosome: "chrSynthetic", position: $0, depth: 1) },
            request: request
        )

        XCTAssertEqual(result.sequence, "ACGTA")
        XCTAssertEqual(result.referenceLength, 5)
        XCTAssertFalse(result.allLowDepth)
    }

    func testConsensusNormalizerRejectsMissingOrExtraCoordinateProjection() {
        // Would fail if a truncated or overlong caller result were silently
        // shifted into a reference-coordinate consensus.
        let request = consensusRequest(start: 10, end: 15, minimumDepth: 1)
        let depth = (10..<15).map { DepthPoint(chromosome: "chrSynthetic", position: $0, depth: 1) }

        for caller in [
            AlignmentDataProvider.ConsensusFASTAResult(sequence: "ACGT", headerStart: 10),
            AlignmentDataProvider.ConsensusFASTAResult(sequence: "AACGTA", headerStart: 10),
        ] {
            XCTAssertThrowsError(
                try AlignmentConsensusNormalizer.normalize(caller: caller, depth: depth, request: request)
            ) { error in
                guard case AlignmentFetchError.consensusCoordinateMismatch = error else {
                    return XCTFail("Expected consensusCoordinateMismatch, got \(error)")
                }
            }
        }
    }

    private func consensusRequest(start: Int, end: Int, minimumDepth: Int) -> AlignmentConsensusRequest {
        AlignmentConsensusRequest(
            chromosome: "chrSynthetic", start: start, end: end,
            filters: .init(minimumDepth: minimumDepth, minimumMapQ: 20, minimumBaseQuality: 12,
                           excludedFlags: 0x904, readGroups: []),
            mode: .bayesian, useAmbiguity: false,
            insertionPolicy: .omit, deletionPolicy: .n
        )
    }

    func testFetchConsensusRequestUsesIdenticalEvidenceFiltersForCRAM() async throws {
        // Would fail if the four-stage snapshot pipeline regressed to direct
        // consensus/depth on the source, if source and remaining filters leaked
        // across stage boundaries, or if caller output bypassed depth masking.
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-consensus-parity")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let invocationsURL = tempDir.appendingPathComponent("invocations.txt")
        let sourceURL = tempDir.appendingPathComponent("evidence.cram")
        let sourceIndexURL = tempDir.appendingPathComponent("evidence.cram.crai")
        let decodingReferenceURL = tempDir.appendingPathComponent("decoding-reference.fa")
        try Data("source".utf8).write(to: sourceURL)
        try Data("index".utf8).write(to: sourceIndexURL)
        try Data(">chrSynthetic\nTTTTT\n".utf8).write(to: decodingReferenceURL)
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationsURL.path)"
        case "$1" in
        --version)
            printf 'samtools 1.23.1\\n'
            ;;
        view)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-o" ]; then
                    printf 'filtered BAM' > "$2"
                    break
                fi
                shift
            done
            ;;
        index)
            printf 'filtered index' > "$3"
            ;;
        consensus)
            printf '>chrSynthetic:11-15\\nACGTA\\n'
            ;;
        depth)
            printf 'chrSynthetic\\t11\\t3\\nchrSynthetic\\t13\\t7\\nchrSynthetic\\t14\\t1\\n'
            ;;
        *)
            exit 9
            ;;
        esac
        """)
        let provider = AlignmentDataProvider(
            alignmentPath: sourceURL.path,
            indexPath: sourceIndexURL.path,
            format: .cram,
            referenceFastaPath: decodingReferenceURL.path,
            samtoolsPath: script.path
        )
        let request = AlignmentConsensusRequest(
            chromosome: "chrSynthetic", start: 10, end: 15,
            filters: .init(minimumDepth: 3, minimumMapQ: 20, minimumBaseQuality: 12,
                           excludedFlags: 0x904, readGroups: ["zeta", "alpha"]),
            mode: .bayesian, useAmbiguity: false,
            insertionPolicy: .omit, deletionPolicy: .n
        )

        let result = try await provider.fetchConsensus(request)

        XCTAssertEqual(result.sequence, "ANGNN")
        let invocations = try String(contentsOf: invocationsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(invocations.count, 5)
        let view = try XCTUnwrap(invocations.first { $0.hasPrefix("view ") })
        let index = try XCTUnwrap(invocations.first { $0.hasPrefix("index ") })
        let consensus = try XCTUnwrap(invocations.first { $0.hasPrefix("consensus ") })
        let depth = try XCTUnwrap(invocations.first { $0.hasPrefix("depth ") })
        XCTAssertTrue(view.contains("-b -h -o"))
        XCTAssertTrue(view.contains("-X \(sourceURL.path) \(sourceIndexURL.path)"))
        XCTAssertTrue(view.contains("-T \(decodingReferenceURL.path)"))
        XCTAssertTrue(view.contains("-q 20 -F 2308"))
        XCTAssertTrue(view.contains("-R"))
        XCTAssertTrue(view.contains("-n"))
        XCTAssertTrue(view.contains("chrSynthetic:11-15"))
        XCTAssertTrue(index.contains("filtered.bam"))

        for invocation in [consensus, depth] {
            XCTAssertTrue(invocation.contains("chrSynthetic:11-15"))
            XCTAssertTrue(invocation.contains("filtered.bam"))
            XCTAssertFalse(invocation.contains(sourceURL.path))
            XCTAssertFalse(invocation.contains("alpha"))
            XCTAssertFalse(invocation.contains("zeta"))
            XCTAssertFalse(invocation.contains("-T \(decodingReferenceURL.path)"))
        }
        XCTAssertTrue(consensus.contains("--min-BQ 12"))
        XCTAssertFalse(consensus.contains("--min-MQ"))
        XCTAssertFalse(consensus.contains("-X"))
        XCTAssertTrue(depth.contains("-q 12"))
        XCTAssertFalse(depth.contains("-Q"))

        XCTAssertEqual(result.executionRecords.map(\.stage), [.view, .index, .consensus, .depth])
        XCTAssertTrue(result.executionRecords.allSatisfy { $0.exitStatus == 0 })
        XCTAssertTrue(result.executionRecords.allSatisfy { !$0.reproducibleCommand.isEmpty })
        XCTAssertTrue(result.executionRecords.allSatisfy { !$0.runtimeIdentity.isEmpty })
        XCTAssertEqual(result.executionRecords.first?.executableVersion, "samtools 1.23.1")
        XCTAssertEqual(result.executionRecords.first?.readGroupFile?.contents, "alpha\nzeta\n")
    }

    func testFetchConsensusWholeContigAcceptsBareCallerHeader() async throws {
        // End-to-end guard for the EsViritu whole-contig failure: when the
        // requested region spans the entire contig, `samtools consensus` emits
        // a bare ">chrom" header with no coordinate suffix. The pipeline must
        // still project that output onto the requested interval instead of
        // failing with a coordinate mismatch.
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-consensus-whole-contig")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("evidence.bam")
        let sourceIndexURL = tempDir.appendingPathComponent("evidence.bam.bai")
        try Data("source".utf8).write(to: sourceURL)
        try Data("index".utf8).write(to: sourceIndexURL)
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        case "$1" in
        --version)
            printf 'samtools 1.24\n'
            ;;
        view)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-o" ]; then
                    printf 'filtered BAM' > "$2"
                    break
                fi
                shift
            done
            ;;
        index)
            printf 'filtered index' > "$3"
            ;;
        consensus)
            printf '>chrSynthetic\nACGTA\n'
            ;;
        depth)
            printf 'chrSynthetic\t1\t5\nchrSynthetic\t2\t5\nchrSynthetic\t3\t5\nchrSynthetic\t4\t5\nchrSynthetic\t5\t5\n'
            ;;
        *)
            exit 9
            ;;
        esac
        """)
        let provider = AlignmentDataProvider(
            alignmentPath: sourceURL.path,
            indexPath: sourceIndexURL.path,
            samtoolsPath: script.path
        )

        let result = try await provider.fetchConsensus(
            consensusRequest(start: 0, end: 5, minimumDepth: 1)
        )

        XCTAssertEqual(result.sequence, "ACGTA")
        XCTAssertEqual(result.referenceLength, 5)
        XCTAssertFalse(result.allLowDepth)
    }

    func testFetchConsensusRecordsChecksummedStdoutArtifacts() async throws {
        // Would fail if consensus or depth stdout were consumed without being
        // represented as a checksummed, sized scientific output artifact.
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-consensus-stdout-provenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("evidence.bam")
        let sourceIndexURL = tempDir.appendingPathComponent("evidence.bam.bai")
        try Data("source".utf8).write(to: sourceURL)
        try Data("index".utf8).write(to: sourceIndexURL)
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        case "$1" in
        --version)
            printf 'samtools 1.23.1\n'
            ;;
        view)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-o" ]; then
                    printf 'filtered BAM' > "$2"
                    break
                fi
                shift
            done
            ;;
        index)
            printf 'filtered index' > "$3"
            ;;
        consensus)
            printf '>chrSynthetic:11-15\nACGTA\n'
            ;;
        depth)
            printf 'chrSynthetic\t11\t3\nchrSynthetic\t13\t7\nchrSynthetic\t14\t1\n'
            ;;
        *)
            exit 9
            ;;
        esac
        """)
        let provider = AlignmentDataProvider(
            alignmentPath: sourceURL.path,
            indexPath: sourceIndexURL.path,
            samtoolsPath: script.path
        )

        let result = try await provider.fetchConsensus(
            consensusRequest(start: 10, end: 15, minimumDepth: 3)
        )

        let consensusRecord = try XCTUnwrap(result.executionRecords.first { $0.stage == .consensus })
        XCTAssertEqual(consensusRecord.outputs.count, 1)
        let consensusOutput = try XCTUnwrap(consensusRecord.outputs.first)
        XCTAssertTrue(consensusOutput.path.hasSuffix("/consensus.fasta"))
        XCTAssertEqual(consensusOutput.checksumSHA256, "31b000b699089c4e51432c9d46559dc9393a9870b35fcabadba8ae237d1da9df")
        XCTAssertEqual(consensusOutput.fileSize, 26)

        let depthRecord = try XCTUnwrap(result.executionRecords.first { $0.stage == .depth })
        XCTAssertEqual(depthRecord.outputs.count, 1)
        let depthOutput = try XCTUnwrap(depthRecord.outputs.first)
        XCTAssertTrue(depthOutput.path.hasSuffix("/depth.tsv"))
        XCTAssertEqual(depthOutput.checksumSHA256, "d6cf71c1dcdd6167715b14f3e94237c637a7cbd7fcae04227916eeb179d80c76")
        XCTAssertEqual(depthOutput.fileSize, 54)
    }

    func testFetchConsensusCoordinateMismatchPreservesStageRecords() async throws {
        // Would fail if post-subprocess projection validation discarded the
        // four successful scientific execution records from the thrown error.
        let tempDir = try makeTemporaryDirectory(prefix: "alignment-consensus-mismatch-provenance")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("evidence.bam")
        let sourceIndexURL = tempDir.appendingPathComponent("evidence.bam.bai")
        try Data("source".utf8).write(to: sourceURL)
        try Data("index".utf8).write(to: sourceIndexURL)
        let script = try makeFakeSamtools(in: tempDir, script: """
        #!/bin/sh
        case "$1" in
        --version)
            printf 'samtools 1.23.1\n'
            ;;
        view)
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-o" ]; then
                    printf 'filtered BAM' > "$2"
                    break
                fi
                shift
            done
            ;;
        index)
            printf 'filtered index' > "$3"
            ;;
        consensus)
            printf '>chrSynthetic:11-14\nACGT\n'
            ;;
        depth)
            printf 'chrSynthetic\t11\t3\nchrSynthetic\t12\t3\nchrSynthetic\t13\t3\nchrSynthetic\t14\t3\n'
            ;;
        *)
            exit 9
            ;;
        esac
        """)
        let provider = AlignmentDataProvider(
            alignmentPath: sourceURL.path,
            indexPath: sourceIndexURL.path,
            samtoolsPath: script.path
        )

        do {
            _ = try await provider.fetchConsensus(
                consensusRequest(start: 10, end: 15, minimumDepth: 3)
            )
            XCTFail("Expected coordinate mismatch")
        } catch let AlignmentFetchError.consensusCoordinateMismatchWithRecords(records) {
            XCTAssertEqual(records.map(\.stage), [.view, .index, .consensus, .depth])
            XCTAssertTrue(records.allSatisfy { $0.exitStatus == 0 })
            XCTAssertTrue(records.suffix(2).allSatisfy {
                $0.outputs.count == 1
                    && $0.outputs[0].checksumSHA256 != nil
                    && $0.outputs[0].fileSize != nil
            })
        } catch {
            XCTFail("Expected coordinate mismatch with records, got \(error)")
        }
    }

    // MARK: - AlignmentMetadataDatabase Parsing (inline data tests)

    func testIdxstatsParsingViaMetadataDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-idxstats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        let idxstatsOutput = """
        chr1\t248956422\t15000000\t50000
        chr2\t242193529\t12000000\t40000
        chrX\t156040895\t5000000\t20000
        *\t0\t0\t100000
        """
        db.populateFromIdxstats(idxstatsOutput)

        XCTAssertEqual(db.totalMappedReads(), 32_000_000)
        // populateFromIdxstats skips the '*' unmapped summary line — only per-chromosome unmapped
        XCTAssertEqual(db.totalUnmappedReads(), 110_000) // 50000 + 40000 + 20000
    }

    func testFlagstatParsingViaMetadataDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-flagstat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        let flagstatOutput = """
        50000000 + 0 in total (QC-passed reads + QC-failed reads)
        1000000 + 0 secondary
        500000 + 0 supplementary
        200000 + 0 duplicates
        48000000 + 0 mapped (96.00% : N/A)
        40000000 + 0 paired in sequencing
        20000000 + 0 read1
        20000000 + 0 read2
        38000000 + 0 properly paired (95.00% : N/A)
        39000000 + 0 with itself and mate mapped
        500000 + 0 singletons (1.25% : N/A)
        100000 + 0 with mate mapped to a different chr
        50000 + 0 with mate mapped to a different chr (mapQ>=5)
        """
        db.populateFromFlagstat(flagstatOutput)

        // Verify flagstat was parsed — populateFromFlagstat should not crash
        // The database stores these as flag_stat rows via addFlagStatEntry
    }

    // MARK: - Empty/Malformed Input Handling

    func testIdxstatsEmptyOutput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        db.populateFromIdxstats("")
        XCTAssertEqual(db.totalMappedReads(), 0)
        XCTAssertEqual(db.totalUnmappedReads(), 0)
    }

    func testIdxstatsMalformedLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADP-malformed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("test.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)

        // Mix of valid and malformed lines
        let output = """
        chr1\t248956422\t1000\t50
        this_is_malformed
        chr2\t242193529\t2000\t100
        """
        db.populateFromIdxstats(output)

        // Should handle gracefully — only valid lines counted
        XCTAssertEqual(db.totalMappedReads(), 3000)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakeSamtools(in directory: URL, script: String) throws -> URL {
        let url = directory.appendingPathComponent("samtools")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
