import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class ViralVariantCallingPipelineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralVariantCallingPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIVarPipelineUsesNativeVCFOutputAndNoTSVTranslation() throws {
        let pipeline = try makePipeline(caller: .ivar)

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--output-format vcf"))
        XCTAssertFalse(plan.commandLine.contains(".tsv"))
    }

    func testLoFreqCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(caller: .lofreq, advancedArguments: ["--call-indels"])

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--call-indels"))
    }

    func testIVarCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(caller: .ivar, advancedArguments: ["-g", "primers.gff"])

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("ivar variants"))
        XCTAssertTrue(plan.commandLine.contains("-g primers.gff"))
    }

    func testMedakaCommandLineIncludesAdvancedArguments() throws {
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            advancedArguments: ["--chunk_len", "1000"]
        )

        let plan = try pipeline.buildExecutionPlan()

        XCTAssertTrue(plan.commandLine.contains("--chunk_len 1000"))
    }

    func testCallerParametersJSONIncludesAdvancedOptions() async throws {
        let pipeline = try makePipeline(
            caller: .lofreq,
            advancedArguments: ["--call-indels", "--tag", "sample 1"],
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tadvanced-1\tA\tG\t80\tPASS\t.
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()
        let data = try XCTUnwrap(result.callerParametersJSON.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["advancedOptions"] as? String, "--call-indels --tag 'sample 1'")
        XCTAssertEqual(json["advancedArguments"] as? [String], ["--call-indels", "--tag", "sample 1"])
        XCTAssertTrue(result.commandLine.contains("--call-indels --tag 'sample 1'"))
    }

    func testAllCallersUseStagedUncompressedReference() throws {
        for caller in ViralVariantCaller.allCases {
            let pipeline = try makePipeline(caller: caller)
            let plan = try pipeline.buildExecutionPlan()
            XCTAssertTrue(plan.referenceURL.path.hasSuffix(".fa"), "Expected \(caller.rawValue) to stage an uncompressed FASTA")
            XCTAssertFalse(plan.referenceURL.path.hasSuffix(".fa.gz"), "Expected \(caller.rawValue) not to point callers at the bundle's compressed FASTA")
        }
    }

    func testMedakaPipelineUsesSharedBamToFastqConverterAndRejectsMissingMetadata() async throws {
        let converterCalled = LockedFlag()
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: nil,
            bamToFASTQConverter: { _, _, _, _, _, _, _, _ in
                converterCalled.setTrue()
            }
        )

        do {
            _ = try await pipeline.run()
            XCTFail("Expected Medaka pipeline to reject missing model metadata")
        } catch let error as ViralVariantCallingPipelineError {
            XCTAssertEqual(error, .medakaRequiresModelMetadata)
        }

        XCTAssertFalse(converterCalled.value)
    }

    func testMedakaPipelineInvokesSharedBamToFastqConverterBeforeCallerExecution() async throws {
        let converterCalled = LockedFlag()
        let pipeline = try makePipeline(
            caller: .medaka,
            medakaModel: "r1041_e82_400bps_sup_v5.0.0",
            bamToFASTQConverter: { _, outputFASTQ, _, _, _, _, _, _ in
                converterCalled.setTrue()
                try """
                @read-1
                ACGT
                +
                !!!!
                """.write(to: outputFASTQ, atomically: true, encoding: .utf8)
            },
            callerExecutor: { plan, _ in
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                ##INFO=<ID=AF,Number=1,Type=Float,Description="Allele frequency">
                ##INFO=<ID=DP,Number=1,Type=Integer,Description="Read depth">
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\tmedaka-1\tA\tG\t80\tPASS\tAF=0.6;DP=30
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        let result = try await pipeline.run()

        XCTAssertTrue(converterCalled.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.normalizedVCFURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stagedVCFGZURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.stagedTabixURL.path))
    }

    func testAliasMatchedBamIsReheaderedToBundleChromosomesBeforeCallerExecution() async throws {
        let bundleURL = tempDir.appendingPathComponent("alias-bundle.lungfishref", isDirectory: true)
        let referenceURL = tempDir.appendingPathComponent("alias-reference.fa")
        let referenceFAIURL = tempDir.appendingPathComponent("alias-reference.fa.fai")
        let alignmentURL = tempDir.appendingPathComponent("alias.sorted.bam")
        let alignmentIndexURL = tempDir.appendingPathComponent("alias.sorted.bam.bai")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(to: referenceFAIURL, atomically: true, encoding: .utf8)
        try await writeIndexedBAM(referenceName: "1", outputBAM: alignmentURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Alias Bundle",
            identifier: "alias.bundle",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: ["1"])
                ],
                md5Checksum: nil
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Alias BAM",
                    format: .bam,
                    sourcePath: "alignments/alias.sorted.bam",
                    indexPath: "alignments/alias.sorted.bam.bai",
                    checksumSHA256: "alias-bam-sha-256"
                )
            ]
        )

        let preflight = BAMVariantCallingPreflightResult(
            manifest: manifest,
            alignmentTrack: manifest.alignments[0],
            genome: try XCTUnwrap(manifest.genome),
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceFASTAURL: referenceURL,
            referenceFAIURL: referenceFAIURL,
            bamReferenceSequences: [
                SAMParser.ReferenceSequence(name: "1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)
            ],
            referenceNameMap: ["1": "chr1"],
            contigValidation: .matchedByAlias
        )

        let request = BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Alias BAM • LoFreq",
            threads: 1,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10,
            ivarPrimerTrimConfirmed: true,
            medakaModel: nil
        )
        let stagingRoot = tempDir.appendingPathComponent("alias-staging-\(UUID().uuidString)", isDirectory: true)
        let pipeline = ViralVariantCallingPipeline(
            request: request,
            preflight: preflight,
            stagingRoot: stagingRoot,
            callerExecutor: { plan, runner in
                let headerResult = try await runner.run(
                    .samtools,
                    arguments: ["view", "-H", plan.alignmentURL.path],
                    timeout: 60
                )
                XCTAssertTrue(headerResult.isSuccess)
                XCTAssertTrue(headerResult.stdout.contains("SN:chr1"))
                XCTAssertFalse(headerResult.stdout.contains("SN:1\t"))
                try """
                ##fileformat=VCFv4.3
                ##contig=<ID=chr1,length=20>
                #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
                chr1\t5\talias-1\tA\tG\t80\tPASS\t.
                """.write(to: plan.rawVCFURL, atomically: true, encoding: .utf8)
            }
        )

        _ = try await pipeline.run()
    }

    private func makePipeline(
        caller: ViralVariantCaller,
        medakaModel: String? = "unused",
        advancedArguments: [String] = [],
        bamToFASTQConverter: @escaping ViralVariantCallingPipeline.BAMToFASTQConverter = convertBAMToSingleFASTQ,
        callerExecutor: ViralVariantCallingPipeline.CallerExecutor? = nil
    ) throws -> ViralVariantCallingPipeline {
        let bundleURL = tempDir.appendingPathComponent("test.lungfishref", isDirectory: true)
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let referenceFAIURL = tempDir.appendingPathComponent("reference.fa.fai")
        let alignmentURL = tempDir.appendingPathComponent("sample.sorted.bam")
        let alignmentIndexURL = tempDir.appendingPathComponent("sample.sorted.bam.bai")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(to: referenceFAIURL, atomically: true, encoding: .utf8)
        try Data("bam".utf8).write(to: alignmentURL)
        try Data("bai".utf8).write(to: alignmentIndexURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: [])
                ],
                md5Checksum: nil
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha-256"
                )
            ]
        )

        let preflight = BAMVariantCallingPreflightResult(
            manifest: manifest,
            alignmentTrack: manifest.alignments[0],
            genome: try XCTUnwrap(manifest.genome),
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceFASTAURL: referenceURL,
            referenceFAIURL: referenceFAIURL,
            bamReferenceSequences: [
                SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)
            ],
            referenceNameMap: ["chr1": "chr1"],
            contigValidation: .exactMatch
        )

        let request = BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: caller,
            outputTrackName: "Sample BAM • \(caller.displayName)",
            threads: 2,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10,
            ivarPrimerTrimConfirmed: true,
            medakaModel: caller == .medaka ? medakaModel : nil,
            advancedArguments: advancedArguments
        )

        let stagingRoot = tempDir.appendingPathComponent("staging-\(caller.rawValue)-\(UUID().uuidString)", isDirectory: true)
        return ViralVariantCallingPipeline(
            request: request,
            preflight: preflight,
            stagingRoot: stagingRoot,
            bamToFASTQConverter: bamToFASTQConverter,
            callerExecutor: callerExecutor
        )
    }
}

private extension ViralVariantCallingPipelineTests {
    func writeIndexedBAM(referenceName: String, outputBAM: URL) async throws {
        let samURL = tempDir.appendingPathComponent("alias-input.sam")
        try """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:\(referenceName)\tLN:20
        @RG\tID:rg1\tPL:ONT\tDS:basecall_model=r1041_e82_400bps_sup_v5.0.0
        read1\t0\t\(referenceName)\t1\t60\t4M\t*\t0\t0\tACGT\t!!!!
        """.write(to: samURL, atomically: true, encoding: .utf8)

        let bamResult = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: ["view", "-b", "-o", outputBAM.path, samURL.path],
            timeout: 60
        )
        XCTAssertTrue(bamResult.isSuccess, bamResult.combinedOutput)

        let indexResult = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: ["index", outputBAM.path],
            timeout: 60
        )
        XCTAssertTrue(indexResult.isSuccess, indexResult.combinedOutput)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func setTrue() {
        lock.lock()
        state = true
        lock.unlock()
    }
}
