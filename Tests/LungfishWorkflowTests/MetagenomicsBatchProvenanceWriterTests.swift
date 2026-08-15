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

    func testClassificationBatchRollupPreservesDegradedChildEvidenceAndBatchArtifacts() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "classification-batch-provenance-")
        let inputsDirectory = batchRoot.appendingPathComponent("inputs", isDirectory: true)
        let completedDirectory = batchRoot.appendingPathComponent("SampleComplete", isDirectory: true)
        let degradedDirectory = batchRoot.appendingPathComponent("SampleDegraded", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: degradedDirectory, withIntermediateDirectories: true)

        let completedInputURL = inputsDirectory.appendingPathComponent("SampleComplete.fastq")
        let degradedInputURL = inputsDirectory.appendingPathComponent("SampleDegraded.fastq")
        try "@complete\nACGT\n+\nIIII\n".write(
            to: completedInputURL,
            atomically: true,
            encoding: .utf8
        )
        try "@degraded\nTGCA\n+\nIIII\n".write(
            to: degradedInputURL,
            atomically: true,
            encoding: .utf8
        )

        let completedKrakenURL = completedDirectory.appendingPathComponent("classification.kraken")
        let completedReportURL = completedDirectory.appendingPathComponent("classification.kreport")
        let completedBrackenURL = completedDirectory.appendingPathComponent("classification.bracken")
        try "C\tcomplete\t2\t4\t1:2\n".write(to: completedKrakenURL, atomically: true, encoding: .utf8)
        try "100.00\t1\t1\tG\t2\tBacteria\n".write(
            to: completedReportURL,
            atomically: true,
            encoding: .utf8
        )
        try "name\ttaxonomy_id\ttaxonomy_lvl\tnew_est_reads\nBacteria\t2\tG\t1\n".write(
            to: completedBrackenURL,
            atomically: true,
            encoding: .utf8
        )

        let completedInput = try ProvenanceFileDescriptor.file(
            url: completedInputURL,
            format: .fastq,
            role: .input
        )
        let completedKraken = try ProvenanceFileDescriptor.file(
            url: completedKrakenURL,
            format: .text,
            role: .output
        )
        let completedReport = try ProvenanceFileDescriptor.file(
            url: completedReportURL,
            format: .text,
            role: .report
        )
        let completedBracken = try ProvenanceFileDescriptor.file(
            url: completedBrackenURL,
            format: .text,
            role: .report
        )
        let completedKrakenStep = ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", completedReportURL.path, completedInputURL.path],
            resolvedOptions: ["databasePath": .string("/databases/silva")],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "kraken2"),
            inputs: [completedInput],
            outputs: [completedKraken, completedReport],
            exitStatus: 0,
            wallTimeSeconds: 2.75
        )
        let completedBrackenStep = ProvenanceStep(
            toolName: "bracken",
            toolVersion: "3.0.1",
            argv: ["bracken", "-i", completedReportURL.path, "-o", completedBrackenURL.path, "-l", "G"],
            resolvedOptions: [
                "requestedRank": .string("automatic"),
                "resolvedRank": .string("G"),
                "readLength": .integer(150),
                "threshold": .integer(10),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "bracken"),
            inputs: [completedReport],
            outputs: [completedBracken],
            exitStatus: 0,
            wallTimeSeconds: 1.5,
            dependsOn: [completedKrakenStep.id]
        )
        let completedEnvelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 100),
            workflowName: "Metagenomics Classification",
            workflowVersion: "Lungfish test",
            toolName: "Kraken2 + Bracken",
            toolVersion: "2.17.1 / 3.0.1",
            tool: ProvenanceToolIdentity(name: "Kraken2 + Bracken", version: "2.17.1 / 3.0.1", kind: "cli"),
            argv: completedKrakenStep.argv,
            options: ProvenanceOptions(
                explicit: [
                    "goal": .string("profile"),
                    "database": .string("SILVA"),
                    "databaseVersion": .string("2026-07"),
                    "databaseCatalogID": .string("kraken2-special-silva"),
                    "brackenRankRequest": .string("automatic"),
                ],
                resolvedDefaults: [
                    "brackenResolvedRank": .string("G"),
                    "profileState": .string("completed"),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "kraken2"),
            files: [completedInput, completedKraken, completedReport, completedBracken],
            output: completedReport,
            outputs: [completedKraken, completedReport, completedBracken],
            steps: [completedKrakenStep, completedBrackenStep],
            wallTimeSeconds: 4.25,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(completedEnvelope, to: completedDirectory)

        let degradedKrakenURL = degradedDirectory.appendingPathComponent("classification.kraken")
        let degradedReportURL = degradedDirectory.appendingPathComponent("classification.kreport")
        try "C\tdegraded\t2\t4\t1:2\n".write(to: degradedKrakenURL, atomically: true, encoding: .utf8)
        try "100.00\t1\t1\tG\t2\tBacteria\n".write(
            to: degradedReportURL,
            atomically: true,
            encoding: .utf8
        )

        let degradedInput = try ProvenanceFileDescriptor.file(
            url: degradedInputURL,
            format: .fastq,
            role: .input
        )
        let degradedKraken = try ProvenanceFileDescriptor.file(
            url: degradedKrakenURL,
            format: .text,
            role: .output
        )
        let degradedReport = try ProvenanceFileDescriptor.file(
            url: degradedReportURL,
            format: .text,
            role: .report
        )
        let degradedKrakenStep = ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", degradedReportURL.path, degradedInputURL.path],
            resolvedOptions: ["databasePath": .string("/databases/silva")],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "kraken2"),
            inputs: [degradedInput],
            outputs: [degradedKraken, degradedReport],
            exitStatus: 0,
            wallTimeSeconds: 2.5
        )
        let degradationMessage = "Bracken distribution database150mers.kmer_distrib is unavailable"
        let degradedPreflightStep = ProvenanceStep(
            toolName: "Lungfish Bracken Preflight",
            toolVersion: "Lungfish test",
            argv: [
                "LungfishWorkflow",
                "BrackenPreflight",
                "--kreport",
                degradedReportURL.path,
                "--resolved-rank",
                "G",
            ],
            resolvedOptions: [
                "requestedRank": .string("automatic"),
                "resolvedRank": .string("G"),
                "readLength": .integer(150),
                "threshold": .integer(10),
            ],
            inputs: [degradedReport],
            outputs: [],
            exitStatus: 2,
            wallTimeSeconds: 0.25,
            stderr: degradationMessage,
            dependsOn: [degradedKrakenStep.id]
        )
        let degradedEnvelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 110),
            workflowName: "Metagenomics Classification",
            workflowVersion: "Lungfish test",
            toolName: "Kraken2 + Bracken",
            toolVersion: "2.17.1",
            tool: ProvenanceToolIdentity(name: "Kraken2 + Bracken", version: "2.17.1", kind: "cli"),
            argv: degradedKrakenStep.argv,
            options: ProvenanceOptions(
                explicit: [
                    "goal": .string("profile"),
                    "database": .string("SILVA"),
                    "databaseVersion": .string("2026-07"),
                    "databaseCatalogID": .string("kraken2-special-silva"),
                    "brackenRankRequest": .string("automatic"),
                ],
                resolvedDefaults: [
                    "brackenResolvedRank": .string("G"),
                    "profileState": .string("degraded"),
                    "profileReason": .string("distributionUnavailable"),
                    "profileMessage": .string(degradationMessage),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "kraken2"),
            files: [degradedInput, degradedKraken, degradedReport],
            output: degradedReport,
            outputs: [degradedKraken, degradedReport],
            steps: [degradedKrakenStep, degradedPreflightStep],
            wallTimeSeconds: 2.75,
            exitStatus: 2,
            stderr: degradationMessage
        )
        try ProvenanceWriter(signingProvider: nil).write(degradedEnvelope, to: degradedDirectory)

        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        let sqliteURL = batchRoot.appendingPathComponent("classification.sqlite")
        try "sample_id\tstatus\tprofile_state\trequested_rank\tresolved_rank\nSampleComplete\tok\tcompleted\tautomatic\tG\nSampleDegraded\tdegraded\tdegraded\tautomatic\tG\n"
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 90),
                sampleCount: 2
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-07",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleComplete",
                    resultDirectory: completedDirectory.lastPathComponent,
                    inputFiles: [completedInputURL.path],
                    isPairedEnd: false,
                    status: "ok",
                    message: nil
                ),
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleDegraded",
                    resultDirectory: degradedDirectory.lastPathComponent,
                    inputFiles: [degradedInputURL.path],
                    isPairedEnd: false,
                    status: "degraded",
                    message: degradationMessage
                ),
            ],
            completedCount: 1,
            degradedCount: 1,
            failedCount: 0
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)
        let manifestURL = batchRoot.appendingPathComponent(ClassificationBatchResultManifest.filename)

        try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL,
            command: ["LungfishApp", "classification-batch", "--output", batchRoot.path]
        )

        let rootEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        XCTAssertEqual(rootEnvelope.workflowName, "Classification Batch")
        XCTAssertTrue(rootEnvelope.steps.contains { $0.id == completedKrakenStep.id })
        XCTAssertTrue(rootEnvelope.steps.contains { $0.id == completedBrackenStep.id })
        XCTAssertTrue(rootEnvelope.steps.contains { $0.id == degradedKrakenStep.id })
        XCTAssertTrue(rootEnvelope.steps.contains { $0.id == degradedPreflightStep.id })
        for childOutput in [completedKrakenURL, completedReportURL, completedBrackenURL, degradedKrakenURL, degradedReportURL] {
            XCTAssertTrue(rootEnvelope.outputs.contains { $0.path == childOutput.path })
        }
        for inputURL in [completedInputURL, degradedInputURL] {
            XCTAssertTrue(rootEnvelope.files.contains {
                $0.path == inputURL.path && $0.role == .input && $0.checksumSHA256 != nil && $0.fileSize != nil
            })
        }
        for batchOutput in [summaryURL, manifestURL, sqliteURL] {
            XCTAssertTrue(rootEnvelope.outputs.contains {
                $0.path == batchOutput.path && $0.checksumSHA256 != nil && $0.fileSize != nil
            })
        }

        var options = rootEnvelope.options.defaults
        options.merge(rootEnvelope.options.explicit) { _, explicit in explicit }
        options.merge(rootEnvelope.options.resolvedDefaults) { _, resolved in resolved }
        XCTAssertEqual(options["databaseName"], .string("SILVA"))
        XCTAssertEqual(options["databaseVersion"], .string("2026-07"))
        XCTAssertEqual(options["goal"], .string("profile"))
        XCTAssertEqual(options["completedCount"], .integer(1))
        XCTAssertEqual(options["degradedCount"], .integer(1))
        XCTAssertEqual(options["failedCount"], .integer(0))
        XCTAssertEqual(options["resolvedProfileRanks"], .array([.string("G")]))
        XCTAssertNotEqual(rootEnvelope.exitStatus, 0)
        XCTAssertTrue(rootEnvelope.stderr?.contains(degradationMessage) == true)
        XCTAssertEqual(try XCTUnwrap(rootEnvelope.wallTimeSeconds), 7.0, accuracy: 0.000_001)
    }

    func testClassificationBatchRollupPreservesExistingBuildDbProvenanceExactlyOnce() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "classification-build-db-rollup-")
        let sampleDirectory = batchRoot.appendingPathComponent("SampleA", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)

        let inputURL = batchRoot.appendingPathComponent("SampleA.fastq")
        let reportURL = sampleDirectory.appendingPathComponent("classification.kreport")
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        let sqliteURL = batchRoot.appendingPathComponent("kraken2.sqlite")
        try "@read\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "100.00\t1\t1\tG\t2\tBacteria\n".write(
            to: reportURL,
            atomically: true,
            encoding: .utf8
        )
        try "sample_id\tstatus\nSampleA\tok\n".write(
            to: summaryURL,
            atomically: true,
            encoding: .utf8
        )
        try Data("sqlite fixture".utf8).write(to: sqliteURL)

        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let report = try ProvenanceFileDescriptor.file(url: reportURL, format: .text, role: .report)
        let classificationRuntime = ProvenanceRuntimeIdentity(
            appVersion: "Lungfish classification test",
            executablePath: "/Applications/Lungfish.app/Contents/MacOS/Lungfish",
            processIdentifier: 101,
            operatingSystemVersion: "macOS test",
            architecture: "arm64",
            user: "scientist",
            condaEnvironment: "kraken2",
            condaPrefix: "/opt/conda/envs/kraken2"
        )
        let classificationStep = ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", reportURL.path, inputURL.path],
            runtimeIdentity: classificationRuntime,
            inputs: [input],
            outputs: [report],
            exitStatus: 0,
            wallTimeSeconds: 2.25
        )
        let classificationEnvelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 100),
            workflowName: "Metagenomics Classification",
            workflowVersion: "Lungfish classification test",
            toolName: "kraken2",
            toolVersion: "2.17.1",
            tool: ProvenanceToolIdentity(name: "kraken2", version: "2.17.1", kind: "cli"),
            argv: classificationStep.argv,
            runtimeIdentity: classificationRuntime,
            files: [input, report],
            output: report,
            outputs: [report],
            steps: [classificationStep],
            wallTimeSeconds: 2.25,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(classificationEnvelope, to: sampleDirectory)

        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 90),
                sampleCount: 1
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-07",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleA",
                    resultDirectory: sampleDirectory.lastPathComponent,
                    inputFiles: [inputURL.path],
                    isPairedEnd: false,
                    status: "ok"
                ),
            ],
            completedCount: 1,
            degradedCount: 0,
            failedCount: 0
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)

        let sqliteOutput = try ProvenanceFileDescriptor.file(
            url: sqliteURL,
            format: .sqlite,
            role: .output
        )
        let buildDbRuntime = ProvenanceRuntimeIdentity(
            appVersion: "Lungfish CLI test",
            executablePath: "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
            processIdentifier: 202,
            operatingSystemVersion: "macOS test",
            architecture: "arm64",
            gitRevision: "build-db-revision",
            user: "scientist",
            condaEnvironment: "lungfish-cli",
            condaPrefix: "/opt/conda/envs/lungfish-cli"
        )
        let buildDbPreparationStep = ProvenanceStep(
            toolName: "Kraken2 SQLite Preparation",
            toolVersion: "Lungfish CLI test",
            argv: ["lungfish-cli", "build-db", "kraken2", "prepare", batchRoot.path],
            runtimeIdentity: buildDbRuntime,
            inputs: [report],
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: 0.75
        )
        let buildDbArgv = [
            "lungfish-cli",
            "build-db",
            "kraken2",
            batchRoot.path,
            "--force",
            "--sample-dir",
            sampleDirectory.path,
        ]
        let buildDbStep = ProvenanceStep(
            toolName: "lungfish build-db kraken2",
            toolVersion: "Lungfish CLI test",
            argv: buildDbArgv,
            inputs: [report],
            outputs: [sqliteOutput],
            exitStatus: 0,
            wallTimeSeconds: 3.0,
            dependsOn: [buildDbPreparationStep.id]
        )
        let buildDbOptions = ProvenanceOptions(
            explicit: [
                "force": .boolean(true),
                "resultDir": .file(batchRoot),
                "sampleDirs": .array([.file(sampleDirectory)]),
            ],
            defaults: [
                "force": .boolean(false),
                "noCleanup": .boolean(false),
                "outputFormat": .string("text"),
            ],
            resolvedDefaults: [
                "force": .boolean(true),
                "noCleanup": .boolean(false),
                "cleanupPerformed": .boolean(true),
                "databasePath": .file(sqliteURL),
                "sampleDirs": .array([.file(sampleDirectory)]),
            ]
        )
        let buildDbEnvelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 103),
            workflowName: "lungfish build-db kraken2",
            workflowVersion: "Lungfish CLI test",
            toolName: "lungfish build-db kraken2",
            toolVersion: "Lungfish CLI test",
            tool: ProvenanceToolIdentity(
                name: "lungfish build-db kraken2",
                version: "Lungfish CLI test",
                kind: "cli"
            ),
            argv: buildDbArgv,
            options: buildDbOptions,
            runtimeIdentity: buildDbRuntime,
            files: [report, sqliteOutput],
            output: sqliteOutput,
            outputs: [sqliteOutput],
            steps: [buildDbPreparationStep, buildDbStep],
            wallTimeSeconds: 3.75,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(buildDbEnvelope, to: batchRoot)

        try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL,
            command: ["LungfishApp", "classification-batch", "--output", batchRoot.path]
        )

        let rootEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        let preservedBuildDbStep = try XCTUnwrap(
            rootEnvelope.steps.first { $0.id == buildDbStep.id }
        )
        XCTAssertEqual(
            rootEnvelope.steps.filter { $0.id == buildDbStep.id }.count,
            1,
            "The preexisting build-db terminal step must be rolled up exactly once"
        )
        XCTAssertEqual(preservedBuildDbStep.toolName, buildDbStep.toolName)
        XCTAssertEqual(preservedBuildDbStep.toolVersion, buildDbStep.toolVersion)
        XCTAssertEqual(preservedBuildDbStep.argv, buildDbArgv)
        XCTAssertEqual(preservedBuildDbStep.inputs, buildDbStep.inputs)
        XCTAssertEqual(preservedBuildDbStep.outputs, [sqliteOutput])
        XCTAssertEqual(preservedBuildDbStep.exitStatus, 0)
        XCTAssertEqual(preservedBuildDbStep.wallTimeSeconds, 3.0)
        XCTAssertEqual(preservedBuildDbStep.dependsOn, [buildDbPreparationStep.id])
        XCTAssertEqual(preservedBuildDbStep.runtimeIdentity, buildDbRuntime)

        let structuredBuildDbOptions = ParameterValue.dictionary([
            "explicit": .dictionary(buildDbOptions.explicit),
            "defaults": .dictionary(buildDbOptions.defaults),
            "resolvedDefaults": .dictionary(buildDbOptions.resolvedDefaults),
        ])
        XCTAssertEqual(
            rootEnvelope.options.resolvedDefaults["buildDatabaseOptions"],
            structuredBuildDbOptions,
            "The rollup must retain build-db explicit options, defaults, and resolved defaults"
        )

        let rollupStep = try XCTUnwrap(
            rootEnvelope.steps.last { $0.toolName == "Lungfish Classification Batch" }
        )
        let expectedBatchRuntime = ProvenanceRuntimeIdentity()
        XCTAssertEqual(rootEnvelope.runtimeIdentity, expectedBatchRuntime)
        XCTAssertEqual(rollupStep.runtimeIdentity, expectedBatchRuntime)
        XCTAssertNotEqual(
            rootEnvelope.runtimeIdentity,
            classificationRuntime,
            "The app-level batch wrapper must not claim the managed Kraken2 child runtime"
        )
        XCTAssertTrue(
            rollupStep.dependsOn.contains(buildDbStep.id),
            "The classification rollup must depend on the preserved terminal build-db step"
        )
        XCTAssertEqual(
            try XCTUnwrap(rootEnvelope.wallTimeSeconds),
            6.0,
            accuracy: 0.000_001,
            "Classification and build-db wall time must each be counted once"
        )
    }

    func testClassificationBatchRollupRecordsOriginalInputForHardFailedSample() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "classification-hard-failure-input-")
        let returnedDirectory = batchRoot.appendingPathComponent("SampleReturned", isDirectory: true)
        try FileManager.default.createDirectory(at: returnedDirectory, withIntermediateDirectories: true)

        let returnedInputURL = batchRoot.appendingPathComponent("SampleReturned.fastq")
        let hardFailedInputURL = batchRoot.appendingPathComponent("SampleHardFailed.fastq")
        let returnedReportURL = returnedDirectory.appendingPathComponent("classification.kreport")
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        try "@returned\nACGT\n+\nIIII\n".write(
            to: returnedInputURL,
            atomically: true,
            encoding: .utf8
        )
        let hardFailedInputData = Data("@failed\nTGCA\n+\nIIII\n".utf8)
        try hardFailedInputData.write(to: hardFailedInputURL)
        try "100.00\t1\t1\tG\t2\tBacteria\n".write(
            to: returnedReportURL,
            atomically: true,
            encoding: .utf8
        )
        try "sample_id\tstatus\nSampleReturned\tok\nSampleHardFailed\tfailed\n".write(
            to: summaryURL,
            atomically: true,
            encoding: .utf8
        )

        let returnedInput = try ProvenanceFileDescriptor.file(
            url: returnedInputURL,
            format: .fastq,
            role: .input
        )
        let returnedReport = try ProvenanceFileDescriptor.file(
            url: returnedReportURL,
            format: .text,
            role: .report
        )
        let classificationStep = ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--report", returnedReportURL.path, returnedInputURL.path],
            inputs: [returnedInput],
            outputs: [returnedReport],
            exitStatus: 0,
            wallTimeSeconds: 1.0
        )
        let classificationEnvelope = ProvenanceEnvelope(
            workflowName: "Metagenomics Classification",
            workflowVersion: "Lungfish test",
            toolName: "kraken2",
            toolVersion: "2.17.1",
            tool: ProvenanceToolIdentity(name: "kraken2", version: "2.17.1", kind: "cli"),
            argv: classificationStep.argv,
            files: [returnedInput, returnedReport],
            output: returnedReport,
            outputs: [returnedReport],
            steps: [classificationStep],
            wallTimeSeconds: 1.0,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(classificationEnvelope, to: returnedDirectory)

        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 100),
                sampleCount: 2
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-07",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleReturned",
                    resultDirectory: returnedDirectory.lastPathComponent,
                    inputFiles: [returnedInputURL.path],
                    isPairedEnd: false,
                    status: "ok"
                ),
            ],
            completedCount: 1,
            degradedCount: 0,
            failedCount: 1
        )
        XCTAssertFalse(manifest.samples.flatMap(\.inputFiles).contains(hardFailedInputURL.path))
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)

        try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: nil,
            command: ["LungfishApp", "classification-batch", "--output", batchRoot.path],
            additionalInputURLs: [hardFailedInputURL]
        )

        let rootEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        let failedInputDescriptor = try XCTUnwrap(
            rootEnvelope.files.first {
                $0.path == hardFailedInputURL.path && $0.role == .input
            }
        )
        XCTAssertNotNil(failedInputDescriptor.checksumSHA256)
        XCTAssertEqual(failedInputDescriptor.fileSize, UInt64(hardFailedInputData.count))
    }

    func testClassificationBatchAllFailedBeforeToolPreservesConfigurationAndMeasuredTime() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "classification-all-failed-provenance-")
        let databaseURL = batchRoot.appendingPathComponent("silva-db", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let inputURL = batchRoot.appendingPathComponent("air-failed.fastq")
        let inputData = Data("@air-failed\nACGT\n+\nIIII\n".utf8)
        try inputData.write(to: inputURL)

        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        try "sample_id\tstatus\tprofile_state\trequested_rank\tresolved_rank\ttotal_reads\tclassified_reads\tclassified_pct\tspecies_count\tdominant_species\tmessage\nair-failed\tfailed\t\t\t\t\t\t\t\t\tInput validation failed\n"
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 200),
                sampleCount: 1
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [],
            completedCount: 0,
            degradedCount: 0,
            failedCount: 1
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)

        let sampleOutputURL = batchRoot.appendingPathComponent("air-failed", isDirectory: true)
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [inputURL],
            isPairedEnd: false,
            databaseName: "SILVA",
            databaseVersion: "2026-08",
            databasePath: databaseURL,
            databaseDigest: "sha256:silva-fixture",
            databaseCatalogID: "kraken2-special-silva",
            databaseInstallationRecipe: .kraken2Special(type: .silva),
            brackenProfileRequest: .automaticDefault,
            confidence: 0.35,
            minimumHitGroups: 3,
            threads: 7,
            memoryMapping: true,
            quickMode: false,
            outputDirectory: sampleOutputURL,
            extraArguments: ["--minimum-base-quality", "20"]
        )
        let startedAt = Date(timeIntervalSince1970: 190)
        let completedAt = Date(timeIntervalSince1970: 194.75)
        let context = ClassificationBatchProvenanceContext(
            configurations: [config],
            startedAt: startedAt,
            completedAt: completedAt
        )

        try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: nil,
            command: ["LungfishApp", "classification-batch", "--output", batchRoot.path],
            additionalStderr: ["Sample air-failed failed: Input validation failed"],
            additionalInputURLs: [inputURL],
            context: context
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batchRoot))
        XCTAssertTrue(manifest.samples.isEmpty, "The fixture must not obtain configuration from child envelopes")
        XCTAssertEqual(envelope.exitStatus, 1)
        XCTAssertEqual(try XCTUnwrap(envelope.wallTimeSeconds), 4.75, accuracy: 0.000_001)
        let batchStep = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "Lungfish Classification Batch" }
        )
        XCTAssertEqual(try XCTUnwrap(batchStep.wallTimeSeconds), 4.75, accuracy: 0.000_001)
        XCTAssertEqual(batchStep.startedAt, startedAt)
        XCTAssertEqual(
            try XCTUnwrap(batchStep.completedAt).timeIntervalSince1970,
            completedAt.timeIntervalSince1970,
            accuracy: 1
        )

        let inputDescriptor = try XCTUnwrap(envelope.files.first {
            $0.path == inputURL.path && $0.role == .input
        })
        XCTAssertNotNil(inputDescriptor.checksumSHA256)
        XCTAssertEqual(inputDescriptor.fileSize, UInt64(inputData.count))

        XCTAssertEqual(envelope.options.explicit["goal"], .string("profile"))
        XCTAssertEqual(envelope.options.explicit["databaseName"], .string("SILVA"))
        XCTAssertEqual(envelope.options.explicit["databaseVersion"], .string("2026-08"))
        XCTAssertEqual(envelope.options.explicit["databasePath"], .file(databaseURL))
        XCTAssertEqual(envelope.options.explicit["databaseDigest"], .string("sha256:silva-fixture"))
        XCTAssertEqual(envelope.options.explicit["databaseCatalogID"], .string("kraken2-special-silva"))
        XCTAssertEqual(
            envelope.options.explicit["databaseInstallationRecipe"],
            .string("kraken2-special:silva")
        )
        XCTAssertEqual(envelope.options.explicit["confidence"], .number(0.35))
        XCTAssertEqual(envelope.options.explicit["minimumHitGroups"], .integer(3))
        XCTAssertEqual(envelope.options.explicit["threads"], .integer(7))
        XCTAssertEqual(envelope.options.explicit["memoryMapping"], .boolean(true))
        XCTAssertEqual(envelope.options.explicit["quickMode"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["pairedEnd"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["extraArgs"], .string("--minimum-base-quality 20"))
        XCTAssertEqual(envelope.options.explicit["brackenRankRequest"], .string("automatic"))
        XCTAssertEqual(envelope.options.explicit["brackenRequestedReadLength"], .integer(150))
        XCTAssertEqual(envelope.options.explicit["brackenRequestedThreshold"], .integer(10))

        XCTAssertEqual(envelope.options.defaults["brackenRankRequest"], .string("automatic"))
        XCTAssertEqual(envelope.options.defaults["brackenReadLength"], .integer(150))
        XCTAssertEqual(envelope.options.defaults["brackenThreshold"], .integer(10))
        XCTAssertEqual(envelope.options.resolvedDefaults["brackenResolvedRank"], .string("G"))
        XCTAssertEqual(
            envelope.options.resolvedDefaults["brackenResolutionSource"],
            .string("catalogIdentity")
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["brackenReadLength"], .integer(150))
        XCTAssertEqual(envelope.options.resolvedDefaults["brackenThreshold"], .integer(10))
        XCTAssertEqual(envelope.options.resolvedDefaults["effectiveMemoryMapping"], .boolean(true))
    }

    func testClassificationBatchRollupRejectsMissingSampleProvenance() throws {
        let batchRoot = try makeTemporaryDirectory(prefix: "classification-batch-missing-child-")
        let sampleDirectory = batchRoot.appendingPathComponent("SampleMissing", isDirectory: true)
        try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        let inputURL = batchRoot.appendingPathComponent("SampleMissing.fastq")
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        try "@read\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "sample_id\tstatus\nSampleMissing\tok\n"
            .write(to: summaryURL, atomically: true, encoding: .utf8)
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: Date(timeIntervalSince1970: 1),
                sampleCount: 1
            ),
            goal: "profile",
            databaseName: "SILVA",
            databaseVersion: "2026-07",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [
                MetagenomicsBatchSampleRecord(
                    sampleId: "SampleMissing",
                    resultDirectory: sampleDirectory.lastPathComponent,
                    inputFiles: [inputURL.path],
                    isPairedEnd: false,
                    status: "ok"
                ),
            ],
            completedCount: 1,
            degradedCount: 0,
            failedCount: 0
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)

        XCTAssertThrowsError(
            try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
                batchRoot: batchRoot,
                manifest: manifest,
                summaryURL: summaryURL,
                sqliteURL: nil,
                command: ["LungfishApp", "classification-batch"]
            )
        ) { error in
            XCTAssertEqual(
                error as? MetagenomicsBatchProvenanceWriterError,
                .missingClassificationSampleProvenance(
                    sampleId: "SampleMissing",
                    directory: sampleDirectory.path
                )
            )
        }
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
            try MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: batchRoot)
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
        let workflowSourceDirectory = resultDirectory
            .appendingPathComponent("workflow-source/taxtriage/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workflowSourceDirectory, withIntermediateDirectories: true)
        let reportURL = reportDirectory.appendingPathComponent("SampleD.organisms.report.txt")
        let workflowSourceURL = workflowSourceDirectory.appendingPathComponent("large-reference.tsv")
        let traceURL = resultDirectory.appendingPathComponent("trace.txt")
        let logURL = resultDirectory.appendingPathComponent("nextflow.log")
        let sqliteURL = resultDirectory.appendingPathComponent("taxtriage.sqlite")
        try "@r\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)
        try "organism\treads\nExample virus\t7\n".write(to: reportURL, atomically: true, encoding: .utf8)
        try "large reference fixture\n".write(to: workflowSourceURL, atomically: true, encoding: .utf8)
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
            allOutputFiles: [reportURL, logURL, traceURL, workflowSourceURL]
        )
        try result.save()

        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory))

        let sidecarURL = try XCTUnwrap(
            try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
        )

        XCTAssertEqual(sidecarURL.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: resultDirectory)?.envelope)
        XCTAssertEqual(envelope.workflowName, "TaxTriage")
        XCTAssertEqual(envelope.toolName, "TaxTriage")
        XCTAssertEqual(envelope.githubReleaseVersion, TaxTriageConfig.defaultGithubReleaseVersion)
        XCTAssertEqual(envelope.steps.first?.githubReleaseVersion, TaxTriageConfig.defaultGithubReleaseVersion)
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "TaxTriage" })
        XCTAssertTrue(envelope.outputs.contains { $0.path == sqliteURL.path })
        XCTAssertTrue(envelope.files.contains { $0.path == fastqURL.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.defaults["topHitsCount"], .integer(10))
        XCTAssertEqual(envelope.options.defaults["github_release_version"], .string(TaxTriageConfig.defaultGithubReleaseVersion))
        XCTAssertEqual(envelope.options.resolvedDefaults["github_release_version"], .string(TaxTriageConfig.defaultGithubReleaseVersion))
        XCTAssertEqual(envelope.options.resolvedDefaults["maxCpus"], .integer(config.maxCpus))
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "nextflow")
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertFalse(envelope.outputs.contains { $0.path.contains("/workflow-source/") })
        XCTAssertFalse(envelope.files.contains { $0.path.contains("/workflow-source/") })
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
            try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
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
            try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: resultDirectory)
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
