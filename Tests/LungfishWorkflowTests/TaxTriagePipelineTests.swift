// TaxTriagePipelineTests.swift - Tests for TaxTriage pipeline integration
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class TaxTriagePipelineTests: XCTestCase {

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func runCommand(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TaxTriagePipelineTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private func createDirtyCachedTaxTriageRepository(in home: URL) throws -> (repoURL: URL, revision: String) {
        let repoURL = home
            .appendingPathComponent(".nextflow", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("jhuapl-bio", isDirectory: true)
            .appendingPathComponent("taxtriage", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent("modules/local", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent("workflows", isDirectory: true), withIntermediateDirectories: true)

        let downloadScript = """
        def get_url(utl, id):
            bb = os.path.basename(utl)
            return utl+"/"+bb+"_genomic.fna.gz"
        """
        try downloadScript.write(
            to: repoURL.appendingPathComponent("bin/download_fastas.py"),
            atomically: true,
            encoding: .utf8
        )

        let workflow = """
        workflow TAXTRIAGE {
            if (!ch_assembly_txt) {
                GET_ASSEMBLIES()
            }
        }
        """
        try workflow.write(
            to: repoURL.appendingPathComponent("workflows/taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )

        let alignmentPerSample = #"""
        process ALIGNMENT_PER_SAMPLE {
            when:
            task.ext.when == null || task.ext.when

            script:
            def output = "${meta.id}.paths.txt"
            def k2 = k2_report.name == "NO_FILE" ? " " : " --k2 ${k2_report} "
            def mapping = mapping.name != "NO_FILE" ? "-m $mapping " : " "
            def sensitive = " "
            def gap_allowance = " "
            def jump_threshold = " "
            """

            match_paths.py \\
                -o $output \\
                -p $pathogens_list  $mapping $k2 $sensitive $gap_allowance $jump_threshold \\
                --fast

            cat <<-END_VERSIONS > versions.yml
            "${task.process}":
                python: \$(python --version)
            END_VERSIONS
            """
        }
        """#
        try alignmentPerSample.write(
            to: repoURL.appendingPathComponent("modules/local/alignment_per_sample.nf"),
            atomically: true,
            encoding: .utf8
        )

        try runCommand("/usr/bin/git", ["init", "--initial-branch=main"], workingDirectory: repoURL)
        try runCommand("/usr/bin/git", ["config", "user.email", "codex@example.com"], workingDirectory: repoURL)
        try runCommand("/usr/bin/git", ["config", "user.name", "Codex"], workingDirectory: repoURL)
        try runCommand("/usr/bin/git", ["add", "."], workingDirectory: repoURL)
        try runCommand("/usr/bin/git", ["commit", "-m", "Initial"], workingDirectory: repoURL)
        let revision = try runCommand("/usr/bin/git", ["rev-parse", "HEAD"], workingDirectory: repoURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let dirtyDownloadScript = """
        def get_url(utl, id):
            bb = os.path.basename(utl.rstrip('/'))
            return utl.rstrip("/")+"/"+bb+"_genomic.fna.gz"
        """
        try dirtyDownloadScript.write(
            to: repoURL.appendingPathComponent("bin/download_fastas.py"),
            atomically: true,
            encoding: .utf8
        )

        let dirtyWorkflow = """
        workflow TAXTRIAGE {
            if (!ch_assembly_txt && !params.skip_refpull && !params.skip_realignment) {
                GET_ASSEMBLIES()
            }
        }
        """
        try dirtyWorkflow.write(
            to: repoURL.appendingPathComponent("workflows/taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )

        return (repoURL, revision)
    }

    func testParseIgnoredFailuresFromNextflowLog() {
        let log = """
        [aa/111111] Submitted process > NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35517992.SRR35517992.dwnld.references)
        ERROR ~ Error executing process > 'NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35517992.SRR35517992.dwnld.references)'
        NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35517992.SRR35517992.dwnld.references)` terminated with an error exit status (1) -- Error is ignored
        NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35518015.SRR35518015.dwnld.references)` terminated with an error exit status (137) -- Error is ignored
        """

        let failures = TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: log)

        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures[0].processName, "MINIMAP2_ALIGN")
        XCTAssertEqual(failures[0].sampleID, "SRR35517992")
        XCTAssertEqual(failures[0].exitCode, 1)
        XCTAssertEqual(failures[1].sampleID, "SRR35518015")
        XCTAssertEqual(failures[1].exitCode, 137)
    }

    func testResultSummaryMentionsIgnoredFailures() {
        let result = TaxTriageResult(
            config: TaxTriageConfig(
                samples: [
                    TaxTriageSample(
                        sampleId: "SRR35517992",
                        fastq1: URL(fileURLWithPath: "/tmp/SRR35517992.fastq.gz"),
                        platform: .illumina
                    ),
                ],
                outputDirectory: URL(fileURLWithPath: "/tmp/taxtriage")
            ),
            runtime: 12,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/tmp/taxtriage"),
            reportFiles: [],
            metricsFiles: [],
            kronaFiles: [],
            logFile: nil,
            traceFile: nil,
            allOutputFiles: [],
            ignoredFailures: [
                TaxTriageIgnoredFailure(
                    processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN",
                    processName: "MINIMAP2_ALIGN",
                    taskLabel: "SRR35517992.SRR35517992.dwnld.references",
                    sampleID: "SRR35517992",
                    exitCode: 1
                ),
            ]
        )

        XCTAssertTrue(result.summary.contains("completed with warnings"))
        XCTAssertTrue(result.summary.contains("Ignored sample failures: 1"))
    }

    // MARK: - TaxTriageConfig Tests

    func testDefaultConfig() {
        let sample = TaxTriageSample(
            sampleId: "TestSample",
            fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
            fastq2: nil,
            platform: .illumina
        )

        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )

        XCTAssertEqual(config.samples.count, 1)
        XCTAssertEqual(config.platform, .illumina)
        XCTAssertEqual(config.classifiers, ["kraken2"])
        XCTAssertEqual(config.topHitsCount, 10)
        XCTAssertEqual(config.k2Confidence, 0.2)
        XCTAssertEqual(config.rank, "S")
        XCTAssertTrue(config.skipAssembly)
        XCTAssertFalse(config.skipKrona)
        XCTAssertEqual(config.maxMemory, "16.GB")
        XCTAssertEqual(config.profile, "docker")
        XCTAssertNil(config.kraken2DatabasePath)
        XCTAssertEqual(config.revision, TaxTriageConfig.defaultRevision)
        XCTAssertNotEqual(config.revision, "main")
    }

    func testConfigWithAllParameters() {
        let sample = TaxTriageSample(
            sampleId: "Sample1",
            fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
            fastq2: URL(fileURLWithPath: "/data/R2.fastq.gz"),
            platform: .oxford
        )

        let config = TaxTriageConfig(
            samples: [sample],
            platform: .oxford,
            outputDirectory: URL(fileURLWithPath: "/results"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db/kraken2"),
            classifiers: ["kraken2"],
            topHitsCount: 20,
            k2Confidence: 0.5,
            rank: "G",
            skipAssembly: false,
            skipKrona: true,
            maxMemory: "32.GB",
            maxCpus: 16,
            profile: "conda",
            containerRuntime: "docker",
            revision: "v1.0"
        )

        XCTAssertEqual(config.platform, .oxford)
        XCTAssertEqual(config.topHitsCount, 20)
        XCTAssertEqual(config.k2Confidence, 0.5)
        XCTAssertEqual(config.rank, "G")
        XCTAssertFalse(config.skipAssembly)
        XCTAssertTrue(config.skipKrona)
        XCTAssertEqual(config.maxMemory, "32.GB")
        XCTAssertEqual(config.maxCpus, 16)
        XCTAssertEqual(config.profile, "conda")
        XCTAssertEqual(config.containerRuntime, "docker")
        XCTAssertEqual(config.revision, "v1.0")
        XCTAssertNotNil(config.kraken2DatabasePath)
    }

    func testConfigSamplesheetURL() {
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/results/run1")
        )

        XCTAssertEqual(
            config.samplesheetURL.path,
            "/results/run1/samplesheet.csv"
        )
    }

    func testPipelineRepository() {
        XCTAssertEqual(TaxTriageConfig.pipelineRepository, "jhuapl-bio/taxtriage")
    }

    // MARK: - Platform Tests

    func testPlatformRawValues() {
        XCTAssertEqual(TaxTriageConfig.Platform.illumina.rawValue, "ILLUMINA")
        XCTAssertEqual(TaxTriageConfig.Platform.oxford.rawValue, "OXFORD")
        XCTAssertEqual(TaxTriageConfig.Platform.pacbio.rawValue, "PACBIO")
    }

    func testPlatformDisplayNames() {
        XCTAssertEqual(TaxTriageConfig.Platform.illumina.displayName, "Illumina")
        XCTAssertEqual(TaxTriageConfig.Platform.oxford.displayName, "Oxford Nanopore")
        XCTAssertEqual(TaxTriageConfig.Platform.pacbio.displayName, "PacBio")
    }

    func testAllPlatformsHaveDisplayNames() {
        for platform in TaxTriageConfig.Platform.allCases {
            XCTAssertFalse(
                platform.displayName.isEmpty,
                "\(platform) should have a display name"
            )
        }
    }

    func testPlatformCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for platform in TaxTriageConfig.Platform.allCases {
            let data = try encoder.encode(platform)
            let decoded = try decoder.decode(TaxTriageConfig.Platform.self, from: data)
            XCTAssertEqual(decoded, platform)
        }
    }

    // MARK: - TaxTriageSample Tests

    func testSampleSingleEnd() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            fastq2: nil,
            platform: .illumina
        )

        XCTAssertEqual(sample.id, "S1")
        XCTAssertEqual(sample.sampleId, "S1")
        XCTAssertFalse(sample.isPairedEnd)
        XCTAssertEqual(sample.allFiles.count, 1)
    }

    func testSamplePairedEnd() {
        let sample = TaxTriageSample(
            sampleId: "S2",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            fastq2: URL(fileURLWithPath: "/data/R2.fq.gz"),
            platform: .oxford
        )

        XCTAssertTrue(sample.isPairedEnd)
        XCTAssertEqual(sample.allFiles.count, 2)
        XCTAssertEqual(sample.platform, .oxford)
    }

    func testSampleEquatable() {
        let sample1 = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        let sample2 = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        XCTAssertEqual(sample1, sample2)
    }

    func testSampleCodable() throws {
        let sample = TaxTriageSample(
            sampleId: "CodeTest",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            fastq2: URL(fileURLWithPath: "/data/reads_R2.fq.gz"),
            platform: .pacbio
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(sample)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageSample.self, from: data)

        XCTAssertEqual(decoded.sampleId, "CodeTest")
        XCTAssertEqual(decoded.platform, .pacbio)
        XCTAssertTrue(decoded.isPairedEnd)
    }

    // MARK: - Validation Tests

    func testValidationNoSamples() {
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .noSamples = configError {
                // Expected
            } else {
                XCTFail("Expected .noSamples, got \(configError)")
            }
        }
    }

    func testValidationEmptySampleId() {
        let sample = TaxTriageSample(
            sampleId: "",
            fastq1: URL(fileURLWithPath: "/data/reads.fq"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .emptySampleId = configError {
                // Expected
            } else {
                XCTFail("Expected .emptySampleId, got \(configError)")
            }
        }
    }

    func testValidationInputFileNotFound() {
        let sample = TaxTriageSample(
            sampleId: "Test",
            fastq1: URL(fileURLWithPath: "/nonexistent/file.fastq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .inputFileNotFound(let sampleId, _) = configError {
                XCTAssertEqual(sampleId, "Test")
            } else {
                XCTFail("Expected .inputFileNotFound, got \(configError)")
            }
        }
    }

    func testValidationDuplicateSampleIds() throws {
        // Create temporary files so they pass the file existence check
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("R1.fq.gz")
        let file2 = tempDir.appendingPathComponent("R2.fq.gz")
        try Data().write(to: file1)
        try Data().write(to: file2)

        let sample1 = TaxTriageSample(
            sampleId: "DupSample",
            fastq1: file1,
            platform: .illumina
        )
        let sample2 = TaxTriageSample(
            sampleId: "DupSample",
            fastq1: file2,
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample1, sample2],
            outputDirectory: tempDir
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .duplicateSampleIds(let ids) = configError {
                XCTAssertEqual(ids, ["DupSample"])
            } else {
                XCTFail("Expected .duplicateSampleIds, got \(configError)")
            }
        }
    }

    func testValidationInvalidConfidence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("reads.fq.gz")
        try Data().write(to: file1)

        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: file1,
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: tempDir,
            k2Confidence: 1.5
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .invalidK2Confidence(let value) = configError {
                XCTAssertEqual(value, 1.5)
            } else {
                XCTFail("Expected .invalidK2Confidence, got \(configError)")
            }
        }
    }

    func testValidationInvalidTopHitsCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("reads.fq.gz")
        try Data().write(to: file1)

        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: file1,
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: tempDir,
            topHitsCount: 0
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .invalidTopHitsCount(let value) = configError {
                XCTAssertEqual(value, 0)
            } else {
                XCTFail("Expected .invalidTopHitsCount, got \(configError)")
            }
        }
    }

    func testValidationDatabaseNotFound() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("reads.fq.gz")
        try Data().write(to: file1)

        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: file1,
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: tempDir,
            kraken2DatabasePath: URL(fileURLWithPath: "/nonexistent/db")
        )

        XCTAssertThrowsError(try config.validate()) { error in
            guard let configError = error as? TaxTriageConfigError else {
                XCTFail("Expected TaxTriageConfigError"); return
            }
            if case .databaseNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .databaseNotFound, got \(configError)")
            }
        }
    }

    // MARK: - Nextflow Argument Building Tests

    func testNextflowArgumentsBasic() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let args = config.nextflowArguments()

        XCTAssertTrue(args.contains("jhuapl-bio/taxtriage"))
        XCTAssertTrue(args.contains("-r"))
        XCTAssertTrue(args.contains(TaxTriageConfig.defaultRevision))
        XCTAssertTrue(args.contains("-profile"))
        XCTAssertTrue(args.contains("docker"))
        XCTAssertTrue(args.contains("--input"))
        XCTAssertTrue(args.contains("--outdir"))
        XCTAssertTrue(args.contains("--skip_assembly"))
        XCTAssertFalse(args.contains("--skip_krona"))
    }

    func testNextflowArgumentsWithDatabase() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db/kraken2")
        )

        let args = config.nextflowArguments()

        XCTAssertTrue(args.contains("--db"))
        XCTAssertTrue(args.contains("/db/kraken2"))
    }

    func testNextflowArgumentsNoSkipAssembly() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output"),
            skipAssembly: false,
            skipKrona: true
        )

        let args = config.nextflowArguments()

        XCTAssertFalse(args.contains("--skip_assembly"))
        XCTAssertTrue(args.contains("--skip_krona"))
    }

    // MARK: - TaxTriageResult Tests

    func testResultSummarySuccess() {
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(
                sampleId: "S1",
                fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
                platform: .illumina
            )],
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 120.5,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/output"),
            reportFiles: [URL(fileURLWithPath: "/output/report.txt")],
            metricsFiles: [URL(fileURLWithPath: "/output/metrics.tsv")],
            kronaFiles: [URL(fileURLWithPath: "/output/krona.html")],
            allOutputFiles: [
                URL(fileURLWithPath: "/output/report.txt"),
                URL(fileURLWithPath: "/output/metrics.tsv"),
                URL(fileURLWithPath: "/output/krona.html"),
            ]
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.summary.contains("successfully"))
        XCTAssertTrue(result.summary.contains("120.5"))
        XCTAssertTrue(result.summary.contains("Samples: 1"))
    }

    func testResultSummaryFailure() {
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 5.0,
            exitCode: 1,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.summary.contains("failed"))
        XCTAssertTrue(result.summary.contains("exit code 1"))
    }

    func testResultSaveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-result-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = TaxTriageConfig(
            samples: [TaxTriageSample(
                sampleId: "SaveTest",
                fastq1: URL(fileURLWithPath: "/data/test.fq.gz"),
                platform: .illumina
            )],
            outputDirectory: tempDir
        )

        let result = TaxTriageResult(
            config: config,
            runtime: 42.0,
            exitCode: 0,
            outputDirectory: tempDir,
            reportFiles: [tempDir.appendingPathComponent("report.txt")],
            allOutputFiles: [tempDir.appendingPathComponent("report.txt")]
        )

        try result.save()

        let loaded = try TaxTriageResult.load(from: tempDir)
        XCTAssertEqual(loaded.exitCode, 0)
        XCTAssertEqual(loaded.runtime, 42.0)
        XCTAssertEqual(loaded.config.samples.count, 1)
        XCTAssertEqual(loaded.config.samples.first?.sampleId, "SaveTest")
        XCTAssertEqual(loaded.reportFiles.count, 1)
    }

    // MARK: - PrerequisiteStatus Tests

    func testPrerequisiteStatusAllSatisfied() {
        let status = PrerequisiteStatus(
            nextflowInstalled: true,
            nextflowVersion: "24.10.0",
            containerRuntimeAvailable: true,
            containerRuntimeName: "Docker"
        )

        XCTAssertTrue(status.allSatisfied)
        XCTAssertTrue(status.summary.contains("installed"))
        XCTAssertTrue(status.summary.contains("24.10.0"))
        XCTAssertTrue(status.summary.contains("Docker"))
        XCTAssertTrue(status.summary.contains("All prerequisites met"))
    }

    func testPrerequisiteStatusMissing() {
        let status = PrerequisiteStatus(
            nextflowInstalled: false,
            nextflowVersion: nil,
            containerRuntimeAvailable: false,
            containerRuntimeName: nil
        )

        XCTAssertFalse(status.allSatisfied)
        XCTAssertTrue(status.summary.contains("NOT INSTALLED"))
        XCTAssertTrue(status.summary.contains("NOT AVAILABLE"))
        XCTAssertTrue(status.summary.contains("MISSING PREREQUISITES"))
    }

    func testPrerequisiteStatusPartial() {
        let status = PrerequisiteStatus(
            nextflowInstalled: true,
            nextflowVersion: "23.04.0",
            containerRuntimeAvailable: false,
            containerRuntimeName: nil
        )

        XCTAssertFalse(status.allSatisfied)
    }

    // MARK: - Config Codable Tests

    func testConfigCodable() throws {
        let sample = TaxTriageSample(
            sampleId: "CodableTest",
            fastq1: URL(fileURLWithPath: "/data/test.fq.gz"),
            fastq2: URL(fileURLWithPath: "/data/test_R2.fq.gz"),
            platform: .pacbio
        )

        let config = TaxTriageConfig(
            samples: [sample],
            platform: .pacbio,
            outputDirectory: URL(fileURLWithPath: "/output"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db"),
            topHitsCount: 15,
            k2Confidence: 0.3,
            rank: "G",
            skipAssembly: false,
            skipKrona: true,
            maxMemory: "32.GB",
            maxCpus: 8,
            profile: "conda",
            revision: "v2.0"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaxTriageConfig.self, from: data)

        XCTAssertEqual(decoded.samples.count, 1)
        XCTAssertEqual(decoded.samples.first?.sampleId, "CodableTest")
        XCTAssertEqual(decoded.platform, .pacbio)
        XCTAssertEqual(decoded.topHitsCount, 15)
        XCTAssertEqual(decoded.k2Confidence, 0.3)
        XCTAssertEqual(decoded.rank, "G")
        XCTAssertFalse(decoded.skipAssembly)
        XCTAssertTrue(decoded.skipKrona)
        XCTAssertEqual(decoded.maxMemory, "32.GB")
        XCTAssertEqual(decoded.maxCpus, 8)
        XCTAssertEqual(decoded.profile, "conda")
        XCTAssertEqual(decoded.revision, "v2.0")
    }

    // MARK: - Error Description Tests

    func testConfigErrorDescriptions() {
        let errors: [TaxTriageConfigError] = [
            .noSamples,
            .emptySampleId,
            .duplicateSampleIds(["S1", "S2"]),
            .inputFileNotFound(
                sampleId: "Test",
                path: URL(fileURLWithPath: "/missing.fq")
            ),
            .databaseNotFound(URL(fileURLWithPath: "/missing/db")),
            .invalidK2Confidence(2.0),
            .invalidTopHitsCount(-1),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
        }
    }

    func testPipelineErrorDescriptions() {
        let errors: [TaxTriagePipelineError] = [
            .nextflowNotInstalled,
            .containerRuntimeNotAvailable,
            .cancelled,
            .prerequisiteFailed(tool: "nextflow", reason: "not found"),
            .pipelineFailed(exitCode: 1, stderr: "error", logFile: nil),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
        }
    }

    // MARK: - Pipeline Argument Building Tests

    func testBuildNextflowArguments() async {
        let pipeline = TaxTriagePipeline()

        let sample = TaxTriageSample(
            sampleId: "Test",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db/k2"),
            topHitsCount: 5,
            k2Confidence: 0.3,
            rank: "G",
            skipAssembly: true,
            skipKrona: true,
            maxMemory: "8.GB",
            maxCpus: 4,
            profile: "docker",
            revision: "dev"
        )

        let args = await pipeline.buildNextflowArguments(config: config)

        // Verify structure
        XCTAssertEqual(args[0], "run")
        XCTAssertEqual(args[1], "jhuapl-bio/taxtriage")
        XCTAssertTrue(args.contains("-r"))
        XCTAssertTrue(args.contains("dev"))
        XCTAssertTrue(args.contains("-profile"))
        XCTAssertTrue(args.contains("docker"))
        XCTAssertTrue(args.contains("--input"))
        XCTAssertTrue(args.contains("--outdir"))
        XCTAssertTrue(args.contains("--db"))
        XCTAssertTrue(args.contains("/db/k2"))
        XCTAssertTrue(args.contains("--top_hits_count"))
        XCTAssertTrue(args.contains("5"))
        XCTAssertTrue(args.contains("--k2_confidence"))
        XCTAssertTrue(args.contains("0.3"))
        XCTAssertTrue(args.contains("--rank"))
        XCTAssertTrue(args.contains("G"))
        XCTAssertTrue(args.contains("--skip_assembly"))
        XCTAssertTrue(args.contains("--skip_krona"))
        XCTAssertTrue(args.contains("--max_memory"))
        XCTAssertTrue(args.contains("--max_cpus"))
        XCTAssertTrue(args.contains("4"))
        XCTAssertTrue(args.contains("-with-trace"))
    }

    func testBuildNextflowLaunchArgumentsPrependRuntimeConfigOverride() async {
        let pipeline = TaxTriagePipeline()

        let sample = TaxTriageSample(
            sampleId: "Test",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output")
        )
        let runtimeConfigURL = URL(fileURLWithPath: "/tmp/lungfish-taxtriage.config")

        let args = await pipeline.buildNextflowLaunchArguments(
            config: config,
            runtimeConfigURL: runtimeConfigURL
        )

        XCTAssertEqual(args.prefix(4), ["-c", runtimeConfigURL.path, "run", "jhuapl-bio/taxtriage"])
    }

    func testBuildNextflowArgumentsWithLocalProjectSourceOmitsRevisionFlag() async {
        let pipeline = TaxTriagePipeline()
        let sample = TaxTriageSample(
            sampleId: "Test",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: URL(fileURLWithPath: "/output"),
            revision: "deadbeef"
        )

        let args = await pipeline.buildNextflowArguments(
            config: config,
            pipelineLaunchTarget: "/tmp/taxtriage-export",
            pipelineRevision: nil
        )

        XCTAssertEqual(args[0], "run")
        XCTAssertEqual(args[1], "/tmp/taxtriage-export")
        XCTAssertFalse(args.contains("-r"))
    }

    func testUsesNextflowCondaOnlyWhenCondaProfileIsSelected() {
        XCTAssertFalse(TaxTriagePipeline.usesNextflowConda(profile: "docker"))
        XCTAssertFalse(TaxTriagePipeline.usesNextflowConda(profile: "podman"))
        XCTAssertTrue(TaxTriagePipeline.usesNextflowConda(profile: "conda"))
        XCTAssertTrue(TaxTriagePipeline.usesNextflowConda(profile: "test,conda"))
    }

    func testBuildLaunchEnvironmentIncludesMambaRootPrefixForCondaProfile() async {
        let pipeline = TaxTriagePipeline()
        let environment = await pipeline.buildLaunchEnvironment(useNextflowConda: true)
        let condaRoot = await CondaManager.shared.rootPrefix

        XCTAssertEqual(environment["MAMBA_ROOT_PREFIX"], condaRoot.path)
        XCTAssertEqual(environment["NXF_CONDA_ENABLED"], "true")
        XCTAssertEqual(
            environment["NXF_CONDA_CACHEDIR"],
            condaRoot.appendingPathComponent("envs").path
        )
        XCTAssertEqual(environment["NXF_HOME"], FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nextflow").path)
        XCTAssertTrue(
            environment["PATH"]?.contains("/opt/homebrew/bin") == true,
            "PATH should retain Docker-friendly system locations"
        )
    }

    func testBuildLaunchEnvironmentOmitsCondaOverridesForDockerProfile() async {
        let pipeline = TaxTriagePipeline()
        let environment = await pipeline.buildLaunchEnvironment(useNextflowConda: false)
        let condaRoot = await CondaManager.shared.rootPrefix

        XCTAssertEqual(environment["MAMBA_ROOT_PREFIX"], condaRoot.path)
        XCTAssertNil(environment["NXF_CONDA_ENABLED"])
        XCTAssertNil(environment["NXF_CONDA_CACHEDIR"])
        XCTAssertEqual(
            environment["NXF_HOME"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nextflow").path
        )
        XCTAssertTrue(
            environment["PATH"]?.contains("/opt/homebrew/bin") == true,
            "PATH should retain Docker-friendly system locations"
        )
    }

    func testPrepareExecutionConfigRedirectsSpaceSensitivePathsIntoSystemTemp() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage space redirect \(UUID().uuidString)", isDirectory: true)
        let projectDir = workspace.appendingPathComponent("Lungfish Docs.lungfish", isDirectory: true)
        let importsDir = projectDir.appendingPathComponent("Imports", isDirectory: true)
        let readsURL = importsDir.appendingPathComponent("sample reads.fastq.gz")
        let outputDir = projectDir.appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("taxtriage-batch-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: importsDir, withIntermediateDirectories: true)
        try Data("ACGT".utf8).write(to: readsURL)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sample = TaxTriageSample(
            sampleId: "SRR14420360",
            fastq1: readsURL,
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: outputDir
        )

        let pipeline = TaxTriagePipeline()
        let execution = try await pipeline.prepareExecutionConfig(for: config)

        XCTAssertNotNil(execution.redirectDirectory)
        XCTAssertFalse(execution.effectiveConfig.outputDirectory.path.contains(" "))
        XCTAssertFalse(execution.effectiveConfig.samplesheetURL.path.contains(" "))
        XCTAssertFalse(execution.effectiveConfig.samples[0].fastq1.path.contains(" "))
        XCTAssertFalse(
            execution.redirectDirectory?.path.contains(" ") ?? true,
            "Redirect directory itself must be space-free for TaxTriage schema validation"
        )
    }

    func testPreparePipelineProjectSourceExportsPinnedRevisionFromDirtyCache() async throws {
        let home = try makeTempDirectory(prefix: "taxtriage-home")
        defer { try? FileManager.default.removeItem(at: home) }

        let (repoURL, revision) = try createDirtyCachedTaxTriageRepository(in: home)

        let pipeline = TaxTriagePipeline(homeDirectoryProvider: { home })
        let prepared = try await pipeline.preparePipelineProjectSource(forRevision: revision)
        defer {
            if let cleanupDirectory = prepared.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
        }

        XCTAssertNotEqual(prepared.launchTarget, TaxTriageConfig.pipelineRepository)
        XCTAssertNil(prepared.revision)

        let exportedProject = URL(fileURLWithPath: prepared.launchTarget)
        let exportedWorkflow = try String(
            contentsOf: exportedProject.appendingPathComponent("workflows/taxtriage.nf"),
            encoding: .utf8
        )
        XCTAssertTrue(exportedWorkflow.contains("if (!ch_assembly_txt) {"))
        XCTAssertFalse(exportedWorkflow.contains("!params.skip_refpull"))

        let cachedWorkflow = try String(
            contentsOf: repoURL.appendingPathComponent("workflows/taxtriage.nf"),
            encoding: .utf8
        )
        XCTAssertTrue(cachedWorkflow.contains("!params.skip_refpull"))
    }

    func testSanitizeIgnoredFailuresSuppressesBenignEmptyReferenceAlignmentWarning() throws {
        let outputDirectory = try makeTempDirectory(prefix: "taxtriage-output")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        try FileManager.default.createDirectory(
            at: outputDirectory.appendingPathComponent("map", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory.appendingPathComponent("combine", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory.appendingPathComponent("download", isDirectory: true),
            withIntermediateDirectories: true
        )

        try "Acc\tAssembly\tOrganism_Name\tDescription\tMapped_Value\n".write(
            to: outputDirectory.appendingPathComponent("map/SRR14420360.merged.taxid.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: outputDirectory.appendingPathComponent("combine/SRR14420360.combined.gcfmap.tsv"))
        try Data().write(to: outputDirectory.appendingPathComponent("download/SRR14420360.dwnld.references.fasta"))

        let failures = [
            TaxTriageIgnoredFailure(
                processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:REPORT:ALIGNMENT_PER_SAMPLE",
                processName: "ALIGNMENT_PER_SAMPLE",
                taskLabel: "SRR14420360",
                sampleID: "SRR14420360",
                exitCode: 1
            ),
        ]

        let sanitized = TaxTriageResult.sanitizeIgnoredFailures(
            failures,
            outputDirectory: outputDirectory
        )

        XCTAssertTrue(sanitized.isEmpty)
    }

    func testSanitizeIgnoredFailuresRetainsNonBenignWarnings() throws {
        let outputDirectory = try makeTempDirectory(prefix: "taxtriage-output")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let failures = [
            TaxTriageIgnoredFailure(
                processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN",
                processName: "MINIMAP2_ALIGN",
                taskLabel: "SRR35517992.SRR35517992.dwnld.references",
                sampleID: "SRR35517992",
                exitCode: 1
            ),
        ]

        let sanitized = TaxTriageResult.sanitizeIgnoredFailures(
            failures,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(sanitized, failures)
    }

    func testCheckPrerequisitesUsesManagedNextflowOutsidePATH() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-managed-nextflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let binDir = tempHome
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("conda", isDirectory: true)
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("nextflow", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let nextflowURL = binDir.appendingPathComponent("nextflow")
        let script = """
        #!/bin/bash
        echo "nextflow version 24.10.0"
        """
        try script.write(to: nextflowURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nextflowURL.path
        )

        let pipeline = TaxTriagePipeline(
            homeDirectoryProvider: { tempHome }
        )
        let status = await pipeline.checkPrerequisites()

        XCTAssertTrue(status.nextflowInstalled)
        XCTAssertEqual(status.nextflowVersion, "24.10.0")
    }

    // MARK: - Multi-Sample Batch Tests (Phase 1)

    func testConfigSourceBundleURLsDefaultNil() {
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        XCTAssertNil(config.sourceBundleURLs)
    }

    func testConfigSourceBundleURLsRoundTrip() throws {
        let bundles = [
            URL(fileURLWithPath: "/data/bundle1.lungfishfastq"),
            URL(fileURLWithPath: "/data/bundle2.lungfishfastq"),
        ]
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceBundleURLs: bundles
        )
        XCTAssertEqual(config.sourceBundleURLs?.count, 2)

        // Codable round-trip
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(TaxTriageConfig.self, from: data)
        XCTAssertEqual(decoded.sourceBundleURLs, bundles)
    }

    func testResultSourceBundleURLsDefaultNil() {
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 10,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        XCTAssertNil(result.sourceBundleURLs)
    }

    func testResultSourceBundleURLsRoundTrip() throws {
        let bundles = [
            URL(fileURLWithPath: "/data/bundle1.lungfishfastq"),
            URL(fileURLWithPath: "/data/bundle2.lungfishfastq"),
        ]
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceBundleURLs: bundles
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 42.5,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/tmp/output"),
            sourceBundleURLs: bundles
        )
        XCTAssertEqual(result.sourceBundleURLs, bundles)

        // Codable round-trip
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(TaxTriageResult.self, from: data)
        XCTAssertEqual(decoded.sourceBundleURLs, bundles)
    }

    func testResultBackwardCompatibilityWithoutSourceBundleURLs() throws {
        // Simulate a legacy JSON without the sourceBundleURLs field
        let config = TaxTriageConfig(
            samples: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 10,
            exitCode: 0,
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        // Encode, then decode — nil fields should survive
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TaxTriageResult.self, from: data)
        XCTAssertNil(decoded.sourceBundleURLs)
    }

    func testResultSaveLoadWithSourceBundleURLs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("taxtriage-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bundles = [
            URL(fileURLWithPath: "/data/bundleA.lungfishfastq"),
            URL(fileURLWithPath: "/data/bundleB.lungfishfastq"),
        ]
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/s1.fq.gz")),
                TaxTriageSample(sampleId: "S2", fastq1: URL(fileURLWithPath: "/data/s2.fq.gz")),
            ],
            outputDirectory: tmpDir,
            sourceBundleURLs: bundles
        )
        var result = TaxTriageResult(
            config: config,
            runtime: 100,
            exitCode: 0,
            outputDirectory: tmpDir,
            sourceBundleURLs: bundles
        )
        try result.save()

        let loaded = try TaxTriageResult.load(from: tmpDir)
        XCTAssertEqual(loaded.sourceBundleURLs, bundles)
        XCTAssertEqual(loaded.config.sourceBundleURLs, bundles)
        XCTAssertEqual(loaded.config.samples.count, 2)
    }
}
