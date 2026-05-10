import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class VariantsCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantsCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testVariantsCommandNameAndHelp() {
        XCTAssertEqual(VariantsCommand.configuration.commandName, "variants")
        XCTAssertTrue(VariantsCommand.helpMessage().contains("call"))
        XCTAssertTrue(VariantsCommand.helpMessage().contains("extract-sample"))
        XCTAssertTrue(VariantsCommand.helpMessage().contains("query"))
    }

    func testExtractSampleSubcommandWritesSingleSampleVCFAndProvenance() async throws {
        let bundleURL = try makeVariantBundleFixture()
        let outputURL = tempDir.appendingPathComponent("NA12878.vcf")
        let command = try VariantsCommand.ExtractSampleSubcommand.parse([
            "extract-sample",
            bundleURL.path,
            "--sample", "NA12878",
            "--output", outputURL.path,
            "--quiet",
        ])

        try await command.executeForTesting()

        let vcf = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(vcf.contains("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878"))
        XCTAssertFalse(vcf.contains("NA12879"))
        XCTAssertTrue(vcf.contains("rs100"))
        XCTAssertTrue(vcf.contains("rs300"))

        let provenanceURL = outputURL.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        XCTAssertEqual(run.name, "lungfish variants extract-sample")
        XCTAssertEqual(run.steps.first?.toolName, "lungfish variants extract-sample")
        XCTAssertEqual(run.steps.first?.exitCode, 0)
        XCTAssertEqual(run.steps.first?.outputs.first?.path, outputURL.path)
        XCTAssertEqual(run.parameters["sample"]?.stringValue, "NA12878")
    }

    func testQuerySubcommandFiltersWithSmartFilter() async throws {
        let bundleURL = try makeVariantBundleFixture()
        let outputURL = tempDir.appendingPathComponent("filtered.vcf")
        let command = try VariantsCommand.QuerySubcommand.parse([
            "query",
            bundleURL.path,
            "--filter", "Sample[NA12878].GT=1/1",
            "--output", outputURL.path,
            "--quiet",
        ])

        try await command.executeForTesting()

        let vcf = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(vcf.contains("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878\tNA12879"))
        XCTAssertTrue(vcf.contains("rs100"))
        XCTAssertFalse(vcf.contains("rs200"))
        XCTAssertTrue(vcf.contains("rs300"))

        let provenanceURL = outputURL.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: provenanceURL))
        XCTAssertEqual(run.name, "lungfish variants query")
        XCTAssertEqual(run.steps.first?.toolName, "lungfish variants query")
        XCTAssertEqual(run.parameters["filter"]?.stringValue, "Sample[NA12878].GT=1/1")
    }

    func testCallSubcommandParsesBundleAlignmentAndCaller() throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--advanced-options", #"--call-indels --tag "sample 1""#,
            "--format", "json",
        ])

        XCTAssertEqual(command.bundlePath, "/tmp/Test.lungfishref")
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.caller, "lofreq")
        XCTAssertEqual(command.advancedOptions, #"--call-indels --tag "sample 1""#)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testCallSubcommandPassesAdvancedOptionsToRuntime() async throws {
        let capture = CapturedVariantRequest()
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--advanced-options", #"--call-indels --tag "sample 1""#,
            "--format", "json",
        ])
        let runtime = try makeRuntime(onPreflight: { request in
            capture.request = request
        })
        var lines: [String] = []

        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        XCTAssertEqual(capture.request?.advancedArguments, ["--call-indels", "--tag", "sample 1"])
    }

    func testCallSubcommandAcceptsBcftoolsCallerAndPassesRequestToRuntime() async throws {
        let capture = CapturedVariantRequest()
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "bcftools",
            "--extra-args", "--ploidy 1",
            "--format", "json",
        ])
        let runtime = try makeRuntime(onPreflight: { request in
            capture.request = request
        })

        _ = try await command.executeForTesting(runtime: runtime) { _ in }

        XCTAssertEqual(capture.request?.caller.rawValue, "bcftools")
        XCTAssertEqual(capture.request?.advancedArguments, ["--ploidy", "1"])
    }

    func testCallSubcommandKeepsAdvancedOptionsAliasForExistingScripts() throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "bcftools",
            "--advanced-options", "--ploidy 1",
            "--format", "json",
        ])

        XCTAssertEqual(command.advancedOptions, "--ploidy 1")
    }

    func testCallSubcommandEmitsRunCompleteJSON() async throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--format", "json",
        ])
        let runtime = try makeRuntime()
        var lines: [String] = []

        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        XCTAssertTrue(lines.contains { $0.contains(#""event":"runComplete""#) })
        XCTAssertTrue(lines.contains { $0.contains(#""variantTrackID":"vc-1""#) })
    }

    func testImportCompleteJSONOmitsTransientDatabasePath() async throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--format", "json",
        ])
        let runtime = try makeRuntime()
        var lines: [String] = []

        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let importEvent = try XCTUnwrap(
            lines
                .compactMap(decodeEvent)
                .first(where: { $0.event == "importComplete" })
        )
        XCTAssertNil(importEvent.databasePath)

        let runCompleteEvent = try XCTUnwrap(
            lines
                .compactMap(decodeEvent)
                .first(where: { $0.event == "runComplete" })
        )
        XCTAssertNotNil(runCompleteEvent.databasePath)
    }

    func testCallSubcommandUsesSystemTempStagingForBundlePathsWithSpaces() async throws {
        let spacedBundleURL = tempDir
            .appendingPathComponent("Project With Spaces.lungfish", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", spacedBundleURL.path,
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--format", "json",
        ])
        let capture = CapturedVariantStaging()
        let runtime = try makeRuntime { context in
            capture.root = context.stagingRoot
            capture.marker = ProjectTempDirectory.readMarker(from: context.stagingRoot)
        }
        var lines: [String] = []

        _ = try await command.executeForTesting(runtime: runtime) { lines.append($0) }

        let stagingRoot = try XCTUnwrap(capture.root)
        XCTAssertFalse(stagingRoot.path.contains("Project With Spaces.lungfish"))
        XCTAssertEqual(capture.marker?.policy, .systemOnly)
        XCTAssertTrue(lines.contains { $0.contains(#""event":"runComplete""#) })
    }

    func testCallSubcommandEmitsRunFailedJSON() async throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", tempDir.path,
            "--alignment-track", "aln-1",
            "--caller", "medaka",
            "--format", "json",
        ])
        let runtime = VariantsCommand.Runtime(
            preflight: { _ in
                throw BAMVariantCallingPreflightError.medakaRequiresModelMetadata
            },
            runPipeline: { _, _, _ in
                XCTFail("Pipeline should not run when preflight fails")
                fatalError("unreachable")
            },
            importSQLite: { _, _ in
                XCTFail("Import should not run when preflight fails")
                fatalError("unreachable")
            },
            attachTrack: { _ in
                XCTFail("Attach should not run when preflight fails")
                fatalError("unreachable")
            }
        )
        var lines: [String] = []

        await XCTAssertThrowsErrorAsync(
            try await command.executeForTesting(runtime: runtime) { lines.append($0) }
        )

        XCTAssertTrue(lines.contains { $0.contains(#""event":"runFailed""#) })
        XCTAssertTrue(lines.contains { $0.contains("Medaka requires ONT model metadata") })
    }

    private func makeRuntime(
        onRunPipeline: (@Sendable (VariantsCommand.CallContext) -> Void)? = nil,
        onPreflight: (@Sendable (BundleVariantCallingRequest) -> Void)? = nil
    ) throws -> VariantsCommand.Runtime {
        let bundleURL = tempDir.appendingPathComponent("Bundle.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let finalVCFURL = tempDir.appendingPathComponent("variants.vcf.gz")
        let finalTBIURL = tempDir.appendingPathComponent("variants.vcf.gz.tbi")
        let finalDBURL = tempDir.appendingPathComponent("variants.db")
        try Data("vcf".utf8).write(to: finalVCFURL)
        try Data("tbi".utf8).write(to: finalTBIURL)
        try Data("db".utf8).write(to: finalDBURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Bundle",
            identifier: "bundle.test",
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
            alignmentURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            alignmentIndexURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
            referenceFAIURL: tempDir.appendingPathComponent("reference.fa.fai"),
            bamReferenceSequences: [
                SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)
            ],
            referenceNameMap: ["chr1": "chr1"],
            contigValidation: .exactMatch
        )
        let pipelineResult = ViralVariantCallingPipelineResult(
            normalizedVCFURL: tempDir.appendingPathComponent("normalized.vcf"),
            stagedVCFGZURL: finalVCFURL,
            stagedTabixURL: finalTBIURL,
            referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
            referenceFASTASHA256: "reference-sha",
            callerVersion: "1.0.0",
            callerParametersJSON: #"{"caller":"lofreq"}"#
        )
        let trackInfo = VariantTrackInfo(
            id: "vc-1",
            name: "Sample BAM • LoFreq",
            description: "LoFreq variants from Sample BAM",
            path: "variants/vc-1.vcf.gz",
            indexPath: "variants/vc-1.vcf.gz.tbi",
            databasePath: "variants/vc-1.db",
            variantType: .mixed,
            variantCount: 2,
            source: "LoFreq",
            version: "1.0.0"
        )

        return VariantsCommand.Runtime(
            preflight: { request in
                onPreflight?(request)
                return preflight
            },
            runPipeline: { _, _, context in
                onRunPipeline?(context)
                return pipelineResult
            },
            importSQLite: { _, _ in
                VariantSQLiteImportResult(
                    databaseURL: finalDBURL,
                    variantCount: 2,
                    didResumeIndexBuild: false,
                    didResumeMaterialization: false
                )
            },
            attachTrack: { _ in
                BundleVariantTrackAttachmentResult(
                    trackInfo: trackInfo,
                    finalVCFGZURL: finalVCFURL,
                    finalTabixURL: finalTBIURL,
                    finalDatabaseURL: finalDBURL
                )
            }
        )
    }

    private func makeVariantBundleFixture() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("Cohort.lungfishref", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        let vcfURL = tempDir.appendingPathComponent("cohort.vcf")
        let dbURL = variantsDir.appendingPathComponent("cohort.db")
        try cohortVCF.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, parseGenotypes: true)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Cohort",
            identifier: "test.cohort",
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            genome: nil,
            variants: [
                VariantTrackInfo(
                    id: "cohort",
                    name: "Cohort",
                    path: "variants/cohort.vcf.gz",
                    indexPath: "variants/cohort.vcf.gz.tbi",
                    databasePath: "variants/cohort.db",
                    variantType: .mixed,
                    variantCount: 3,
                    source: "Fixture"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent(BundleManifest.filename))
        return bundleURL
    }

    private var cohortVCF: String {
        """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">
        ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allele depths">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878\tNA12879
        chr1\t100\trs100\tA\tG\t60\tPASS\t.\tGT:DP:AD\t1/1:35:0,35\t0/1:32:16,16
        chr1\t200\trs200\tC\tT\t50\tPASS\t.\tGT:DP:AD\t0/1:20:10,10\t0/1:22:11,11
        chr1\t300\trs300\tG\tA\t70\tPASS\t.\tGT:DP:AD\t1/1:31:0,31\t1/1:34:0,34
        """
    }
}

private final class CapturedVariantStaging: @unchecked Sendable {
    var root: URL?
    var marker: ProjectTempDirectory.TempOriginMarker?
}

private final class CapturedVariantRequest: @unchecked Sendable {
    var request: BundleVariantCallingRequest?
}

private func decodeEvent(_ line: String) -> VariantsCommand.VariantCallingEvent? {
    guard let data = line.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(VariantsCommand.VariantCallingEvent.self, from: data)
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
    }
}
