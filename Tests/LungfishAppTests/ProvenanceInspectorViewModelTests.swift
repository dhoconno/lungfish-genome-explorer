import XCTest
@testable import LungfishApp
import LungfishIO
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

    func testMissingRequiredProvenanceIsBlockingAndBrowsable() async throws {
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
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .missing)
        XCTAssertTrue(viewModel.audit.isBlocking)
        XCTAssertTrue(viewModel.shouldShowTab)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Missing provenance" })
    }

    func testCompleteEnvelopeBuildsSummaryLineageAndFiles() async throws {
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
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "FASTQ Import")
        XCTAssertEqual(viewModel.summary.stepCount, 2)
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.map(\.toolName), ["fastq-import", "qc"])
        XCTAssertEqual(Set(viewModel.fileRows.map(\.role)), Set(["Input", "Output"]))
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "quality" && $0.kind == "Explicit" })
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "compress" && $0.kind == "Default" })
        XCTAssertTrue(viewModel.optionRows.contains { $0.name == "threads" && $0.kind == "Resolved Default" })
        XCTAssertTrue(viewModel.copyableText.contains("Run Summary"))
        XCTAssertTrue(viewModel.copyableText.contains("FASTQ Import"))
        XCTAssertTrue(viewModel.copyableText.contains("fastq-import"))
        XCTAssertTrue(viewModel.copyableText.contains(input.path))
        XCTAssertTrue(viewModel.copyableText.contains(output.path))
    }

    func testIncompleteEnvelopeIsBlockingForRequiredScientificTarget() async throws {
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
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .incomplete)
        XCTAssertTrue(viewModel.audit.isBlocking)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Incomplete provenance" })
    }

    func testSuccessfulEnvelopeWithoutStderrIsComplete() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("reads.fastq.gz")
        let output = dir.appendingPathComponent("final.contigs.fa")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data(">contig\nACGT\n".utf8).write(to: output)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .fasta, role: .output)
        let step = ProvenanceStep(
            toolName: "megahit",
            toolVersion: "1.2.9",
            argv: ["megahit", "-r", input.path, "-o", dir.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 10.1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish.assemble",
            workflowVersion: "0.5.0-alpha6",
            toolName: "megahit",
            toolVersion: "1.2.9",
            argv: ["lungfish-cli", "assemble", input.path, "--assembler", "megahit"],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 10.1,
            exitStatus: 0,
            stderr: nil
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .analysisResult,
                contentMode: .assembly,
                displayName: "MEGAHIT Assembly"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertFalse(viewModel.warnings.contains { $0.message.localizedCaseInsensitiveContains("stderr") })
    }

    func testLineageStderrStripsANSIEscapeSequencesForDisplayAndCopy() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("reads.fastq")
        let output = dir.appendingPathComponent("classification.tsv")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("sample\tstatus\nSampleA\tok\n".utf8).write(to: output)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .text, role: .report)
        let coloredStderr = """
        \u{001B}[93m2026-05-17 20:03:29,901 - INFO - DB: /tmp/esviritu\u{001B}[0m
        \u{001B}[31mwarning: low viral read depth\u{001B}[0m
        """
        let step = ProvenanceStep(
            toolName: "EsViritu",
            toolVersion: "3.13",
            argv: ["EsViritu", "-r", input.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 33.12,
            stderr: coloredStderr
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "EsViritu Batch",
            workflowVersion: "0.5.0-alpha6",
            toolName: "Lungfish EsViritu Batch",
            toolVersion: "0.5.0-alpha6",
            argv: step.argv,
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 33.12,
            exitStatus: 0,
            stderr: coloredStderr
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .esvirituResult,
                contentMode: .metagenomics,
                displayName: "EsViritu"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        let displayedStderr = try XCTUnwrap(viewModel.lineageRuns.first?.steps.first?.stderr)
        XCTAssertTrue(displayedStderr.contains("2026-05-17 20:03:29,901 - INFO - DB: /tmp/esviritu"))
        XCTAssertTrue(displayedStderr.contains("warning: low viral read depth"))
        XCTAssertFalse(displayedStderr.contains("\u{001B}"))
        XCTAssertFalse(displayedStderr.contains("[93m"))
        XCTAssertFalse(displayedStderr.contains("[31m"))
        XCTAssertFalse(displayedStderr.contains("[0m"))

        XCTAssertFalse(viewModel.copyableText.contains("\u{001B}"))
        XCTAssertFalse(viewModel.copyableText.contains("[93m"))
        XCTAssertFalse(viewModel.copyableText.contains("[31m"))
        XCTAssertFalse(viewModel.copyableText.contains("[0m"))
    }

    /// Before Phase 2.4 the audit wrote a batch record, a manifest and a summary table when it found a
    /// batch with sample records and no root record. Reading never writes (ruling V6), so the batch
    /// shows Missing provenance and its folder keeps every byte.
    func testEsVirituInspectorShowsMissingProvenanceForBatchWithoutRootRecord() async throws {
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
        let before = try ProjectTreeSnapshot(of: root)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: batchRoot,
                sidebarType: .esvirituResult,
                contentMode: .metagenomics,
                displayName: "EsViritu"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .missing)
        XCTAssertEqual(viewModel.summary.statusLabel, "Missing provenance")
        XCTAssertNil(viewModel.resolvedEnvelope)
        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: batchRoot))
        XCTAssertEqual(
            try ProjectTreeSnapshot(of: root).differences(from: before), [],
            "Selecting a batch without a root record must not write one."
        )
    }

    /// Before Phase 2.4 the audit wrote a record for a TaxTriage result that had none, stamped with
    /// the reading app's version and the moment of reading. Reading never writes (ruling V6), so the
    /// result shows Missing provenance and its folder keeps every byte.
    func testTaxTriageInspectorShowsMissingProvenanceForResultWithoutRecord() async throws {
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
        let before = try ProjectTreeSnapshot(of: resultDirectory)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: resultDirectory,
                sidebarType: .taxTriageResult,
                contentMode: .metagenomics,
                displayName: "TaxTriage"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .missing)
        XCTAssertEqual(viewModel.summary.statusLabel, "Missing provenance")
        XCTAssertNil(viewModel.resolvedEnvelope)
        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory))
        XCTAssertEqual(
            try ProjectTreeSnapshot(of: resultDirectory).differences(from: before), [],
            "Selecting a result without a record must not write one."
        )
    }

    /// Capture on 9.64: the HG002 bcftools track's record read "Incomplete"
    /// because the stream bcftools mpileup pipes into bcftools call has no
    /// checksum or size. A pipe is not a file, so it cannot have either.
    func testPipedStreamDescriptorIsNotReportedAsMissingFileMetadata() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("aln.bam")
        let output = dir.appendingPathComponent("calls.vcf.gz")
        try Data("bam".utf8).write(to: input)
        try Data("vcf".utf8).write(to: output)
        let inputDescriptor = ProvenanceFileDescriptor(
            path: input.path, checksumSHA256: String(repeating: "a", count: 64), fileSize: 3,
            format: .bam, role: .input)
        let outputDescriptor = ProvenanceFileDescriptor(
            path: output.path, checksumSHA256: String(repeating: "b", count: 64), fileSize: 3,
            format: .vcf, role: .output)
        let pipeDescriptor = ProvenanceFileDescriptor(
            path: "pipe:stdout:bcftools-mpileup", format: .bcf, role: .output)
        let mpileup = ProvenanceStep(
            toolName: "bcftools", toolVersion: "1.24", argv: ["bcftools", "mpileup", input.path],
            inputs: [inputDescriptor], outputs: [pipeDescriptor], exitStatus: 0, wallTimeSeconds: 1, stderr: "")
        let call = ProvenanceStep(
            toolName: "bcftools", toolVersion: "1.24", argv: ["bcftools", "call", "-o", output.path],
            inputs: [pipeDescriptor], outputs: [outputDescriptor], exitStatus: 0, wallTimeSeconds: 1, stderr: "")
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish variants call", workflowVersion: "2026.9.64",
            toolName: "bcftools", toolVersion: "1.24", argv: ["bcftools", "call"],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor], output: outputDescriptor, outputs: [outputDescriptor],
            steps: [mpileup, call], wallTimeSeconds: 2, exitStatus: 0, stderr: "")
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(item: ProvenanceInspectableItem(
            url: dir, sidebarType: .classificationResult, contentMode: .metagenomics, displayName: "bcftools"))
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertFalse(viewModel.warnings.contains { $0.title == "File metadata incomplete" }, "\(viewModel.warnings)")
        XCTAssertNotEqual(viewModel.audit.status, .incomplete)
    }

    func testMissingFileMetadataWarningsAreAggregated() async throws {
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
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .incomplete)
        XCTAssertEqual(viewModel.warnings.filter { $0.title == "File metadata incomplete" }.count, 1)
        XCTAssertTrue(viewModel.warnings.contains { warning in
            warning.message.contains("2 file descriptors")
                && warning.message.contains("reads.fastq")
                && warning.message.contains("classification.kreport")
        }, "\(viewModel.warnings)")
    }

    func testLargeEnvelopePresentationIsBounded() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputDescriptors = (0..<650).map { index in
            ProvenanceFileDescriptor(
                path: dir.appendingPathComponent("input-\(index).fastq").path,
                checksumSHA256: String(repeating: "a", count: 64),
                fileSize: UInt64(index + 1),
                format: .fastq,
                role: .input
            )
        }
        let outputDescriptors = (0..<650).map { index in
            ProvenanceFileDescriptor(
                path: dir.appendingPathComponent("output-\(index).fastq").path,
                checksumSHA256: String(repeating: "b", count: 64),
                fileSize: UInt64(index + 1),
                format: .fastq,
                role: .output
            )
        }
        let step = ProvenanceStep(
            toolName: "bulk-import",
            toolVersion: "1.0",
            argv: ["bulk-import", dir.path],
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: 2
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "Large FASTQ Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.5.0",
            argv: ["lungfish-cli", "fastq", "import-ont", dir.path],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: inputDescriptors + outputDescriptors,
            output: outputDescriptors.first,
            outputs: outputDescriptors,
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Large Import"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.inputCount, 650)
        XCTAssertEqual(viewModel.summary.outputCount, 650)
        XCTAssertLessThanOrEqual(viewModel.fileRows.count, 500)
        XCTAssertLessThanOrEqual(viewModel.lineageRuns.first?.steps.first?.inputPaths.count ?? 0, 201)
        XCTAssertLessThanOrEqual(viewModel.lineageRuns.first?.steps.first?.outputPaths.count ?? 0, 201)
        XCTAssertEqual(viewModel.rawJSON, "")
        XCTAssertNotNil(viewModel.resolvedEnvelope)
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "Large provenance record" })
        XCTAssertLessThan(viewModel.copyableText.count, 200_000)
    }

    func testONTFASTQBundleChunkInputsCollapseForInspectorDisplay() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resultBundle = root.appendingPathComponent("barcode08-mcm-mhc.lungfishgenotype", isDirectory: true)
        let fastqBundle = root.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunkDirectory = fastqBundle.appendingPathComponent("chunks", isDirectory: true)
        let originalDirectory = root.appendingPathComponent("fastq_pass/barcode08", isDirectory: true)
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)

        let bundleChunk0 = chunkDirectory.appendingPathComponent("FBC39814_pass_barcode08_0.fastq.gz")
        let bundleChunk1 = chunkDirectory.appendingPathComponent("FBC39814_pass_barcode08_1.fastq.gz")
        let originalChunk2 = originalDirectory.appendingPathComponent("FBC39814_pass_barcode08_2.fastq.gz")
        let chunkDescriptors = [bundleChunk0, bundleChunk1, originalChunk2].enumerated().map { index, url in
            [
                "path": url.path,
                "role": "input-fastq",
                "format": "fastq",
                "sha256": String(repeating: "\(index)", count: 64),
                "fileSizeBytes": 1_024 * UInt64(index + 1),
            ] as [String: Any]
        }
        let output = resultBundle.appendingPathComponent("barcode08-mcm-mhc.xlsx")
        try Data("xlsx".utf8).write(to: output)

        try FASTQSourceFileManifest(files: [
            FASTQSourceFileManifest.SourceFileEntry(
                filename: "chunks/FBC39814_pass_barcode08_0.fastq.gz",
                originalPath: root.appendingPathComponent("fastq_pass/barcode08/FBC39814_pass_barcode08_0.fastq.gz").path,
                sizeBytes: 1_024,
                isSymlink: false
            ),
            FASTQSourceFileManifest.SourceFileEntry(
                filename: "chunks/FBC39814_pass_barcode08_1.fastq.gz",
                originalPath: root.appendingPathComponent("fastq_pass/barcode08/FBC39814_pass_barcode08_1.fastq.gz").path,
                sizeBytes: 2_048,
                isSymlink: false
            ),
            FASTQSourceFileManifest.SourceFileEntry(
                filename: "chunks/FBC39814_pass_barcode08_2.fastq.gz",
                originalPath: originalChunk2.path,
                sizeBytes: 3_072,
                isSymlink: false
            ),
        ]).save(to: fastqBundle)

        let primitiveJSON: [String: Any] = [
            "workflowName": "ONT Barcode Demux Genotyping",
            "workflowVersion": "0.5.0-alpha6",
            "toolName": "lungfish fastq ont-barcode-genotype",
            "toolVersion": "Lungfish 0.5.0-alpha6 (1)",
            "createdAt": "2026-05-22T12:00:00Z",
            "argv": [
                "lungfish",
                "fastq",
                "ont-barcode-genotype",
                fastqBundle.path,
                "--output",
                resultBundle.path,
            ],
            "options": [
                "inputFASTQ": fastqBundle.path,
                "reportName": "barcode08-mcm-mhc",
            ],
            "inputs": chunkDescriptors,
            "outputs": [[
                "path": output.path,
                "role": "report",
                "format": "xlsx",
                "sha256": String(repeating: "a", count: 64),
                "fileSizeBytes": 3,
            ]],
            "steps": [[
                "toolName": "minimap2",
                "toolVersion": "2.28",
                "argv": ["minimap2", "-ax", "map-ont", "reference.fa", fastqBundle.path],
                "outputs": [[
                    "path": resultBundle.appendingPathComponent("barcode08-mcm-mhc.bam").path,
                    "role": "output",
                    "format": "bam",
                    "sha256": String(repeating: "b", count: 64),
                    "fileSizeBytes": 10,
                ]],
                "exitStatus": 0,
                "wallTimeSeconds": 5.0,
            ]],
            "wallTimeSeconds": 5.0,
            "exitStatus": 0,
            "runtimeIdentity": [
                "appVersion": "Lungfish 0.5.0-alpha6 (1)",
                "executablePath": "/Applications/Lungfish.app/Contents/MacOS/Lungfish",
                "processIdentifier": 1,
                "operatingSystemVersion": "macOS",
                "architecture": "arm64",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: primitiveJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: resultBundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: resultBundle,
                sidebarType: .genotypeResultBundle,
                contentMode: .genotype,
                displayName: "barcode08-mcm-mhc"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.inputCount, 3)
        XCTAssertTrue(viewModel.fileRows.contains { row in
            row.path == fastqBundle.path
                && row.displayPath.contains("barcode08.lungfishfastq")
                && row.fileSizeLabel.contains("3 FASTQ chunks")
        }, "\(viewModel.fileRows)")
        XCTAssertFalse(viewModel.fileRows.contains { $0.path.contains("/chunks/FBC39814_pass_barcode08_0.fastq.gz") })
        XCTAssertFalse(viewModel.fileRows.contains { $0.path == originalChunk2.path })
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.first?.inputPaths, [
            "barcode08.lungfishfastq - 3 FASTQ chunks (6 KB)",
        ])
        XCTAssertTrue(viewModel.warnings.contains { warning in
            warning.title == "FASTQ chunks collapsed"
                && warning.message.contains("3 FASTQ chunk descriptors")
                && warning.message.contains("complete provenance JSON")
        })
        XCTAssertLessThan(viewModel.copyableText.count, 20_000)
    }

    func testONTFASTQBundleChunkCollapseKeepsLargeInspectorPresentationBounded() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let resultBundle = root.appendingPathComponent("barcode08-large.lungfishgenotype", isDirectory: true)
        let fastqBundle = root.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunkDirectory = fastqBundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)

        let chunkCount = 260
        let chunkDescriptors: [[String: Any]] = (0..<chunkCount).map { index in
            let chunkURL = chunkDirectory.appendingPathComponent("barcode08_\(index).fastq.gz")
            return [
                "path": chunkURL.path,
                "role": "input-fastq",
                "format": "fastq",
                "sha256": String(repeating: String(index % 10), count: 64),
                "fileSizeBytes": 4_096,
            ]
        }
        try FASTQSourceFileManifest(
            files: (0..<chunkCount).map { index in
                FASTQSourceFileManifest.SourceFileEntry(
                    filename: "chunks/barcode08_\(index).fastq.gz",
                    originalPath: root.appendingPathComponent("fastq_pass/barcode08/barcode08_\(index).fastq.gz").path,
                    sizeBytes: 4_096,
                    isSymlink: false
                )
            }
        ).save(to: fastqBundle)

        let output = resultBundle.appendingPathComponent("barcode08-large.xlsx")
        try Data("xlsx".utf8).write(to: output)
        let primitiveJSON: [String: Any] = [
            "workflowName": "ONT Barcode Demux Genotyping",
            "workflowVersion": "0.5.0-alpha6",
            "toolName": "lungfish fastq ont-barcode-genotype",
            "toolVersion": "Lungfish 0.5.0-alpha6 (1)",
            "createdAt": "2026-05-22T12:00:00Z",
            "argv": ["lungfish", "fastq", "ont-barcode-genotype", fastqBundle.path],
            "options": ["inputFASTQ": fastqBundle.path],
            "inputs": chunkDescriptors,
            "outputs": [[
                "path": output.path,
                "role": "report",
                "format": "xlsx",
                "sha256": String(repeating: "c", count: 64),
                "fileSizeBytes": 4,
            ]],
            "steps": [[
                "toolName": "retained-demux",
                "toolVersion": "1.0",
                "argv": ["retained-demux", fastqBundle.path],
                "exitStatus": 0,
                "wallTimeSeconds": 5.0,
            ]],
            "wallTimeSeconds": 5.0,
            "exitStatus": 0,
            "runtimeIdentity": [
                "appVersion": "Lungfish 0.5.0-alpha6 (1)",
                "executablePath": "/Applications/Lungfish.app/Contents/MacOS/Lungfish",
                "processIdentifier": 1,
                "operatingSystemVersion": "macOS",
                "architecture": "arm64",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: primitiveJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: resultBundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: resultBundle,
                sidebarType: .genotypeResultBundle,
                contentMode: .genotype,
                displayName: "barcode08-large"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.fileRows.filter { $0.role == "Input" }.count, 1)
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.first?.inputPaths.count, 1)
        XCTAssertEqual(viewModel.rawJSON, "")
        XCTAssertTrue(viewModel.warnings.contains { $0.title == "FASTQ chunks collapsed" })
        XCTAssertLessThan(viewModel.copyableText.count, 25_000)
    }

    func testFullLengthGenotypeBundleLoadsWorkflowNamedRootProvenanceSidecar() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resultBundle = dir.appendingPathComponent("CP2656.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)

        let input = resultBundle.appendingPathComponent("CP2656.fastq")
        let workbook = resultBundle.appendingPathComponent("CP2656.full-length-ont-mhc-genotypes.xlsx")
        let clusters = resultBundle.appendingPathComponent("samples/CP2656/savont/CP2656.savont-clusters.fasta")
        try FileManager.default.createDirectory(
            at: clusters.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("xlsx".utf8).write(to: workbook)
        try Data(">cluster_1;size=42\nACGT\n".utf8).write(to: clusters)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let workbookDescriptor = try ProvenanceFileDescriptor.file(url: workbook, format: .unknown, role: .report)
        let clusterDescriptor = try ProvenanceFileDescriptor.file(url: clusters, format: .fasta, role: .output)
        let savontStep = ProvenanceStep(
            toolName: "savont",
            toolVersion: "0.1.0",
            argv: ["savont", "asv", input.path, "-o", clusters.deletingLastPathComponent().path],
            inputs: [inputDescriptor],
            outputs: [clusterDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 7.5
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish fastq full-length-ont-mhc-genotype",
            workflowVersion: "Lungfish test",
            toolName: "lungfish-cli",
            toolVersion: "Lungfish test",
            argv: [
                "lungfish",
                "fastq",
                "full-length-ont-mhc-genotype",
                input.path,
                "--output-dir",
                resultBundle.path,
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, workbookDescriptor, clusterDescriptor],
            output: nil,
            outputs: [workbookDescriptor, clusterDescriptor],
            steps: [savontStep],
            wallTimeSeconds: 8.0,
            exitStatus: 0
        )
        let data = try ProvenanceJSON.encoder.encode(envelope)
        try data.write(
            to: resultBundle.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json"),
            options: .atomic
        )

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: resultBundle,
                sidebarType: .genotypeResultBundle,
                contentMode: .genotype,
                displayName: "CP2656"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.audit.status, .present)
        XCTAssertEqual(viewModel.summary.workflowName, "lungfish fastq full-length-ont-mhc-genotype")
        XCTAssertEqual(viewModel.lineageRuns.first?.steps.map(\.toolName), ["savont"])
        XCTAssertTrue(viewModel.summary.sidecarPath?.hasSuffix("full-length-ont-mhc-genotyping-provenance.json") == true)
        XCTAssertTrue(viewModel.copyableText.contains("full-length-ont-mhc-genotype"))
    }

    func testLineageWalksUpstreamThroughInputSidecars() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("Chained.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        let analysis = project.appendingPathComponent("Analyses/minimap2-1", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let reads = imports.appendingPathComponent("reads.fastq.gz")
        let bam = analysis.appendingPathComponent("reads.sorted.bam")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: reads)
        try Data("bam".utf8).write(to: bam)

        let readsOut = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "lungfish import fastq", toolName: "clumpify.sh", toolVersion: "40.02",
                argv: ["clumpify.sh", "in=raw.fastq.gz", "out=\(reads.path)"],
                runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
                files: [readsOut], output: readsOut, outputs: [readsOut],
                steps: [ProvenanceStep(toolName: "clumpify.sh", toolVersion: "40.02", argv: ["clumpify.sh"], outputs: [readsOut], exitStatus: 0, wallTimeSeconds: 1)],
                wallTimeSeconds: 1, exitStatus: 0, stderr: ""
            ),
            to: imports
        )
        let readsIn = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .input)
        let bamOut = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .output)
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "lungfish map", toolName: "minimap2", toolVersion: "2.31",
                argv: ["minimap2", "-a", reads.path],
                runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
                files: [readsIn, bamOut], output: bamOut, outputs: [bamOut],
                steps: [ProvenanceStep(toolName: "minimap2", toolVersion: "2.31", argv: ["minimap2", "-a", reads.path], inputs: [readsIn], outputs: [bamOut], exitStatus: 0, wallTimeSeconds: 2)],
                wallTimeSeconds: 2, exitStatus: 0, stderr: ""
            ),
            to: analysis
        )

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: analysis,
                sidebarType: .analysisResult,
                contentMode: .empty,
                displayName: "minimap2-1"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.summary.workflowName, "lungfish map")
        XCTAssertEqual(viewModel.lineageRuns.map(\.title), ["lungfish import fastq", "lungfish map"])
        XCTAssertEqual(viewModel.lineageRuns.last?.steps.map(\.toolName), ["minimap2"])
        XCTAssertTrue(viewModel.copyableText.contains("clumpify.sh"), viewModel.copyableText)
    }

    /// A record a development build wrote under another machine's project
    /// root, read from a copy of that project: files that still exist here
    /// read as project-relative, vanished intermediates are named as such,
    /// an input outside the project shows its name, an index gets a format,
    /// and the version a dev build stamped reads as a development build.
    func testForeignRecordPresentsProjectRelativePathsAndDevelopmentBuild() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("HG002 chr20.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        let analysis = project.appendingPathComponent("Analyses/minimap2-1", isDirectory: true)
        let mapped = analysis.appendingPathComponent("ref.lungfishref/alignments/mapped", isDirectory: true)
        for folder in [imports, mapped] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: imports.appendingPathComponent("reads.fastq.gz"))
        try Data("bam".utf8).write(to: mapped.appendingPathComponent("aln_1.bam"))
        try Data("bai".utf8).write(to: mapped.appendingPathComponent("aln_1.bam.bai"))

        let foreign = "/tmp/lge-demo-build/projects/Human Mapping.lungfish"
        let sha = String(repeating: "a", count: 64)
        func descriptor(_ path: String, _ role: FileRole, _ format: FileFormat?) -> ProvenanceFileDescriptor {
            ProvenanceFileDescriptor(path: path, checksumSHA256: sha, fileSize: 3, format: format, role: role)
        }
        let reads = descriptor("\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz", .input, .fastq)
        let external = descriptor("/Volumes/Data/HG002_R1.fastq.gz", .input, .fastq)
        let rawSAM = descriptor("\(foreign)/Analyses/minimap2-1/reads.raw.sam", .output, .sam)
        let bam = descriptor("\(foreign)/Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam", .output, .bam)
        let bai = descriptor("\(foreign)/Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam.bai", .index, .unknown)
        let envelope = ProvenanceEnvelope(
            workflowName: "lungfish map",
            workflowVersion: "Lungfish dev (0)",
            toolName: "lungfish map",
            toolVersion: "Lungfish dev (0)",
            argv: ["minimap2", "-a", reads.path],
            options: ProvenanceOptions(
                explicit: [
                    "reads": .file(URL(fileURLWithPath: reads.path)),
                    "effectiveArgv": .string("minimap2 -a '\(reads.path)' -o '\(rawSAM.path)'"),
                    "threads": .integer(14),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [reads, external, rawSAM, bam, bai],
            output: bam,
            outputs: [bam, bai],
            steps: [
                ProvenanceStep(
                    toolName: "minimap2", toolVersion: "2.31", argv: ["minimap2", "-a", reads.path],
                    inputs: [reads, external], outputs: [rawSAM], exitStatus: 0, wallTimeSeconds: 1
                ),
                ProvenanceStep(
                    toolName: "lungfish map", toolVersion: "Lungfish dev (0)", argv: ["lungfish-internal", "adopt"],
                    inputs: [rawSAM], outputs: [bam, bai], exitStatus: 0, wallTimeSeconds: 1
                ),
            ],
            wallTimeSeconds: 2, exitStatus: 0, stderr: ""
        )
        // Written as bytes, the way records older than the path sanitizer are
        // on disk: the writer would otherwise rewrite the foreign root.
        try ProvenanceJSON.encoder.encode(envelope)
            .write(to: analysis.appendingPathComponent(".lungfish-provenance.json"))

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(item: ProvenanceInspectableItem(
            url: analysis, sidebarType: .analysisResult, contentMode: .mapping, displayName: "minimap2-1"
        ))
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.summary.workflowVersion, "Lungfish (development build)")
        XCTAssertEqual(viewModel.summary.toolVersion, "(development build)")
        XCTAssertEqual(viewModel.summary.sidecarDisplayPath, "Analyses/minimap2-1/.lungfish-provenance.json")
        XCTAssertEqual(viewModel.summary.sidecarPath, analysis.appendingPathComponent(".lungfish-provenance.json").path)

        func row(_ suffix: String) throws -> ProvenanceFileRow {
            try XCTUnwrap(viewModel.fileRows.first { $0.path.hasSuffix(suffix) }, "no row ends with \(suffix): \(viewModel.fileRows.map(\.path))")
        }
        // The FASTQ input collapses into its bundle row, shown project-relative.
        let readsRow = try row("reads.lungfishfastq")
        XCTAssertEqual(readsRow.displayPath, "Imports/reads.lungfishfastq")
        XCTAssertNil(readsRow.detail)
        XCTAssertEqual(readsRow.accessibilityValue, imports.path)

        let samRow = try row("reads.raw.sam")
        XCTAssertEqual(samRow.displayPath, "Analyses/minimap2-1/reads.raw.sam")
        XCTAssertEqual(samRow.detail, "intermediate file, not kept")
        XCTAssertTrue(samRow.accessibilityValue.contains(rawSAM.path), samRow.accessibilityValue)
        XCTAssertFalse(samRow.displayPath.contains("/tmp/lge-demo-build"))

        let externalRow = try row("HG002_R1.fastq.gz")
        XCTAssertEqual(externalRow.displayPath, "HG002_R1.fastq.gz")
        XCTAssertEqual(externalRow.detail, "outside the project")
        XCTAssertTrue(externalRow.accessibilityValue.contains("/Volumes/Data/HG002_R1.fastq.gz"))

        XCTAssertEqual(try row("aln_1.bam.bai").format, "BAM index")
        XCTAssertEqual(try row("aln_1.bam").format, "BAM")

        let run = try XCTUnwrap(viewModel.lineageRuns.last)
        XCTAssertEqual(run.subtitle, "lungfish map (development build)")
        XCTAssertEqual(run.steps.map(\.toolVersion), ["v2.31", "(development build)"])
        XCTAssertEqual(run.steps[1].inputPathLabels, ["Analyses/minimap2-1/reads.raw.sam (intermediate file, not kept)"])
        XCTAssertEqual(run.steps[1].inputPaths, [rawSAM.path])
        XCTAssertEqual(run.steps[0].inputPathLabels.last, "HG002_R1.fastq.gz (outside the project)")
        XCTAssertEqual(run.steps[1].outputPathLabels.first, "Analyses/minimap2-1/ref.lungfishref/alignments/mapped/aln_1.bam")

        // The Command row shows project paths project-relative while the
        // recorded command stays whole for help, accessibility and copying.
        // The reader re-roots a recorded path whose file exists here, so the
        // kept FASTQ is named by this project's path and the discarded SAM by
        // the foreign one.
        let localReads = imports.appendingPathComponent("reads.fastq.gz").path
        XCTAssertEqual(run.steps[0].displayCommand, "minimap2 -a Imports/reads.lungfishfastq/reads.fastq.gz")
        XCTAssertEqual(run.steps[0].command, "minimap2 -a '\(localReads)'")
        XCTAssertEqual(run.steps[1].displayCommand, "lungfish-internal adopt")
        XCTAssertTrue(viewModel.copyableText.contains("Command: minimap2 -a '\(localReads)'"), viewModel.copyableText)

        func option(_ name: String) throws -> ProvenanceOptionRow {
            try XCTUnwrap(viewModel.optionRows.first { $0.name == name }, "no option named \(name)")
        }
        XCTAssertEqual(try option("reads").displayValue, "Imports/reads.lungfishfastq/reads.fastq.gz")
        XCTAssertEqual(try option("reads").value, localReads)
        XCTAssertEqual(
            try option("effectiveArgv").displayValue,
            "minimap2 -a Imports/reads.lungfishfastq/reads.fastq.gz -o Analyses/minimap2-1/reads.raw.sam"
        )
        XCTAssertEqual(try option("effectiveArgv").value, "minimap2 -a '\(localReads)' -o '\(rawSAM.path)'")
        XCTAssertEqual(try option("threads").displayValue, "14")
        XCTAssertTrue(viewModel.copyableText.contains("reads (Explicit): \(localReads)"), viewModel.copyableText)

        XCTAssertFalse(viewModel.copyableText.contains("dev (0)"), viewModel.copyableText)
        XCTAssertTrue(viewModel.copyableText.contains("Lungfish (development build)"), viewModel.copyableText)
        XCTAssertTrue(viewModel.copyableText.contains("Sidecar: Analyses/minimap2-1/.lungfish-provenance.json"), viewModel.copyableText)
        XCTAssertTrue(viewModel.copyableText.contains("Format: BAM index"), viewModel.copyableText)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `load(item:)` is synchronous but resolves the sidecar lookup on a detached background
    /// task (see F6); this polls `isLoading` until that task has applied its result back on
    /// the main actor. Idiom: `waitUntil` in `SequenceViewerInteractionAsyncBundleReadTests`.
    private func waitUntilLoadCompletes(
        _ viewModel: ProvenanceInspectorViewModel,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isLoading {
            if Date() >= deadline {
                XCTFail("Timed out waiting for provenance load to complete")
                return
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
