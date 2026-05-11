import XCTest
@testable import LungfishWorkflow

final class GATKPipelineExecutorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GATKPipelineExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRunsInjectedHaplotypeCallerAndWritesFinalLocationProvenance() async throws {
        let reference = try write("reference.fa", contents: ">chr1\nACGT\n")
        let bam = try write("sample.bam", contents: "bam-bytes")
        let output = tempDir.appendingPathComponent("sample.g.vcf.gz")
        let config = GATKHaplotypeCallerConfiguration(
            referenceFASTAURL: reference,
            inputBAMURL: bam,
            outputVCFURL: output
        )
        let command = GATKCommandBuilder.haplotypeCallerCommand(config)
        let runner = RecordingGATKCommandRunner { _ in
            try Data("gvcf-bytes".utf8).write(to: output)
            return GATKCommandExecutionResult(
                exitCode: 0,
                stdout: "created sample.g.vcf.gz",
                stderr: "gatk stderr summary",
                wallTime: 12.5
            )
        }
        let executor = GATKPipelineExecutor(runner: runner)
        let request = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: config,
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(
                condaEnvironment: "/tmp/conda/envs/gatk-core",
                containerImage: nil,
                containerDigest: nil
            ),
            packVersion: "0.4.0-alpha.12"
        )

        let result = try await executor.run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.provenanceURL, tempDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let recordedCommands = await runner.recordedCommands()
        XCTAssertEqual(recordedCommands.map(\.shellCommand), [command.shellCommand])

        let provenance = try decodeProvenance(at: result.provenanceURL)
        XCTAssertEqual(provenance.name, "GATK HaplotypeCaller")
        XCTAssertEqual(provenance.status.rawValue, RunStatus.completed.rawValue)
        XCTAssertEqual(provenance.steps.count, 1)
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolName, "gatk-haplotype-caller")
        XCTAssertEqual(step.toolVersion, "4.6.2.0")
        XCTAssertEqual(step.command, ["gatk"] + command.arguments)
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertEqual(step.wallTime, 12.5)
        XCTAssertEqual(step.stderr, "gatk stderr summary")
        XCTAssertEqual(step.inputs.count, 2)
        XCTAssertEqual(step.outputs.count, 1)
        XCTAssertEqual(step.outputs.first?.path, output.path)
        XCTAssertEqual(step.outputs.first?.sizeBytes, 10)
        XCTAssertNotNil(step.outputs.first?.sha256)
        XCTAssertEqual(step.containerImage, nil)
        XCTAssertEqual(step.containerDigest, nil)
        XCTAssertEqual(provenance.parameters["toolEnvironment"]?.stringValue, "gatk-core")
        XCTAssertEqual(provenance.parameters["packID"]?.stringValue, "gatk-core")
        XCTAssertEqual(provenance.parameters["packVersion"]?.stringValue, "0.4.0-alpha.12")
        XCTAssertEqual(provenance.parameters["condaEnvironment"]?.stringValue, "/tmp/conda/envs/gatk-core")
        XCTAssertEqual(provenance.parameters["option.emitReferenceConfidence"]?.stringValue, "GVCF")
        XCTAssertEqual(provenance.parameters["default.ploidy"]?.stringValue, "2")
    }

    func testRunsInjectedVariantsToTableAndWritesFinalLocationProvenance() async throws {
        let vcf = try write("cohort.vcf.gz", contents: "vcf-bytes")
        let finalDirectory = tempDir.appendingPathComponent("final", isDirectory: true)
        let output = finalDirectory.appendingPathComponent("cohort.tsv")
        let config = GATKVariantsToTableConfiguration(
            inputVCFURL: vcf,
            outputTableURL: output,
            fields: ["CHROM", "POS", "GT"]
        )
        let runner = RecordingGATKCommandRunner { command in
            XCTAssertEqual(command.arguments.first, "VariantsToTable")
            try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
            try Data("CHROM\tPOS\tGT\n".utf8).write(to: output)
            return GATKCommandExecutionResult(
                exitCode: 0,
                stdout: "wrote final/cohort.tsv",
                stderr: "",
                wallTime: 1.25
            )
        }
        let executor = GATKPipelineExecutor(runner: runner)
        let request = GATKPipelineExecutionRequest.variantsToTable(
            configuration: config,
            toolVersion: "4.6.2.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core"),
            packVersion: "0.4.0-alpha.12"
        )

        let result = try await executor.run(request)

        XCTAssertEqual(result.provenanceURL, finalDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        let provenance = try decodeProvenance(at: result.provenanceURL)
        XCTAssertEqual(provenance.name, "GATK VariantsToTable")
        XCTAssertEqual(provenance.steps.map(\.toolName), ["gatk-variants-to-table"])
        XCTAssertEqual(provenance.steps.first?.outputs.first?.path, output.path)
        XCTAssertEqual(provenance.steps.first?.outputs.first?.sizeBytes, 13)
        XCTAssertEqual(provenance.parameters["packID"]?.stringValue, "gatk-core")
        XCTAssertEqual(provenance.parameters["option.fields"]?.stringValue, #"["CHROM","POS","GT"]"#)
        let provenanceJSON = try String(contentsOf: result.provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceJSON.contains("/staging/"))
    }

    func testExecutionRequestFactoriesCoverAllWrappedGATKCommandsWithGATKCoreRuntime() throws {
        let runtime = GATKRuntimeIdentity(condaEnvironment: "/tmp/conda/envs/gatk-core")
        let requests: [GATKPipelineExecutionRequest] = [
            .haplotypeCaller(
                configuration: GATKHaplotypeCallerConfiguration(
                    referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
                    inputBAMURL: tempDir.appendingPathComponent("sample.bam"),
                    outputVCFURL: tempDir.appendingPathComponent("sample.g.vcf.gz")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .jointGenotype(
                configuration: GATKJointGenotypingConfiguration(
                    referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
                    inputGVCFURLs: [
                        tempDir.appendingPathComponent("s1.g.vcf.gz"),
                        tempDir.appendingPathComponent("s2.g.vcf.gz"),
                    ],
                    outputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    intermediateURL: tempDir.appendingPathComponent("cohort.combined.g.vcf.gz"),
                    strategy: .combineGVCFs
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .variantFiltration(
                configuration: GATKVariantFiltrationConfiguration(
                    inputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    outputVCFURL: tempDir.appendingPathComponent("cohort.filtered.vcf.gz")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .selectVariants(
                configuration: GATKSelectVariantsConfiguration(
                    inputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    outputVCFURL: tempDir.appendingPathComponent("sample.vcf.gz"),
                    sampleID: "sample"
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .variantsToTable(
                configuration: GATKVariantsToTableConfiguration(
                    inputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    outputTableURL: tempDir.appendingPathComponent("cohort.tsv")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .baseQualityScoreRecalibration(
                configuration: GATKBaseQualityScoreRecalibrationConfiguration(
                    referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
                    inputBAMURL: tempDir.appendingPathComponent("sample.bam"),
                    outputBAMURL: tempDir.appendingPathComponent("sample.recal.bam"),
                    knownSitesVCFURLs: [tempDir.appendingPathComponent("dbsnp.vcf.gz")],
                    recalibrationTableURL: tempDir.appendingPathComponent("sample.recal.table")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .markDuplicates(
                configuration: GATKMarkDuplicatesConfiguration(
                    inputBAMURLs: [tempDir.appendingPathComponent("sample.bam")],
                    outputBAMURL: tempDir.appendingPathComponent("sample.markdup.bam"),
                    metricsURL: tempDir.appendingPathComponent("sample.markdup.metrics.txt")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .validateSamFile(
                configuration: GATKValidateSamFileConfiguration(
                    inputBAMURL: tempDir.appendingPathComponent("sample.bam"),
                    outputReportURL: tempDir.appendingPathComponent("sample.validate.txt")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .leftAlignAndTrimVariants(
                configuration: GATKLeftAlignAndTrimVariantsConfiguration(
                    referenceFASTAURL: tempDir.appendingPathComponent("reference.fa"),
                    inputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    outputVCFURL: tempDir.appendingPathComponent("cohort.left.vcf.gz")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
            .collectVariantCallingMetrics(
                configuration: GATKCollectVariantCallingMetricsConfiguration(
                    inputVCFURL: tempDir.appendingPathComponent("cohort.vcf.gz"),
                    outputMetricsPrefixURL: tempDir.appendingPathComponent("metrics/cohort"),
                    dbSNPVCFURL: tempDir.appendingPathComponent("dbsnp.vcf.gz")
                ),
                toolVersion: "4.6.2.0",
                runtimeIdentity: runtime
            ),
        ]

        XCTAssertEqual(requests.count, 10)
        XCTAssertEqual(Set(requests.map(\.packID)), ["gatk-core"])
        XCTAssertTrue(requests.allSatisfy { !$0.inputs.isEmpty })
        XCTAssertTrue(requests.allSatisfy { !$0.outputs.isEmpty })
        XCTAssertTrue(requests.allSatisfy { !$0.options.isEmpty })
        XCTAssertTrue(requests.allSatisfy { !$0.resolvedDefaults.isEmpty })
        XCTAssertTrue(requests.allSatisfy { !$0.commands.isEmpty })
        XCTAssertTrue(requests.allSatisfy { $0.runtimeIdentity.condaEnvironment == "/tmp/conda/envs/gatk-core" })
        XCTAssertEqual(requests.flatMap(\.commands).map(\.environment).uniqued(), ["gatk-core"])
    }

    func testWritesFailedProvenanceBeforeThrowingOnNonZeroExit() async throws {
        let reference = try write("reference.fa", contents: ">chr1\nACGT\n")
        let bam = try write("sample.bam", contents: "bam-bytes")
        let output = tempDir.appendingPathComponent("sample.g.vcf.gz")
        let command = GATKCommandBuilder.haplotypeCallerCommand(
            GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: reference,
                inputBAMURL: bam,
                outputVCFURL: output
            )
        )
        let runner = RecordingGATKCommandRunner { _ in
            GATKCommandExecutionResult(
                exitCode: 7,
                stdout: "",
                stderr: "missing sequence dictionary",
                wallTime: 0.25
            )
        }
        let executor = GATKPipelineExecutor(runner: runner)
        let request = GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: "4.6.2.0",
            command: command,
            outputDirectory: tempDir,
            inputs: [
                GATKFileArtifact(url: reference, format: .fasta, role: .reference),
                GATKFileArtifact(url: bam, format: .bam, role: .input),
            ],
            outputs: [GATKFileArtifact(url: output, format: .vcf, role: .output)],
            options: [:],
            resolvedDefaults: ["ploidy": "2"]
        )

        do {
            _ = try await executor.run(request)
            XCTFail("Expected non-zero GATK exit to throw.")
        } catch let error as GATKPipelineExecutionError {
            guard case .commandFailed(let exitCode, let provenanceURL) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertEqual(exitCode, 7)
            XCTAssertEqual(provenanceURL, tempDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        }

        let provenance = try decodeProvenance(at: tempDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        XCTAssertEqual(provenance.status.rawValue, RunStatus.failed.rawValue)
        XCTAssertEqual(provenance.steps.first?.exitCode, 7)
        XCTAssertEqual(provenance.steps.first?.stderr, "missing sequence dictionary")
        XCTAssertEqual(provenance.steps.first?.outputs.first?.path, output.path)
        XCTAssertNil(provenance.steps.first?.outputs.first?.sha256)
        XCTAssertNil(provenance.steps.first?.outputs.first?.sizeBytes)
    }

    func testProcessRunnerCapturesVerboseStdoutAndStderrWithoutRealGATK() async throws {
        let runner = ProcessGATKCommandRunner()

        let result = try await runner.run(
            GATKCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "i=0; while [ $i -lt 20000 ]; do echo stdout-$i; echo stderr-$i >&2; i=$((i+1)); done",
                ]
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("stdout-19999"))
        XCTAssertTrue(result.stderr.contains("stderr-19999"))
    }

    private func write(_ name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func decodeProvenance(at url: URL) throws -> WorkflowRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: url))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private actor RecordingGATKCommandRunner: GATKCommandRunning {
    typealias Handler = @Sendable (GATKCommand) async throws -> GATKCommandExecutionResult

    private let handler: Handler
    private(set) var commands: [GATKCommand] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        commands.append(command)
        return try await handler(command)
    }

    func recordedCommands() -> [GATKCommand] {
        commands
    }
}
