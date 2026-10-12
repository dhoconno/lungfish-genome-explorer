// NextflowLaunchArgumentsTests.swift - TaxTriage's launch arguments from its descriptor against today's pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (API brief section 3, ARCH ruling 2 of the M1 review). The descriptor builds a launch's
// arguments from a launch request, and TaxTriage's must equal, byte for byte, what
// `TaxTriagePipeline.buildNextflowLaunchArguments` writes today for the same configuration. The parity test runs
// the pinned repository with `-r`, a user's revision and LGE's snapshot folder without `-r`, each with and without
// a work folder, under the profiles nil (the descriptor's `docker`), `conda` and `local`. Pure, so it runs in the
// unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class NextflowLaunchArgumentsTests: XCTestCase {
    private let descriptor = NextflowWorkflowDescriptor.taxTriage
    private let runtimeConfig = URL(fileURLWithPath: "/private/tmp/lungfish-args/lungfish.nextflow.config")
    private let snapshot = URL(
        fileURLWithPath: "/Volumes/Lab Drive/proj.lungfish/Analyses/taxtriage/workflow-source/taxtriage",
        isDirectory: true)
    private let work = URL(fileURLWithPath: "/private/tmp/taxtriage-run-abc/work", isDirectory: true)
    private let sample = TaxTriageSample(
        sampleId: "S1",
        fastq1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"),
        fastq2: URL(fileURLWithPath: "/data/S1_R2.fastq.gz"))

    /// Two configurations that between them take every branch of TaxTriage's options. The second sets its own
    /// `--remove_taxids` among the extra arguments, so the configured list is left out.
    private func configurations(profile: String) -> [TaxTriageConfig] {
        [
            TaxTriageConfig(
                samples: [sample],
                outputDirectory: URL(
                    fileURLWithPath: "/Volumes/Lab Drive/proj.lungfish/Analyses/taxtriage", isDirectory: true),
                kraken2DatabasePath: URL(fileURLWithPath: "/db/kraken2/standard-8", isDirectory: true),
                skipKrona: true,
                profile: profile,
                extraArguments: ["--min_reads", "5"],
                removeTaxids: "9606"),
            TaxTriageConfig(
                samples: [sample],
                platform: .oxford,
                outputDirectory: URL(fileURLWithPath: "/output", isDirectory: true),
                topHitsCount: 25,
                k2Confidence: 0.05,
                rank: "G",
                skipAssembly: false,
                maxMemory: "8.GB",
                maxCpus: 4,
                profile: profile,
                extraArguments: ["--remove_taxids", "9606,10090"],
                removeTaxids: "9606"),
        ]
    }

    func testTaxTriagesArgumentsAreThePipelinesBytesForEveryTargetProfileAndWorkFolder() throws {
        let pipeline = TaxTriagePipeline()
        let pin = try descriptor.resolveBundledPin()
        let userPin = NextflowPipelinePin(
            pipelineID: pin.pipelineID, repository: pin.repository, revision: "v3.3.7", releaseVersion: "v3.3.7")
        // Each target with the launch target and revision today's pipeline is given for it.
        let targets: [(target: NextflowLaunchTarget, launchTarget: String, revision: String?)] = [
            (.pinned(pin), pin.repository, pin.revision),
            (.pinned(userPin), pin.repository, "v3.3.7"),
            (.snapshot(snapshot), snapshot.path, nil),
        ]

        var cases = 0
        for profile in [nil, "conda", "local"] as [String?] {
            for config in configurations(profile: profile ?? "docker") {
                for (target, launchTarget, revision) in targets {
                    for workDirectory in [nil, work] as [URL?] {
                        let today = pipeline.buildNextflowLaunchArguments(
                            config: config,
                            runtimeConfigURL: runtimeConfig,
                            pipelineLaunchTarget: launchTarget,
                            pipelineRevision: revision,
                            workDirectory: workDirectory)
                        let launch = NextflowLaunchRequest(
                            configFiles: [runtimeConfig],
                            target: target,
                            samplesheet: config.samplesheetURL,
                            outputDirectory: config.outputDirectory,
                            workDirectory: workDirectory,
                            profile: profile,
                            pipelineArguments: config.nextflowPipelineArguments())
                        XCTAssertEqual(
                            descriptor.nextflowArguments(for: launch), today,
                            "profile \(profile ?? "nil"), \(target), work \(workDirectory?.path ?? "none")")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 36)
    }

    func testTheFrameWritesConfigFilesFirstThenTodaysOrder() throws {
        let pin = try descriptor.resolveBundledPin()
        let output = URL(fileURLWithPath: "/out", isDirectory: true)
        let extraConfig = URL(fileURLWithPath: "/private/tmp/lungfish-args/limits.config")
        var launch = NextflowLaunchRequest(
            configFiles: [runtimeConfig, extraConfig],
            target: .pinned(pin),
            samplesheet: output.appendingPathComponent("samplesheet.csv"),
            outputDirectory: output,
            workDirectory: work,
            pipelineArguments: ["--rank", "S"])
        XCTAssertEqual(descriptor.nextflowArguments(for: launch), [
            "-c", runtimeConfig.path, "-c", extraConfig.path,
            "run", pin.repository, "-r", pin.revision,
            "-profile", "docker",
            "--input", "/out/samplesheet.csv",
            "--outdir", "/out",
            "-with-trace", "/out/trace.txt",
            "-w", work.path,
            "--rank", "S",
        ])

        // A resumed launch passes -resume right after the target, as nf-core's request does. TaxTriage sets none.
        launch.resume = true
        launch.configFiles = []
        launch.workDirectory = nil
        XCTAssertEqual(Array(descriptor.nextflowArguments(for: launch).prefix(5)), [
            "run", pin.repository, "-r", pin.revision, "-resume",
        ])
    }

    func testTaxTriagesOptionsFollowThePipelinesOrderFromTheDatabaseToTheExtraArguments() {
        let first = configurations(profile: "docker")[0]
        XCTAssertEqual(first.nextflowPipelineArguments(), [
            "--db", "/db/kraken2/standard-8",
            "--top_hits_count", "10",
            "--k2_confidence", "0.2",
            "--rank", "S",
            "--skip_assembly",
            "--skip_krona",
            "--remove_taxids", "9606",
            "--max_memory", "16.GB",
            "--max_cpus", String(ProcessInfo.processInfo.activeProcessorCount),
            "--min_reads", "5",
        ])

        // No database, assembly on, Krona on, and the extra arguments' own --remove_taxids instead of the setting.
        let second = configurations(profile: "docker")[1]
        XCTAssertEqual(second.nextflowPipelineArguments(), [
            "--top_hits_count", "25",
            "--k2_confidence", "0.05",
            "--rank", "G",
            "--max_memory", "8.GB",
            "--max_cpus", "4",
            "--remove_taxids", "9606,10090",
        ])
    }
}
