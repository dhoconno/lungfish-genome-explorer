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
    }

    func testCallSubcommandParsesBundleAlignmentAndCaller() throws {
        let command = try VariantsCommand.CallSubcommand.parse([
            "call",
            "--bundle", "/tmp/Test.lungfishref",
            "--alignment-track", "aln-1",
            "--caller", "lofreq",
            "--format", "json",
        ])

        XCTAssertEqual(command.bundlePath, "/tmp/Test.lungfishref")
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.caller, "lofreq")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
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

    private func makeRuntime() throws -> VariantsCommand.Runtime {
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
            preflight: { _ in preflight },
            runPipeline: { _, _, _ in pipelineResult },
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
