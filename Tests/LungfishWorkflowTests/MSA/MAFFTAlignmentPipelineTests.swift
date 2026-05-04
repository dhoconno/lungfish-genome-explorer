import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class MAFFTAlignmentPipelineTests: XCTestCase {
    private let fileManager = FileManager.default
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? fileManager.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildCommandUsesExpertDefaultAutoStrategy() throws {
        let workspace = try makeWorkspace()
        let input = workspace.appendingPathComponent("unaligned.fasta")
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try ">a\nACGT\n>b\nACGA\n".write(to: input, atomically: true, encoding: .utf8)

        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [input],
            projectURL: project,
            outputBundleURL: project.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true),
            name: "Aligned",
            threads: 6
        )

        let command = try MAFFTAlignmentPipeline.buildCommand(
            for: request,
            stagedInputURL: project.appendingPathComponent(".tmp/mafft-test/input.fasta"),
            alignedOutputURL: project.appendingPathComponent(".tmp/mafft-test/output.aligned.fasta")
        )

        XCTAssertEqual(command.executable, "mafft")
        XCTAssertEqual(command.environment, "mafft")
        XCTAssertEqual(command.arguments, [
            "--auto",
            "--thread", "6",
            "--threadit", "0",
            "--inputorder",
            project.appendingPathComponent(".tmp/mafft-test/input.fasta").path,
        ])
        XCTAssertTrue(command.shellCommand.contains("mafft --auto --thread 6 --threadit 0 --inputorder"))
    }

    func testBuildCommandSupportsLINSIAndAlignedOutputOrder() throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = workspace.appendingPathComponent("input.fasta")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try ">a\nACGT\n>b\nACGA\n".write(to: input, atomically: true, encoding: .utf8)

        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [input],
            projectURL: project,
            outputBundleURL: nil,
            name: "Local Pair",
            threads: 2,
            strategy: .linsi,
            outputOrder: .aligned,
            extraArguments: ["--op", "1.53"]
        )

        let command = try MAFFTAlignmentPipeline.buildCommand(
            for: request,
            stagedInputURL: project.appendingPathComponent(".tmp/mafft-test/input.fasta"),
            alignedOutputURL: project.appendingPathComponent(".tmp/mafft-test/output.aligned.fasta")
        )

        XCTAssertEqual(command.arguments, [
            "--localpair",
            "--maxiterate", "1000",
            "--op", "1.53",
            "--thread", "2",
            "--threadit", "0",
            "--reorder",
            project.appendingPathComponent(".tmp/mafft-test/input.fasta").path,
        ])
    }

    func testBuildCommandUsesAutoThreadsWhenThreadCountIsNil() throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = workspace.appendingPathComponent("input.fasta")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try ">a\nACGT\n>b\nACGA\n".write(to: input, atomically: true, encoding: .utf8)

        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [input],
            projectURL: project,
            outputBundleURL: nil,
            name: "Auto Threads",
            threads: nil
        )

        let command = try MAFFTAlignmentPipeline.buildCommand(
            for: request,
            stagedInputURL: project.appendingPathComponent(".tmp/mafft-test/input.fasta"),
            alignedOutputURL: project.appendingPathComponent(".tmp/mafft-test/output.aligned.fasta")
        )

        XCTAssertEqual(command.arguments, [
            "--auto",
            "--thread", "-1",
            "--threadit", "0",
            "--inputorder",
            project.appendingPathComponent(".tmp/mafft-test/input.fasta").path,
        ])
    }

    func testRunUsesProjectLocalTempAndWritesExternalToolProvenance() async throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try ">seq one\nACGT\n>seq two\nACGA\n".write(to: input, atomically: true, encoding: .utf8)

        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [input],
            projectURL: project,
            outputBundleURL: project.appendingPathComponent("MAFFT Output.lungfishmsa", isDirectory: true),
            name: "MAFFT Output",
            threads: 4
        )
        let runner = RecordingMSAToolRunner(alignedFASTA: ">seq_one\nACGT\n>seq_two\nAC-A\n")

        let result = try await MAFFTAlignmentPipeline(toolRunner: runner)
            .run(request: request)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: result.bundleURL)

        XCTAssertEqual(bundle.manifest.name, "MAFFT Output")
        XCTAssertEqual(bundle.manifest.rowCount, 2)
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.alignedLength, 4)
        XCTAssertTrue(runner.lastWorkingDirectory?.path.contains("\(project.path)/.tmp/mafft-") == true)
        XCTAssertFalse(runner.lastWorkingDirectory?.path.contains("/tmp/") == true)

        let provenanceURL = bundle.url.appendingPathComponent(".lungfish-provenance.json")
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(provenance.contains("\"toolName\" : \"lungfish align mafft\""))
        XCTAssertTrue(provenance.contains("\"name\" : \"mafft\""))
        XCTAssertTrue(provenance.contains("\"condaEnvironment\" : \"mafft\""))
        XCTAssertTrue(provenance.contains("\"--auto\""))
        XCTAssertTrue(provenance.contains(bundle.url.appendingPathComponent("alignment/input.unaligned.fasta").path))
        XCTAssertTrue(provenance.contains(bundle.url.appendingPathComponent("alignment/primary.aligned.fasta").path))
        XCTAssertTrue(provenance.contains("analysis-metadata.json"))
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: bundle.url)?.tool, "mafft")
        XCTAssertFalse(provenance.contains("\"/tmp/"), "MAFFT provenance should not point at system temp paths")
        XCTAssertFalse(provenance.contains("/.tmp/"), "MAFFT provenance should point at final bundle artifacts, not project staging paths")
    }

    func testRunStagesCompressedReferenceBundleGenomeFASTA() async throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let referenceBundle = project
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("two-sequences.lungfishref", isDirectory: true)
        let genomeDirectory = referenceBundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)

        let uncompressedFASTA = workspace.appendingPathComponent("sequence.fa")
        try ">ref A\nACGT\n>ref B\nACGA\n".write(to: uncompressedFASTA, atomically: true, encoding: .utf8)
        let compressedFASTA = genomeDirectory.appendingPathComponent("sequence.fa.gz")
        try gzipFile(uncompressedFASTA, to: compressedFASTA)
        try "ref A\t4\t7\t4\t5\nref B\t4\t19\t4\t5\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa.gz.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: "Two Sequences",
            identifier: "org.lungfish.test.two-sequences",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 8,
                chromosomes: [
                    ChromosomeInfo(name: "ref A", length: 4, offset: 7, lineBases: 4, lineWidth: 5),
                    ChromosomeInfo(name: "ref B", length: 4, offset: 19, lineBases: 4, lineWidth: 5),
                ]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: referenceBundle.appendingPathComponent(BundleManifest.filename), options: .atomic)

        let output = project.appendingPathComponent("Aligned Reference.lungfishmsa", isDirectory: true)
        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [referenceBundle],
            projectURL: project,
            outputBundleURL: output,
            name: "Aligned Reference",
            threads: nil
        )
        let runner = RecordingMSAToolRunner(alignedFASTA: ">ref_A\nACGT\n>ref_B\nAC-A\n")

        let result = try await MAFFTAlignmentPipeline(toolRunner: runner).run(request: request)
        let stagedInputURL = result.bundleURL.appendingPathComponent("alignment/input.unaligned.fasta")
        let stagedInput = try String(contentsOf: stagedInputURL, encoding: .utf8)

        XCTAssertEqual(runner.lastArguments?.last, runner.lastWorkingDirectory?.appendingPathComponent("input.unaligned.fasta").path)
        XCTAssertTrue(stagedInput.contains(">ref_A\nACGT\n"))
        XCTAssertTrue(stagedInput.contains(">ref_B\nACGA\n"))
        XCTAssertFalse(stagedInputURL.path.contains("/tmp/"))
    }

    func testRunRehydratesReferenceBundleAnnotationsAfterMAFFT() async throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        let referenceBundle = project
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("annotated-reference.lungfishref", isDirectory: true)
        let genomeDirectory = referenceBundle.appendingPathComponent("genome", isDirectory: true)
        let annotationDirectory = referenceBundle.appendingPathComponent("annotations", isDirectory: true)
        try fileManager.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: annotationDirectory, withIntermediateDirectories: true)

        let uncompressedFASTA = workspace.appendingPathComponent("annotated.fa")
        try ">ref A\nACGT\n>ref B\nACGA\n".write(to: uncompressedFASTA, atomically: true, encoding: .utf8)
        let compressedFASTA = genomeDirectory.appendingPathComponent("sequence.fa.gz")
        try gzipFile(uncompressedFASTA, to: compressedFASTA)
        try "ref A\t4\t7\t4\t5\nref B\t4\t19\t4\t5\n".write(
            to: genomeDirectory.appendingPathComponent("sequence.fa.gz.fai"),
            atomically: true,
            encoding: .utf8
        )
        let bedURL = workspace.appendingPathComponent("genes.bed")
        try "ref A\t1\t4\tgene-alpha\t0\t+\t1\t4\t0,0,0\t1\t3,\t0,\tgene\tID=gene-alpha;product=alpha\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(
            bedURL: bedURL,
            outputURL: annotationDirectory.appendingPathComponent("genes.db")
        )
        try Data().write(to: annotationDirectory.appendingPathComponent("genes.bb"))

        let manifest = BundleManifest(
            name: "Annotated Reference",
            identifier: "org.lungfish.test.annotated-reference",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 8,
                chromosomes: [
                    ChromosomeInfo(name: "ref A", length: 4, offset: 7, lineBases: 4, lineWidth: 5),
                    ChromosomeInfo(name: "ref B", length: 4, offset: 19, lineBases: 4, lineWidth: 5),
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/genes.bb",
                    databasePath: "annotations/genes.db",
                    featureCount: 1
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: referenceBundle.appendingPathComponent(BundleManifest.filename), options: .atomic)

        let output = project.appendingPathComponent("Annotated Alignment.lungfishmsa", isDirectory: true)
        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [referenceBundle],
            projectURL: project,
            outputBundleURL: output,
            name: "Annotated Alignment",
            threads: nil
        )
        let runner = RecordingMSAToolRunner(alignedFASTA: ">ref_A\nA-CGT\n>ref_B\nATCGA\n")

        let result = try await MAFFTAlignmentPipeline(toolRunner: runner).run(request: request)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: result.bundleURL)
        let annotationStore = try bundle.loadAnnotationStore()
        let annotation = try XCTUnwrap(annotationStore.sourceAnnotations.first)

        XCTAssertEqual(annotation.rowName, "ref_A")
        XCTAssertEqual(annotation.sourceAnnotationID, "gene-alpha")
        XCTAssertEqual(annotation.sourceIntervals, [AnnotationInterval(start: 1, end: 4)])
        XCTAssertEqual(annotation.alignedIntervals, [AnnotationInterval(start: 2, end: 5)])
        XCTAssertEqual(annotation.qualifiers["product"], ["alpha"])
        XCTAssertTrue(bundle.manifest.capabilities.contains("annotation-retention"))
    }

    func testRunRejectsFASTQInputsByDefault() async throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let fastq = workspace.appendingPathComponent("contigs.fastq")
        try """
        @contig one
        ACGT
        +
        IIII
        @contig two
        ACGA
        +
        IIII
        """.write(to: fastq, atomically: true, encoding: .utf8)

        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [fastq],
            projectURL: project,
            outputBundleURL: project.appendingPathComponent("FASTQ Rejected.lungfishmsa", isDirectory: true),
            name: "FASTQ Rejected",
            threads: nil
        )

        do {
            _ = try await MAFFTAlignmentPipeline(toolRunner: RecordingMSAToolRunner(alignedFASTA: ""))
                .run(request: request)
            XCTFail("Expected FASTQ input to be rejected unless explicitly allowed")
        } catch MAFFTAlignmentPipelineError.unsupportedInput(let url) {
            XCTAssertEqual(url.lastPathComponent, "contigs.fastq")
        } catch {
            XCTFail("Expected unsupportedInput, got \(error)")
        }
    }

    func testRunConvertsExplicitFASTQAssemblyInputsToControlledFASTA() async throws {
        let workspace = try makeWorkspace()
        let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let fastq = workspace.appendingPathComponent("assembled-contigs.fastq")
        try """
        @contig_one description
        ACGT
        +
        IIIH
        @contig_two
        ACGA
        +
        I!IH
        """.write(to: fastq, atomically: true, encoding: .utf8)

        let output = project.appendingPathComponent("FASTQ Contigs.lungfishmsa", isDirectory: true)
        let request = MSAAlignmentRunRequest(
            tool: .mafft,
            inputSequenceURLs: [fastq],
            projectURL: project,
            outputBundleURL: output,
            name: "FASTQ Contigs",
            threads: nil,
            allowFASTQAssemblyInputs: true
        )
        let runner = RecordingMSAToolRunner(alignedFASTA: ">contig_one\nACGT\n>contig_two\nAC-A\n")

        let result = try await MAFFTAlignmentPipeline(toolRunner: runner).run(request: request)
        let stagedInput = try String(
            contentsOf: result.bundleURL.appendingPathComponent("alignment/input.unaligned.fasta"),
            encoding: .utf8
        )
        let qualityStore = try MultipleSequenceAlignmentBundle
            .load(from: result.bundleURL)
            .loadFASTQQualityStore()

        XCTAssertTrue(stagedInput.contains(">contig_one\nACGT\n"))
        XCTAssertTrue(stagedInput.contains(">contig_two\nACGA\n"))
        XCTAssertEqual(qualityStore.records.map(\.rowName), ["contig_one", "contig_two"])
        XCTAssertEqual(qualityStore.records[0].meanQuality, 39.75, accuracy: 0.001)
        XCTAssertEqual(qualityStore.records[1].minimumQuality, 0)
        XCTAssertTrue(qualityStore.records.allSatisfy { $0.sourceFASTQPath == fastq.path })

        let provenanceText = try String(contentsOf: result.bundleURL.appendingPathComponent(".lungfish-provenance.json"), encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(provenanceText.contains("metadata/fastq-quality.json"))
        XCTAssertTrue(provenanceText.contains("--allow-fastq-assembly-inputs"))
    }

    private func makeWorkspace() throws -> URL {
        let root = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("mafft-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        cleanupURLs.append(root)
        return root
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func gzipFile(_ inputURL: URL, to outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", inputURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let compressed = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8) ?? "gzip failed"
            throw XCTSkip("Unable to create gzip fixture: \(detail)")
        }
        try compressed.write(to: outputURL, options: .atomic)
    }
}

private final class RecordingMSAToolRunner: MSAToolRunning, @unchecked Sendable {
    private let alignedFASTA: String
    private(set) var lastWorkingDirectory: URL?
    private(set) var lastArguments: [String]?

    init(alignedFASTA: String) {
        self.alignedFASTA = alignedFASTA
    }

    func runTool(
        name: String,
        arguments: [String],
        environment: String,
        workingDirectory: URL,
        environmentVariables: [String: String],
        timeout: TimeInterval,
        stderrHandler: (@Sendable (String) -> Void)?
    ) async throws -> MSAToolRunResult {
        lastWorkingDirectory = workingDirectory
        lastArguments = arguments
        return MSAToolRunResult(
            stdout: alignedFASTA,
            stderr: "MAFFT fake progress\n",
            exitCode: 0,
            executablePath: "/conda/envs/mafft/bin/mafft",
            version: "v7.526"
        )
    }
}
