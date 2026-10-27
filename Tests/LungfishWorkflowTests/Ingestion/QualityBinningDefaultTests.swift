// QualityBinningDefaultTests.swift - Imports bin with their platform's default, and older records replay what they ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// BIO-BIN (Phase 3.0 lane BIN), narrowing lane C2-BINNING, with the owner's ruling of 2026-10-27. Every platform bins
/// with `fiveStep` unless the user picks a scheme (None keeps every score), a recipe's declared value applies when no
/// flag is given and a flag wins. A record written before C2-BINNING names no binning for the routes whose default
/// was `none`, and its replay runs the value the record states.
final class QualityBinningDefaultTests: XCTestCase {

    private let project = URL(fileURLWithPath: "/tmp/quality-binning-default.lungfish")

    // MARK: - The import configuration

    func testQualityBinningDefaultFollowsThePlatform() {
        for platform in IngestionPlatform.allCases {
            let config = FASTQBatchImporter.ImportConfig(projectDirectory: project, platform: platform)
            XCTAssertEqual(config.qualityBinning, .fiveStep, "\(platform)")
            XCTAssertEqual(config.commandDefaultQualityBinning, config.qualityBinning, "the record names what ran")
        }
    }

    /// The one function every route reads. The owner's ruling of 2026-10-27 bins every platform, which is the set of
    /// every platform in `IngestionPlatform.platformsBinnedByDefault`, and narrowing it again is that one line.
    func testOneFunctionGivesEveryPlatformsDefault() {
        XCTAssertEqual(IngestionPlatform.platformsBinnedByDefault, Set(LungfishIO.SequencingPlatform.allCases))
        for platform in LungfishIO.SequencingPlatform.allCases {
            XCTAssertEqual(IngestionPlatform.defaultQualityBinning(for: platform), .fiveStep, "\(platform)")
        }
    }


    func testQualityBinningDefaultGivesWayToARecipeAndARecipeToAFlag() {
        let recipe = Recipe(id: "fine", name: "Fine", platforms: [.illumina], qualityBinning: .eightLevel, steps: [])
        let fromRecipe = FASTQBatchImporter.ImportConfig(projectDirectory: project, platform: .illumina, newRecipe: recipe)
        XCTAssertEqual(fromRecipe.qualityBinning, .eightLevel)
        for flag in QualityBinningScheme.allCases {
            let fromFlag = FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina, newRecipe: recipe, qualityBinning: flag
            )
            XCTAssertEqual(fromFlag.qualityBinning, flag)
        }
    }

    // MARK: - A record written before the change

    /// `fastq import-ont`, `fetch sra download --bundle` and `fastq ingest` left the binning flag out of the command
    /// they recorded when the value was `none`, their default then. The replay names the value the record states.
    func testQualityBinningDefaultLeavesAnOlderRecordsReplayAsItRan() throws {
        let ont = step(
            ["lungfish-cli", "fastq", "import-ont", "/data/fastq_pass", "--output", "/data/out"],
            options: ["qualityBinning": .string("none")]
        )
        let sra = step(["lungfish-cli", "fetch", "sra", "download", "SRR1", "--bundle", "--project", "/data/P.lungfish"])
        let ingest = step(["lungfish-cli", "fastq", "ingest", "/data/reads.fastq.gz"], options: ["binning": .string("none")])
        let stated = step(
            ["lungfish-cli", "fastq", "import-ont", "/data/fastq_pass2", "--output", "/data/out2"],
            options: ["qualityBinning": .string("eightLevel")]
        )
        let named = step(["lungfish-cli", "import", "fastq", "/data/r.fastq", "--project", "/data/P.lungfish",
                          "--quality-binning", "illumina4"])

        let shell = ProvenanceExporter(signingProvider: nil).exportShell(run([ont, sra, ingest, stated, named]), allowUnpinned: true)
        let lines = shell.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }

        XCTAssertTrue(lines.contains { $0.contains("import-ont") && $0.contains("fastq_pass ") && $0.contains("--quality-binning none") }, shell)
        XCTAssertTrue(lines.contains { $0.contains("download SRR1") && $0.contains("--quality-binning none") }, shell)
        XCTAssertTrue(lines.contains { $0.contains("fastq ingest") && $0.contains("--binning none") }, shell)
        XCTAssertTrue(lines.contains { $0.contains("fastq_pass2") && $0.contains("--quality-binning eightLevel") }, shell)
        let named2 = lines.filter { $0.contains("import fastq") }
        XCTAssertEqual(named2.count, 1, shell)
        XCTAssertEqual(named2.first?.components(separatedBy: "--quality-binning").count, 2, "a named value stays as it is: \(shell)")
    }

    private func step(_ argv: [String], options: [String: ParameterValue]? = nil) -> StepExecution {
        StepExecution(
            toolName: "lungfish-cli",
            toolVersion: "2026.10.21",
            command: argv,
            durableReplayArgv: argv,
            resolvedOptions: options,
            inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: URL(fileURLWithPath: "/data/out-\(UUID().uuidString)"), role: .output)],
            exitCode: 0,
            wallTime: 1
        )
    }

    private func run(_ steps: [StepExecution]) -> WorkflowRun {
        var run = WorkflowRun(name: "binning replay", appVersion: "lungfish-cli 2026.10.21", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return run
    }
}
