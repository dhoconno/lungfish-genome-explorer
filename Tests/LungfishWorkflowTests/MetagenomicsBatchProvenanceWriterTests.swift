import XCTest
@testable import LungfishWorkflow

final class MetagenomicsBatchProvenanceWriterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testEsVirituBatchRollupWritesRootProvenanceFromSampleSidecars() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "esviritu-batch-provenance-")
        let sampleDirectory = batchRoot.appendingPathComponent("SampleA", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

        let inputURL = sampleDirectory.appendingPathComponent("SampleA.fastq")
        let detectionURL = sampleDirectory.appendingPathComponent("SampleA.detected_virus.info.tsv")
        let summaryURL = batchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
        let sqliteURL = batchRoot.appendingPathComponent("esviritu.sqlite")
        try "@r1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "virus\treads\nExample virus\t12\n".write(to: detectionURL, atomically: true, encoding: .utf8)
        try "sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror\nSampleA\tok\t1\t1\t1\t\n"
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: detectionURL, format: .text, role: .output)
        let childStep = ProvenanceStep(
            toolName: "EsViritu",
            toolVersion: "1.2.3",
            argv: ["EsViritu", "--input", inputURL.path],
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 4.5,
            stderr: "EsViritu warning: low viral read depth"
        )
        let childEnvelope = ProvenanceEnvelope(
            workflowName: "Viral Metagenomics Detection",
            workflowVersion: "Lungfish test",
            toolName: "EsViritu",
            toolVersion: "1.2.3",
            tool: ProvenanceToolIdentity(name: "EsViritu", version: "1.2.3", kind: "cli"),
            argv: childStep.argv,
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [childStep],
            wallTimeSeconds: 4.5,
            exitStatus: 0,
            stderr: "EsViritu warning: low viral read depth"
        )
        try ProvenanceWriter(signingProvider: nil).write(childEnvelope, to: sampleDirectory)

        let manifest = EsVirituBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 1,
                createdAt: Date(timeIntervalSince1970: 10),
                sampleCount: 1
            ),
            summaryTSV: summaryURL.lastPathComponent,
            samples: [
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleA",
                    resultDirectory: "SampleA",
                    inputFiles: [inputURL.path],
                    isPairedEnd: false
                )
            ]
        )

        try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL,
            command: ["lungfish", "esviritu", "detect", "--input", inputURL.path]
        )

        let rootEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        XCTAssertEqual(rootEnvelope.workflowName, "EsViritu Batch")
        XCTAssertTrue(rootEnvelope.steps.contains { $0.toolName == "EsViritu" })
        XCTAssertTrue(rootEnvelope.steps.contains { $0.toolName == "Lungfish EsViritu Batch" })
        XCTAssertTrue(rootEnvelope.outputs.contains { $0.path == summaryURL.path })
        XCTAssertTrue(rootEnvelope.outputs.contains { $0.path == sqliteURL.path })
        XCTAssertTrue(rootEnvelope.stderr?.contains("low viral read depth") == true)
        XCTAssertEqual(rootEnvelope.options.defaults["summaryFilename"], .string("esviritu-batch-summary.tsv"))
        XCTAssertEqual(rootEnvelope.options.resolvedDefaults["summaryTSV"], .string(summaryURL.path))
        XCTAssertTrue(rootEnvelope.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: batchRoot))
    }

    func testEsVirituBackfillReconstructsRootProvenanceWithoutManifest() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "esviritu-batch-backfill-")
        let sampleDirectory = batchRoot.appendingPathComponent("SampleB", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

        let inputURL = sampleDirectory.appendingPathComponent("SampleB.fastq")
        let detectionURL = sampleDirectory.appendingPathComponent("SampleB.detected_virus.info.tsv")
        let sqliteURL = batchRoot.appendingPathComponent("esviritu.sqlite")
        try "@r1\nTGCA\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "virus\treads\nExample virus\t8\n".write(to: detectionURL, atomically: true, encoding: .utf8)
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: detectionURL, format: .text, role: .output)
        let childStep = ProvenanceStep(
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            argv: ["EsViritu", "--input", inputURL.path],
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 2.0
        )
        let childEnvelope = ProvenanceEnvelope(
            workflowName: "Viral Metagenomics Detection",
            workflowVersion: "Lungfish test",
            toolName: "EsViritu",
            toolVersion: "2.0.0",
            tool: ProvenanceToolIdentity(name: "EsViritu", version: "2.0.0", kind: "cli"),
            argv: childStep.argv,
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [childStep],
            wallTimeSeconds: 2.0,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(childEnvelope, to: sampleDirectory)

        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: batchRoot))

        let backfilledURL = try XCTUnwrap(
            MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: batchRoot)
        )

        XCTAssertEqual(backfilledURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        XCTAssertNotNil(MetagenomicsBatchResultStore.loadEsViritu(from: batchRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent("esviritu-batch-summary.tsv").path))
        let rootEnvelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: batchRoot)?.envelope)
        XCTAssertEqual(rootEnvelope.workflowName, "EsViritu Batch")
        XCTAssertTrue(rootEnvelope.steps.contains { $0.toolName == "EsViritu" })
        XCTAssertTrue(rootEnvelope.outputs.contains { $0.path == sqliteURL.path })
    }

    func testTaxTriageBackfillWritesRootProvenanceFromResultSidecar() throws {
        let resultDirectory = try makeTemporaryDirectory(prefix: "taxtriage-batch-backfill-")

        let fastqURL = resultDirectory.appendingPathComponent("SampleD.fastq")
        let reportDirectory = resultDirectory.appendingPathComponent("report", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let reportURL = reportDirectory.appendingPathComponent("SampleD.organisms.report.txt")
        let traceURL = resultDirectory.appendingPathComponent("trace.txt")
        let logURL = resultDirectory.appendingPathComponent("nextflow.log")
        let sqliteURL = resultDirectory.appendingPathComponent("taxtriage.sqlite")
        try "@r\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "organism\treads\nExample virus\t7\n".write(to: reportURL, atomically: true, encoding: .utf8)
        try "task_id\tstatus\n1\tCOMPLETED\n".write(to: traceURL, atomically: true, encoding: .utf8)
        try "TaxTriage complete\n".write(to: logURL, atomically: true, encoding: .utf8)
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "SampleD", fastq1: fastqURL)
            ],
            outputDirectory: resultDirectory,
            maxCpus: 4,
            profile: "docker"
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 12.5,
            exitCode: 0,
            outputDirectory: resultDirectory,
            reportFiles: [reportURL],
            logFile: logURL,
            traceFile: traceURL,
            allOutputFiles: [reportURL, logURL, traceURL]
        )
        try result.save()

        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory))

        let sidecarURL = try XCTUnwrap(
            MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
        )

        XCTAssertEqual(sidecarURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory)?.envelope)
        XCTAssertEqual(envelope.workflowName, "TaxTriage")
        XCTAssertEqual(envelope.toolName, "TaxTriage")
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "TaxTriage" })
        XCTAssertTrue(envelope.outputs.contains { $0.path == sqliteURL.path })
        XCTAssertTrue(envelope.files.contains { $0.path == fastqURL.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.defaults["topHitsCount"], .integer(10))
        XCTAssertEqual(envelope.options.resolvedDefaults["maxCpus"], .integer(config.maxCpus))
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "nextflow")
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
    }

    func testTaxTriageFailedBackfillCapturesUsefulLogStderr() throws {
        let resultDirectory = try makeTemporaryDirectory(prefix: "taxtriage-failed-backfill-")

        let fastqURL = resultDirectory.appendingPathComponent("SampleF.fastq")
        let logURL = resultDirectory.appendingPathComponent("nextflow.log")
        try "@r\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "ERROR ~ TaxTriage failed while classifying SampleF\n".write(to: logURL, atomically: true, encoding: .utf8)

        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "SampleF", fastq1: fastqURL)
            ],
            outputDirectory: resultDirectory,
            profile: "conda"
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 7.25,
            exitCode: 2,
            outputDirectory: resultDirectory,
            logFile: logURL,
            allOutputFiles: [logURL]
        )
        try result.save()

        let sidecarURL = try XCTUnwrap(
            MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
        )

        XCTAssertEqual(sidecarURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory)?.envelope)
        XCTAssertEqual(envelope.exitStatus, 2)
        XCTAssertEqual(envelope.wallTimeSeconds, 7.25)
        XCTAssertTrue(envelope.stderr?.contains("TaxTriage failed while classifying SampleF") == true)
        XCTAssertTrue(envelope.steps.contains {
            $0.toolName == "TaxTriage"
                && $0.exitStatus == 2
                && $0.stderr?.contains("TaxTriage failed while classifying SampleF") == true
        })
    }

    func testTaxTriageBackfillPreservesExistingPipelineProvenanceWhenAddingSQLite() throws {
        let resultDirectory = try makeTemporaryDirectory(prefix: "taxtriage-existing-provenance-")

        let fastqURL = resultDirectory.appendingPathComponent("SampleE.fastq")
        let reportDirectory = resultDirectory.appendingPathComponent("report", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let reportURL = reportDirectory.appendingPathComponent("SampleE.organisms.report.txt")
        let logURL = resultDirectory.appendingPathComponent("nextflow.log")
        let resultSidecarURL = resultDirectory.appendingPathComponent("taxtriage-result.json")
        let sqliteURL = resultDirectory.appendingPathComponent("taxtriage.sqlite")
        try "@r\nTGCA\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "organism\treads\nExample virus\t5\n".write(to: reportURL, atomically: true, encoding: .utf8)
        try "TaxTriage complete\n".write(to: logURL, atomically: true, encoding: .utf8)
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "SampleE", fastq1: fastqURL)
            ],
            outputDirectory: resultDirectory,
            maxCpus: 4,
            profile: "docker"
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 8.0,
            exitCode: 0,
            outputDirectory: resultDirectory,
            reportFiles: [reportURL],
            logFile: logURL,
            allOutputFiles: [reportURL, logURL]
        )
        try result.save()

        let input = try ProvenanceFileDescriptor.file(url: fastqURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: reportURL, format: .text, role: .output)
        let exactArgv = [
            "/opt/homebrew/bin/micromamba",
            "run",
            "-n",
            "nextflow",
            "nextflow",
            "run",
            "jhuapl-bio/taxtriage",
            "--input",
            config.samplesheetURL.path,
            "--outdir",
            resultDirectory.path,
        ]
        let step = ProvenanceStep(
            toolName: "TaxTriage",
            toolVersion: config.revision,
            argv: exactArgv,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 8.0
        )
        let existingEnvelope = ProvenanceEnvelope(
            workflowName: "TaxTriage",
            workflowVersion: "Lungfish test",
            toolName: "TaxTriage",
            toolVersion: config.revision,
            tool: ProvenanceToolIdentity(name: "TaxTriage", version: config.revision, kind: "nextflow"),
            argv: exactArgv,
            options: ProvenanceOptions(explicit: ["profile": .string(config.profile)]),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 8.0,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(existingEnvelope, to: resultDirectory)

        let sidecarURL = try XCTUnwrap(
            MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
        )

        XCTAssertEqual(sidecarURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory)?.envelope)
        XCTAssertEqual(envelope.argv, exactArgv)
        XCTAssertEqual(envelope.steps.first?.argv, exactArgv)
        XCTAssertTrue(envelope.outputs.contains { $0.path == sqliteURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(envelope.files.contains { $0.path == sqliteURL.path && $0.fileSize != nil })
        XCTAssertTrue(envelope.steps.contains {
            $0.toolName == "Lungfish TaxTriage Index" && $0.outputs.contains { $0.path == sqliteURL.path }
        })
        XCTAssertTrue(envelope.outputs.contains { $0.path == resultSidecarURL.path })
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
