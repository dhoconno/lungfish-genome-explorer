// TaxTriagePipelineTests.swift - Tests for TaxTriage pipeline integration
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
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
        def normalize(line):
            return line.rstrip()

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

    private func createDirtyCachedTaxTriageRepositoryMissingRemoteRevision(
        in home: URL
    ) throws -> (repoURL: URL, revision: String) {
        let originURL = home.appendingPathComponent("taxtriage-origin", isDirectory: true)
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originURL.appendingPathComponent("workflows", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originURL.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)

        try """
        workflow TAXTRIAGE {
            INITIAL()
        }
        """.write(
            to: originURL.appendingPathComponent("workflows/taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        def get_url(utl, id):
            bb = os.path.basename(utl)
            return utl+"/"+bb+"_genomic.fna.gz"
        """.write(
            to: originURL.appendingPathComponent("bin/download_fastas.py"),
            atomically: true,
            encoding: .utf8
        )

        try runCommand("/usr/bin/git", ["init", "--initial-branch=main"], workingDirectory: originURL)
        try runCommand("/usr/bin/git", ["config", "user.email", "codex@example.com"], workingDirectory: originURL)
        try runCommand("/usr/bin/git", ["config", "user.name", "Codex"], workingDirectory: originURL)
        try runCommand("/usr/bin/git", ["add", "."], workingDirectory: originURL)
        try runCommand("/usr/bin/git", ["commit", "-m", "Initial"], workingDirectory: originURL)

        let repoURL = home
            .appendingPathComponent(".nextflow", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("jhuapl-bio", isDirectory: true)
            .appendingPathComponent("taxtriage", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runCommand("/usr/bin/git", ["clone", originURL.path, repoURL.path])

        try """
        workflow TAXTRIAGE {
            REQUESTED_REMOTE_REVISION()
        }
        """.write(
            to: originURL.appendingPathComponent("workflows/taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )
        try runCommand("/usr/bin/git", ["add", "."], workingDirectory: originURL)
        try runCommand("/usr/bin/git", ["commit", "-m", "Requested revision"], workingDirectory: originURL)
        let requestedRevision = try runCommand("/usr/bin/git", ["rev-parse", "HEAD"], workingDirectory: originURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try """
        workflow TAXTRIAGE {
            DIRTY_LOCAL_CACHE()
        }
        """.write(
            to: repoURL.appendingPathComponent("workflows/taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )

        return (repoURL, requestedRevision)
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
        XCTAssertTrue(result.summary.contains("Ignored task failures: 1"))
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
        XCTAssertNil(config.revision, "nil runs the commit the lock pins, with no fallback branch (N4)")
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

    func testPipelineRepository() throws {
        XCTAssertEqual(try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin().repository, "jhuapl-bio/taxtriage")
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

    // TaxTriage's own options, the launch's pipeline arguments. The launch target, -r, -profile,
    // --input and --outdir are the descriptor's (NextflowLaunchArgumentsTests).
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

        let args = config.nextflowPipelineArguments()

        XCTAssertTrue(args.contains("--skip_assembly"))
        XCTAssertFalse(args.contains("--skip_krona"))
        // Today's real launch passes no --skip_plots. Only the deleted, uncalled builder added it
        // (A16 M2 review ruling), and adding it needs a panel vote, a Moved out row for 2.10.
        XCTAssertFalse(args.contains("--skip_plots"))
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

        let args = config.nextflowPipelineArguments()

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

        let args = config.nextflowPipelineArguments()

        XCTAssertFalse(args.contains("--skip_assembly"))
        XCTAssertTrue(args.contains("--skip_krona"))
    }

    // The launch passes no --classifiers whatever the config holds, so TaxTriage runs its own
    // default, Kraken 2, and the record files `classifiers` as a resolved default (BIO T1, R5).
    // Only the deleted, uncalled builder passed the flag.
    func testNextflowArgumentsNeverPassClassifiers() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fq.gz"),
            platform: .illumina
        )
        for classifiers in [["kraken2", "diamond"], ["kraken2"], []] {
            let config = TaxTriageConfig(
                samples: [sample],
                outputDirectory: URL(fileURLWithPath: "/output"),
                classifiers: classifiers
            )
            XCTAssertFalse(config.nextflowPipelineArguments().contains("--classifiers"), "\(classifiers)")
        }
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
        XCTAssertTrue(status.summary.contains("Nextflow: not installed"), status.summary)
        XCTAssertTrue(status.summary.contains("Container runtime: not available"), status.summary)
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

    func testBuildNextflowArguments() throws {
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

        let args = pipeline.buildNextflowArguments(config: config, pin: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())

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

    func testBuildNextflowLaunchArgumentsPrependRuntimeConfigOverride() throws {
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

        let args = pipeline.buildNextflowLaunchArguments(
            config: config,
            runtimeConfigURL: runtimeConfigURL,
            pin: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        )

        XCTAssertEqual(args.prefix(4), ["-c", runtimeConfigURL.path, "run", "jhuapl-bio/taxtriage"])
    }

    func testBuildNextflowArgumentsWithLocalProjectSourceOmitsRevisionFlag() {
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

        let args = pipeline.buildNextflowArguments(
            config: config,
            pipelineLaunchTarget: "/tmp/taxtriage-export",
            pipelineRevision: nil
        )

        XCTAssertEqual(args[0], "run")
        XCTAssertEqual(args[1], "/tmp/taxtriage-export")
        XCTAssertFalse(args.contains("-r"))
    }

    func testBuildLaunchMetadataUsesDurableWorkflowSnapshotAndReleaseLabel() throws {
        let pipeline = TaxTriagePipeline()
        let outputDirectory = try makeTempDirectory(prefix: "taxtriage-launch-metadata")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let sample = TaxTriageSample(
            sampleId: "Test",
            fastq1: URL(fileURLWithPath: "/data/reads.fq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            outputDirectory: outputDirectory,
            revision: "8fd1fb5bb236e4978f5734e522e6b89e0640a2a9"
        )
        let snapshotURL = outputDirectory
            .appendingPathComponent("workflow-source", isDirectory: true)
            .appendingPathComponent("taxtriage", isDirectory: true)
        let runtimeConfigURL = outputDirectory.appendingPathComponent("lungfish.nextflow.config")

        let args = pipeline.buildNextflowLaunchArguments(
            config: config,
            runtimeConfigURL: runtimeConfigURL,
            pipelineLaunchTarget: snapshotURL.path,
            pipelineRevision: nil
        )
        let metadata = pipeline.buildLaunchMetadata(
            requestedConfig: config,
            effectiveConfig: config,
            nextflowArguments: args,
            launcherPath: "/usr/bin/nextflow",
            launcherArguments: args,
            workingDirectory: outputDirectory,
            environment: ["NXF_HOME": "/tmp/nxf"],
            workflowRepository: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin().repository,
            workflowRevision: "8fd1fb5bb236e4978f5734e522e6b89e0640a2a9",
            workflowGithubReleaseVersion: try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin().releaseVersion,
            workflowSnapshotURL: snapshotURL
        )

        XCTAssertTrue(args.contains(snapshotURL.path))
        XCTAssertFalse(args.contains("-r"))
        XCTAssertTrue(metadata.contains("workflow_repository: jhuapl-bio/taxtriage"))
        XCTAssertTrue(metadata.contains("workflow_github_release_version: v3.3.8"))
        XCTAssertTrue(metadata.contains("workflow_revision: 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9"))
        XCTAssertTrue(metadata.contains("workflow_snapshot_directory: \(snapshotURL.path)"))
        XCTAssertTrue(metadata.contains("nextflow_command: nextflow -c \(runtimeConfigURL.path) run \(snapshotURL.path)"))
    }

    func testBuildLaunchScriptIncludesWorkflowVersionComments() {
        let pipeline = TaxTriagePipeline()
        let directory = URL(fileURLWithPath: "/tmp/taxtriage-output")
        let metadata = """
        # TaxTriage launch metadata
        workflow_github_release_version: v3.3.6
        workflow_revision: 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9
        workflow_snapshot_directory: /tmp/taxtriage-output/workflow-source/taxtriage
        launcher_command: /usr/bin/nextflow run /tmp/taxtriage-output/workflow-source/taxtriage
        """

        let script = pipeline.buildLaunchScript(metadata: metadata, directory: directory)

        XCTAssertTrue(script.contains("# workflow_github_release_version: v3.3.6"))
        XCTAssertTrue(script.contains("# workflow_revision: 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9"))
        XCTAssertTrue(script.contains("# workflow_snapshot_directory: /tmp/taxtriage-output/workflow-source/taxtriage"))
        XCTAssertTrue(script.contains("cd /tmp/taxtriage-output"))
        XCTAssertTrue(script.contains("/usr/bin/nextflow run /tmp/taxtriage-output/workflow-source/taxtriage"))
    }

    func testBuildLaunchScriptPrefersReproducibleGithubCommandWhenSnapshotWasUsed() {
        let pipeline = TaxTriagePipeline()
        let directory = URL(fileURLWithPath: "/tmp/taxtriage-output")
        let metadata = """
        # TaxTriage launch metadata
        workflow_repository: jhuapl-bio/taxtriage
        workflow_github_release_version: v3.3.6
        workflow_revision: 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9
        workflow_snapshot_directory: /tmp/taxtriage-output/workflow-source/taxtriage
        launcher_command: /usr/bin/nextflow run /tmp/taxtriage-output/workflow-source/taxtriage
        reproducible_launcher_command: /usr/bin/nextflow run jhuapl-bio/taxtriage -r 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9
        """

        let script = pipeline.buildLaunchScript(metadata: metadata, directory: directory)

        XCTAssertTrue(script.contains("# actual_launcher_command: /usr/bin/nextflow run /tmp/taxtriage-output/workflow-source/taxtriage"))
        XCTAssertTrue(script.contains("/usr/bin/nextflow run jhuapl-bio/taxtriage -r 8fd1fb5bb236e4978f5734e522e6b89e0640a2a9"))
        XCTAssertFalse(script.contains("\n/usr/bin/nextflow run /tmp/taxtriage-output/workflow-source/taxtriage\n"))
    }

    func testTaxTriageGithubReleaseLabelIsOnlyUsedForKnownReleaseRevisions() throws {
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: pin.revision, pin: pin), pin.releaseVersion)
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: pin.releaseVersion, pin: pin), pin.releaseVersion)
        XCTAssertNil(TaxTriageConfig.githubReleaseVersion(for: "8fd1fb5bb236e4978f5734e522e6b89e0640a2aa", pin: pin))
        XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: "v3.3.9", pin: nil), "v3.3.9")
        XCTAssertNil(TaxTriageConfig.githubReleaseVersion(for: pin.revision, pin: nil), "with no pin only a v tag names a release")
    }

    /// Capture on 9.68: `taxtriage run --output <project>/Analyses/taxtriage-cornea`
    /// showed in the sidebar as a plain folder.
    func testRunWrittenIntoAnalysesIsMarkedAsATaxTriageAnalysis() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageAnalysisMarker-\(UUID().uuidString).lungfish", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        let output = project.appendingPathComponent("Analyses/taxtriage-cornea", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertNil(AnalysesFolder.analysisInfo(for: output))

        TaxTriagePipeline.markAsProjectAnalysisIfNeeded(output)
        XCTAssertEqual(AnalysesFolder.analysisInfo(for: output)?.tool, "taxtriage")

        let elsewhere = project.appendingPathComponent("Exports/taxtriage-cornea", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        TaxTriagePipeline.markAsProjectAnalysisIfNeeded(elsewhere)
        XCTAssertNil(AnalysesFolder.readAnalysisMetadata(from: elsewhere))
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
        let condaRoot = CondaManager.shared.rootPrefix

        XCTAssertEqual(environment["MAMBA_ROOT_PREFIX"], condaRoot.path)
        XCTAssertEqual(environment["NXF_CONDA_ENABLED"], "true")
        XCTAssertEqual(
            environment["NXF_CONDA_CACHEDIR"],
            condaRoot.appendingPathComponent("envs").path
        )
        XCTAssertEqual(environment["NXF_HOME"], FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nextflow").path)
        let pathComponents = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(pathComponents.contains(condaRoot.appendingPathComponent("bin").path))
        XCTAssertTrue(
            pathComponents.contains("/usr/local/bin"),
            "PATH should include Docker-friendly system locations without depending on host-specific Homebrew paths"
        )
    }

    func testBuildLaunchEnvironmentOmitsCondaOverridesForDockerProfile() async {
        let pipeline = TaxTriagePipeline()
        let environment = await pipeline.buildLaunchEnvironment(useNextflowConda: false)
        let condaRoot = CondaManager.shared.rootPrefix

        XCTAssertEqual(environment["MAMBA_ROOT_PREFIX"], condaRoot.path)
        XCTAssertNil(environment["NXF_CONDA_ENABLED"])
        XCTAssertNil(environment["NXF_CONDA_CACHEDIR"])
        XCTAssertEqual(
            environment["NXF_HOME"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nextflow").path
        )
        let pathComponents = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(pathComponents.contains(condaRoot.appendingPathComponent("bin").path))
        XCTAssertTrue(
            pathComponents.contains("/usr/local/bin"),
            "PATH should include Docker-friendly system locations without depending on host-specific Homebrew paths"
        )
    }

    func testBuildLaunchEnvironmentIsolatesDebugNextflowHome() async {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let debugPipeline = TaxTriagePipeline(
            homeDirectoryProvider: { home },
            appIdentity: .debug
        )
        let previewPipeline = TaxTriagePipeline(
            homeDirectoryProvider: { home },
            appIdentity: .preview
        )

        let debugEnvironment = await debugPipeline.buildLaunchEnvironment(useNextflowConda: false)
        let previewEnvironment = await previewPipeline.buildLaunchEnvironment(useNextflowConda: false)
        let debugRepository = await debugPipeline.cachedTaxTriageRepositoryURL()
        let previewRepository = await previewPipeline.cachedTaxTriageRepositoryURL()

        XCTAssertEqual(
            debugEnvironment["NXF_HOME"],
            "/Users/example/Library/Caches/com.lungfish.debug/nextflow"
        )
        XCTAssertEqual(
            previewEnvironment["NXF_HOME"],
            "/Users/example/.nextflow"
        )
        XCTAssertEqual(
            debugRepository.path,
            "/Users/example/Library/Caches/com.lungfish.debug/nextflow/assets/jhuapl-bio/taxtriage"
        )
        XCTAssertEqual(
            previewRepository.path,
            "/Users/example/.nextflow/assets/jhuapl-bio/taxtriage"
        )
    }

    func testPrepareExecutionConfigRedirectsSpaceSensitivePathsIntoSystemTemp() throws {
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
        let execution = try pipeline.prepareExecutionConfig(for: config)

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
        let prepared = try await pipeline.preparePipelineProjectSource(forRevision: revision, repository: "jhuapl-bio/taxtriage")
        defer {
            if let cleanupDirectory = prepared.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
        }

        XCTAssertNotEqual(prepared.launchTarget, "jhuapl-bio/taxtriage")
        XCTAssertNil(prepared.revision)
        XCTAssertEqual(prepared.pipelineSource, .snapshot, "B11 M2 (T6), the step records the snapshot it launched")

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

        let exportedDownloadScript = try String(
            contentsOf: exportedProject.appendingPathComponent("bin/download_fastas.py"),
            encoding: .utf8
        )
        // Flipped by B11 M2 (T6, F3). LGE patches no pipeline code, so the snapshot holds the commit's bytes.
        let committed = try runCommand("/usr/bin/git", ["show", "\(revision):bin/download_fastas.py"], workingDirectory: repoURL)
        XCTAssertEqual(exportedDownloadScript, committed, "the commit's script, not the cache's edit and no patch")
    }

    func testPreparePipelineProjectSourceFetchesMissingRevisionFromDirtyCacheOrigin() async throws {
        let home = try makeTempDirectory(prefix: "taxtriage-home")
        defer { try? FileManager.default.removeItem(at: home) }

        let (repoURL, revision) = try createDirtyCachedTaxTriageRepositoryMissingRemoteRevision(in: home)

        let pipeline = TaxTriagePipeline(homeDirectoryProvider: { home })
        let prepared = try await pipeline.preparePipelineProjectSource(forRevision: revision, repository: "jhuapl-bio/taxtriage")
        defer {
            if let cleanupDirectory = prepared.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
        }

        XCTAssertNotEqual(prepared.launchTarget, "jhuapl-bio/taxtriage")
        XCTAssertNil(prepared.revision)
        XCTAssertEqual(prepared.pipelineSource, .snapshot, "B11 M2 (T6), the step records the snapshot it launched")

        let exportedProject = URL(fileURLWithPath: prepared.launchTarget)
        let exportedWorkflow = try String(
            contentsOf: exportedProject.appendingPathComponent("workflows/taxtriage.nf"),
            encoding: .utf8
        )
        XCTAssertTrue(exportedWorkflow.contains("REQUESTED_REMOTE_REVISION()"))
        XCTAssertFalse(exportedWorkflow.contains("DIRTY_LOCAL_CACHE()"))

        let cachedWorkflow = try String(
            contentsOf: repoURL.appendingPathComponent("workflows/taxtriage.nf"),
            encoding: .utf8
        )
        XCTAssertTrue(cachedWorkflow.contains("DIRTY_LOCAL_CACHE()"))
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
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: PrerequisiteProbeStub.dockerRunning
        )
        let status = await pipeline.checkPrerequisites()

        XCTAssertTrue(status.nextflowInstalled)
        XCTAssertEqual(status.nextflowVersion, "24.10.0")
    }

    // MARK: - Container runtime verdict follows the shared Docker probe

    /// The CLI check, the wizard row, and the run preflight all read
    /// `PipelineContainerRuntimeStatus.check` through the injected probe, so
    /// an Apple Containerization runtime that is ready must not make the
    /// prerequisite pass while the Docker daemon is down.
    func testCheckPrerequisitesReportsDockerOnlyAndIgnoresAppleRuntime() async throws {
        let tempHome = try makeTempDirectory(prefix: "taxtriage-probe-home")
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let daemonDownAppleReady = PrerequisiteProbeStub(
            dockerPath: "/usr/local/bin/docker",
            daemon: DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: "Cannot connect to the Docker daemon"
            ),
            apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
        )
        let down = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: daemonDownAppleReady
        ).checkPrerequisites()
        XCTAssertFalse(down.containerRuntimeAvailable)
        XCTAssertNil(down.containerRuntimeName)
        XCTAssertEqual(down.containerRuntimeDetail, "Docker Desktop is not running")
        XCTAssertFalse(down.allSatisfied)
        XCTAssertEqual(daemonDownAppleReady.recorder.appleCallCount, 0, "Apple runtime must not be consulted")
        XCTAssertTrue(down.summary.contains("Container runtime: not available (Docker Desktop is not running)"))

        let noDocker = PrerequisiteProbeStub(
            dockerPath: nil,
            daemon: DockerDaemonProbe(reachable: false, clientVersion: nil, serverVersion: nil, detail: nil),
            apple: AppleContainerProbe(frameworkAvailable: true, runtimeReady: true, detail: nil)
        )
        let missing = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: noDocker
        ).checkPrerequisites()
        XCTAssertFalse(missing.containerRuntimeAvailable)
        XCTAssertEqual(missing.containerRuntimeDetail, "Docker Desktop is not installed")
        XCTAssertTrue(noDocker.recorder.recordedTimeouts.isEmpty, "no CLI means nothing to run")

        let running = await TaxTriagePipeline(
            homeDirectoryProvider: { tempHome },
            appIdentity: .preview,
            containerRuntimeProbe: PrerequisiteProbeStub.dockerRunning
        ).checkPrerequisites()
        XCTAssertTrue(running.containerRuntimeAvailable)
        XCTAssertEqual(running.containerRuntimeName, PipelineContainerRuntimeStatus.runtimeName)
        XCTAssertNil(running.containerRuntimeDetail)
        XCTAssertTrue(running.summary.contains("Container runtime: Docker Desktop"))
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
        let result = TaxTriageResult(
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

    // MARK: - The batch result (2.13 K1b)

    // These three cases ran `TaxTriageSerialBatchRunner`, which no route ran after 2.12 K1. They run the batch result
    // of `TaxTriageAnalysisRunTool` now, the one a TaxTriage batch publishes at its root, from one unit report per
    // sample. The launch order, the sample folders and the root record are the plan's and the executor's, pinned by
    // `TaxTriageAnalysisRunToolPlanTests` and `TaxTriageAnalysisRunToolReplayTests`.

    func testABatchResultHoldsEverySampleInOrderAndIsPublishedAtTheRoot() throws {
        let tmpDir = try makeTempDirectory(prefix: "taxtriage-serial")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sourceBundles = [
            URL(fileURLWithPath: "/data/Alpha.lungfishfastq"),
            URL(fileURLWithPath: "/data/Beta.lungfishfastq"),
        ]
        let units = try ["Alpha", "Beta"].enumerated().map { index, id in
            try batchUnit(index, id, root: tmpDir, files: ["top/\(id).top_report.tsv"], bundle: sourceBundles[index])
        }

        let result = try XCTUnwrap(TaxTriageAnalysisRunTool.publishAggregateResult(of: units, planned: nil, root: tmpDir))

        XCTAssertEqual(result.outputDirectory.standardizedFileURL, tmpDir.standardizedFileURL)
        XCTAssertEqual(result.config.samples.map(\.sampleId), ["Alpha", "Beta"])
        XCTAssertEqual(result.reportFiles.count, 2)
        XCTAssertEqual(result.sourceBundleURLs, sourceBundles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("taxtriage-result.json").path))
    }

    func testABatchResultExcludesWorkflowSourceFromItsOutputs() throws {
        let tmpDir = try makeTempDirectory(prefix: "taxtriage-serial-source-filter")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let units = try ["SampleA", "SampleB"].enumerated().map { index, id in
            try batchUnit(index, id, root: tmpDir, files: [
                "report/\(id).organisms.report.txt", "workflow-source/taxtriage/assets/large-reference.tsv",
            ])
        }

        let result = try XCTUnwrap(TaxTriageAnalysisRunTool.aggregateResult(of: units, planned: nil, root: tmpDir))

        XCTAssertEqual(result.reportFiles.count, 2)
        XCTAssertFalse(result.allOutputFiles.contains { $0.path.contains("/workflow-source/") })
    }

    func testABatchResultListsAFailedSampleBetweenCompletedOnes() throws {
        let tmpDir = try makeTempDirectory(prefix: "taxtriage-serial-failure")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let units = [
            try batchUnit(0, "GoodA", root: tmpDir, files: ["top/GoodA.top_report.tsv"]),
            AnalysisUnitReport<TaxTriageUnitResult>(
                index: 1, label: "Bad", sampleName: "Bad", directory: tmpDir.appendingPathComponent("Bad", isDirectory: true),
                outcome: .failed(reason: "synthetic sample failure")
            ),
            try batchUnit(2, "GoodB", root: tmpDir, files: ["top/GoodB.top_report.tsv"]),
        ]

        let result = try XCTUnwrap(TaxTriageAnalysisRunTool.aggregateResult(of: units, planned: nil, root: tmpDir))

        XCTAssertEqual(result.reportFiles.count, 2)
        XCTAssertEqual(result.sampleFailures.map(\.sampleID), ["Bad"])
        XCTAssertEqual(result.sampleFailures.first?.errorDescription, "synthetic sample failure")
        XCTAssertTrue(result.hasSampleFailures)
    }

    /// A completed unit of the batch at `root`, one sample in its own folder, whose result names `files` (relative to
    /// that folder, the first its report), written there.
    private func batchUnit(
        _ index: Int,
        _ id: String,
        root: URL,
        files: [String],
        bundle: URL? = nil
    ) throws -> AnalysisUnitReport<TaxTriageUnitResult> {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let urls = try files.map { relative -> URL in
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(id)\t\(relative)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: id, fastq1: URL(fileURLWithPath: "/data/\(id).fastq.gz"))],
            outputDirectory: folder,
            sourceBundleURLs: bundle.map { [$0] }
        )
        let result = TaxTriageResult(
            config: config, runtime: 1.0, exitCode: 0, outputDirectory: folder,
            reportFiles: Array(urls.prefix(1)), allOutputFiles: urls, sourceBundleURLs: bundle.map { [$0] }
        )
        return AnalysisUnitReport(
            index: index, label: id, sampleName: id, directory: folder, outcome: .completed(TaxTriageUnitResult(result: result))
        )
    }
}

// MARK: - Container runtime probe stub

/// A probe whose answers are fixed by the test, so `checkPrerequisites`
/// never runs `docker` or the Apple runtime.
struct PrerequisiteProbeStub: ContainerRuntimeProbing {
    var dockerPath: String?
    var daemon: DockerDaemonProbe
    var apple: AppleContainerProbe
    let recorder = PrerequisiteProbeRecorder()

    static let dockerRunning = PrerequisiteProbeStub(
        dockerPath: "/usr/local/bin/docker",
        daemon: DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.3.2", detail: nil),
        apple: AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    )

    func dockerCLIPath() -> String? { dockerPath }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        recorder.record(timeout)
        return daemon
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        recorder.appleConsulted()
        return apple
    }
}

final class PrerequisiteProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []
    private var appleCalls = 0

    func record(_ timeout: TimeInterval) {
        lock.lock(); timeouts.append(timeout); lock.unlock()
    }

    func appleConsulted() {
        lock.lock(); appleCalls += 1; lock.unlock()
    }

    var recordedTimeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }; return timeouts
    }

    var appleCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return appleCalls
    }
}
