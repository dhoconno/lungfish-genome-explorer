import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTGenotypingPipelineTests: XCTestCase {
    func testPipelineMapsEachInputWithShortReadPresetFiltersWithPysamAndWritesInvocationReportAndProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-genotyping-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let reference = root.appendingPathComponent("mhc.fasta")
        try ">DQA1*01\nACGT\n>DQB1*06\nACGT\n".write(to: reference, atomically: true, encoding: .utf8)

        let inputA = try makeFASTQBundle(named: "FLD0001", in: root)
        let inputB = try makeFASTQBundle(named: "FLD0002", in: root)
        let output = root.appendingPathComponent("out", isDirectory: true)

        let mappingRunner = StubONTMappingRunner { request, _ in
            XCTAssertEqual(request.tool, .minimap2)
            XCTAssertEqual(request.modeID, MappingMode.defaultShortRead.id)
            XCTAssertEqual(request.compatibilityReadClassOverride, .illuminaShortReads)
            XCTAssertTrue(request.includeSecondary)
            XCTAssertEqual(request.minimumMappingQuality, 0)
            XCTAssertEqual(request.readGroup?.platform, "ILLUMINA")

            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            let bam = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam")
            let bai = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam.bai")
            try Data("BAM \(request.sampleName)".utf8).write(to: bam)
            try Data("BAI \(request.sampleName)".utf8).write(to: bai)
            return MappingResult(
                mapper: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                bamURL: bam,
                baiURL: bai,
                totalReads: request.sampleName == "FLD0001" ? 14730 : 100,
                mappedReads: request.sampleName == "FLD0001" ? 14542 : 92,
                unmappedReads: request.sampleName == "FLD0001" ? 188 : 8,
                wallClockSeconds: 1.25,
                contigs: [
                    MappingContigSummary(
                        contigName: "raw-zero-hit",
                        contigLength: 156,
                        mappedReads: 0,
                        mappedReadPercent: 0,
                        meanDepth: 0,
                        coverageBreadth: 0,
                        medianMAPQ: 0,
                        meanIdentity: 0
                    )
                ]
            )
        }
        let filterRunner = StubONTFilterRunner { request in
            XCTAssertTrue(request.pythonArguments.contains("--require-both-end-softclips"))
            XCTAssertTrue(request.pythonArguments.contains("--require-full-reference-span"))
            XCTAssertTrue(request.pythonArguments.contains("--allow-indels"))
            XCTAssertTrue(request.pythonArguments.contains("--max-mismatches"))
            XCTAssertTrue(request.pythonArguments.contains("0"))
            try FileManager.default.createDirectory(at: request.outputBAMURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("filtered".utf8).write(to: request.outputBAMURL)
            try Data("index".utf8).write(to: request.outputBAMURL.appendingPathExtension("bai"))
            return ONTGenotypingFilterResult(
                inputBAMURL: request.inputBAMURL,
                outputBAMURL: request.outputBAMURL,
                outputBAIURL: request.outputBAMURL.appendingPathExtension("bai"),
                totalAlignments: 12,
                passedAlignments: request.sampleName == "FLD0001" ? 6 : 2,
                genotypeCounts: request.sampleName == "FLD0001"
                    ? [
                        ONTGenotypingGenotypeCount(genotype: "DQA1*01", filteredIndelOnlyMappedReads: 3),
                        ONTGenotypingGenotypeCount(genotype: "DQB1*06", filteredIndelOnlyMappedReads: 2),
                        ONTGenotypingGenotypeCount(genotype: "DQB1*low", filteredIndelOnlyMappedReads: 1),
                        ONTGenotypingGenotypeCount(genotype: "raw-zero-hit", filteredIndelOnlyMappedReads: 0),
                    ]
                    : [
                        ONTGenotypingGenotypeCount(genotype: "DQA1*01", filteredIndelOnlyMappedReads: 2),
                    ],
                stdout: "ok",
                stderr: "",
                exitCode: 0,
                wallClockSeconds: 0.5
            )
        }

        let request = ONTGenotypingRunRequest(
            inputFASTQURLs: [inputA, inputB],
            referenceSourceURL: reference,
            outputDirectory: output,
            outputName: "mhc-ont-genotyping",
            projectURL: nil,
            threads: 8,
            minSupport: 2,
            extraArguments: ["--tag", "NM"]
        )

        let result = try await ONTGenotypingPipeline(
            mappingRunner: mappingRunner,
            filterRunner: filterRunner
        ).run(request)

        XCTAssertEqual(result.sampleResults.count, 2)
        XCTAssertEqual(result.reportCSVURL.lastPathComponent, "mhc-ont-genotyping.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportCSVURL.path))

        let csv = try String(contentsOf: result.reportCSVURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("input_bundle_name,genotype,filtered_indel_only_mapped_reads,total_reads"))
        XCTAssertTrue(csv.contains("FLD0001,DQA1*01,3,14730"))
        XCTAssertTrue(csv.contains("FLD0001,DQB1*06,2,14730"))
        XCTAssertTrue(csv.contains("FLD0002,DQA1*01,2,100"))
        XCTAssertFalse(csv.contains("DQB1*low"))
        XCTAssertFalse(csv.contains("raw-zero-hit"))

        let filteredMapping = try MappingResult.load(
            from: output.appendingPathComponent("FLD0001", isDirectory: true)
        )
        XCTAssertEqual(filteredMapping.bamURL.lastPathComponent, "FLD0001.ont-genotyping.filtered.bam")
        XCTAssertEqual(filteredMapping.baiURL.lastPathComponent, "FLD0001.ont-genotyping.filtered.bam.bai")
        XCTAssertEqual(filteredMapping.mappedReads, 6)
        XCTAssertEqual(filteredMapping.contigs.map(\.contigName), ["DQA1*01", "DQB1*06", "DQB1*low"])
        XCTAssertEqual(filteredMapping.contigs.map(\.mappedReads), [3, 2, 1])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: output
                    .appendingPathComponent("FLD0001", isDirectory: true)
                    .appendingPathComponent("raw-mapping-result.json")
                    .path
            )
        )

        let sampleEnvelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(from: output.appendingPathComponent("FLD0001", isDirectory: true))
        )
        XCTAssertEqual(sampleEnvelope.workflowName, "ONT Genotyping")
        XCTAssertEqual(sampleEnvelope.argv, request.argv)
        XCTAssertEqual(sampleEnvelope.durableReplayArgv, request.argv)
        XCTAssertEqual(
            sampleEnvelope.output.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            "FLD0001.ont-genotyping.filtered.bam"
        )
        XCTAssertFalse(
            sampleEnvelope.reproducibleCommand.contains(" lungfish map "),
            "Filtered ONT genotyping sidecar provenance must not replay only the raw mapper."
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(envelope.workflowName, "ONT Genotyping")
        XCTAssertEqual(envelope.toolName, "pysam")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.explicit["minSupport"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["mappingPreset"], .string("sr"))
        XCTAssertTrue(envelope.runtimeIdentity.condaEnvironment?.contains("pysam") == true)
    }

    private func makeFASTQBundle(named name: String, in root: URL) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("\(name).fastq")
        try "@\(name)-read1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        let manifest = FASTQDerivedBundleManifest(
            name: name,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: fastqURL.lastPathComponent,
            payload: .full(fastqFilename: fastqURL.lastPathComponent),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: 1),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: .singleEnd,
            sequenceFormat: .fastq,
            payloadChecksums: nil,
            materializationState: .materialized(checksum: "")
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }
}

private struct StubONTMappingRunner: ONTGenotypingMappingRunning {
    let handler: @Sendable (MappingRunRequest, (@Sendable (Double, String) -> Void)?) async throws -> MappingResult

    func runMapping(
        request: MappingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> MappingResult {
        try await handler(request, progressHandler)
    }
}

private struct StubONTFilterRunner: ONTGenotypingPysamFiltering {
    let handler: @Sendable (ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult

    func filter(_ request: ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult {
        try await handler(request)
    }
}
