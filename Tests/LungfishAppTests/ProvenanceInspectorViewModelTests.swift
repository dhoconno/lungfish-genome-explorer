import XCTest
@testable import LungfishApp
import LungfishWorkflow

@MainActor
final class ProvenanceInspectorViewModelTests: XCTestCase {
    func testScientificSidebarTypesRequireProvenance() {
        let monitor = ProvenanceCoverageMonitor()
        let required: [SidebarItemType] = [
            .sequence,
            .annotation,
            .alignment,
            .coverage,
            .referenceBundle,
            .multipleSequenceAlignmentBundle,
            .phylogeneticTreeBundle,
            .fastqBundle,
            .primerSchemeBundle,
            .classificationResult,
            .esvirituResult,
            .taxTriageResult,
            .naoMgsResult,
            .nvdResult,
            .czIdResult,
            .analysisResult,
        ]

        let missing = required.filter { type in
            monitor.requirement(
                for: ProvenanceInspectableItem(
                    url: nil,
                    sidebarType: type,
                    contentMode: .empty,
                    displayName: nil
                )
            ).isNotRequired
        }

        XCTAssertEqual(missing, [])
    }

    func testNonScientificSidebarTypesDoNotRequireProvenance() {
        let monitor = ProvenanceCoverageMonitor()
        let notRequired: [SidebarItemType] = [
            .group,
            .folder,
            .project,
            .document,
            .image,
            .unknown,
            .batchGroup,
        ]

        let unexpectedlyRequired = notRequired.filter { type in
            !monitor.requirement(
                for: ProvenanceInspectableItem(
                    url: nil,
                    sidebarType: type,
                    contentMode: .empty,
                    displayName: nil
                )
            ).isNotRequired
        }

        XCTAssertEqual(unexpectedlyRequired, [])
    }

    func testScientificExtensionsRequireProvenanceWithoutSidebarType() {
        let monitor = ProvenanceCoverageMonitor()
        let requiredNames = [
            "fixture.lungfishref",
            "reads.lungfishfastq",
            "alignment.lungfishmsa",
            "tree.lungfishtree",
            "scheme.lungfishprimers",
            "reads.bam",
            "reads.cram",
            "variants.vcf",
            "variants.vcf.gz",
            "contigs.fasta",
            "contigs.fasta.gz",
            "reads.fastq",
            "reads.fastq.gz",
        ]

        let missing = requiredNames.filter { name in
            let item = ProvenanceInspectableItem(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                sidebarType: nil,
                contentMode: .empty,
                displayName: nil
            )
            return monitor.requirement(for: item).isNotRequired
        }

        XCTAssertEqual(missing, [])
    }

    func testGenericCompressedFilesDoNotRequireProvenanceWithoutScientificExtension() {
        let monitor = ProvenanceCoverageMonitor()
        let item = ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/report.txt.gz"),
            sidebarType: nil,
            contentMode: .empty,
            displayName: nil
        )

        XCTAssertTrue(monitor.requirement(for: item).isNotRequired)
    }

    func testMissingRequiredProvenanceIsBlockingAndBrowsable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Reads"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .missing)
        XCTAssertTrue(viewModel.audit.isBlocking)
        XCTAssertTrue(viewModel.shouldShowTab)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Missing provenance" })
    }

    func testCompleteEnvelopeBuildsSummaryLineageAndFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("input.fastq")
        let output = dir.appendingPathComponent("output.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("@r\nACG\n+\n!!!\n".utf8).write(to: output)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)
        let importStep = ProvenanceStep(
            toolName: "fastq-import",
            toolVersion: "1.0",
            argv: ["fastq-import", input.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 2
        )
        let qcStep = ProvenanceStep(
            toolName: "qc",
            toolVersion: "2.0",
            argv: ["qc", output.path],
            inputs: [outputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 1,
            dependsOn: [importStep.id]
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "FASTQ Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0",
            argv: ["lungfish-cli", "import", input.path],
            options: ProvenanceOptions(
                explicit: ["quality": .string("strict")],
                defaults: ["compress": .boolean(true)],
                resolvedDefaults: ["threads": .integer(4)]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [importStep, qcStep],
            wallTimeSeconds: 3,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Reads"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "FASTQ Import")
        XCTAssertEqual(viewModel.summary.stepCount, 2)
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.map(\.toolName), ["fastq-import", "qc"])
        XCTAssertEqual(Set(viewModel.fileRows.map(\.role)), Set(["Input", "Output"]))
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "quality" && $0.kind == "Explicit" })
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "compress" && $0.kind == "Default" })
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "threads" && $0.kind == "Resolved Default" })
    }

    func testIncompleteEnvelopeIsBlockingForRequiredScientificTarget() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let envelope = ProvenanceEnvelope(
            workflowName: "Incomplete",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0",
            argv: [],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [],
            output: nil,
            outputs: [],
            steps: [],
            wallTimeSeconds: nil,
            exitStatus: nil,
            stderr: nil
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .analysisResult,
                contentMode: .metagenomics,
                displayName: "Analysis"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .incomplete)
        XCTAssertTrue(viewModel.audit.isBlocking)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Incomplete provenance" })
    }

    func testEsVirituInspectorBackfillsRootProvenanceFromSampleSidecar() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let batchRoot = root.appendingPathComponent("esviritu-batch-test", isDirectory: true)
        let sampleDirectory = batchRoot.appendingPathComponent("SampleC", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

        let input = sampleDirectory.appendingPathComponent("SampleC.fastq")
        let output = sampleDirectory.appendingPathComponent("SampleC.detected_virus.info.tsv")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("virus\treads\nExample virus\t3\n".utf8).write(to: output)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .text, role: .output)
        let step = ProvenanceStep(
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            argv: ["EsViritu", "--input", input.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 2
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "Viral Metagenomics Detection",
            workflowVersion: "2026.05",
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            argv: step.argv,
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: sampleDirectory)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: batchRoot,
                sidebarType: .esvirituResult,
                contentMode: .metagenomics,
                displayName: "EsViritu"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "EsViritu Batch")
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: batchRoot))
    }

    func testTaxTriageInspectorBackfillsRootProvenanceFromResultSidecar() throws {
        let resultDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: resultDirectory) }

        let fastqURL = resultDirectory.appendingPathComponent("SampleE.fastq")
        let reportURL = resultDirectory.appendingPathComponent("SampleE.organisms.report.txt")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: fastqURL)
        try Data("organism\treads\nExample virus\t4\n".utf8).write(to: reportURL)

        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "SampleE", fastq1: fastqURL)],
            outputDirectory: resultDirectory,
            maxCpus: 2,
            profile: "docker"
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 3,
            exitCode: 0,
            outputDirectory: resultDirectory,
            reportFiles: [reportURL],
            allOutputFiles: [reportURL]
        )
        try result.save()

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: resultDirectory,
                sidebarType: .taxTriageResult,
                contentMode: .metagenomics,
                displayName: "TaxTriage"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "TaxTriage")
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory))
    }

    func testMissingFileMetadataWarningsAreAggregated() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("reads.fastq")
        let output = dir.appendingPathComponent("classification.kreport")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("50.0\t10\t10\tS\t562\tEscherichia coli\n".utf8).write(to: output)

        let inputDescriptor = ProvenanceFileDescriptor(
            path: input.path,
            format: .fastq,
            role: .input
        )
        let outputDescriptor = ProvenanceFileDescriptor(
            path: output.path,
            format: .text,
            role: .report
        )
        let step = ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", output.path, input.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 1,
            stderr: ""
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "Metagenomics Profiling",
            workflowVersion: "2026.05",
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", output.path, input.path],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 1,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .classificationResult,
                contentMode: .metagenomics,
                displayName: "Kraken2"
            )
        )

        XCTAssertEqual(viewModel.audit.status, .incomplete)
        XCTAssertEqual(viewModel.warnings.filter { $0.title == "File metadata incomplete" }.count, 1)
        XCTAssertTrue(viewModel.warnings.contains { warning in
            warning.message.contains("2 file descriptors")
                && warning.message.contains("reads.fastq")
                && warning.message.contains("classification.kreport")
        }, "\(viewModel.warnings)")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
