// TaxTriageStandInEngine.swift - The stand-in micromamba and Nextflow that TaxTriage tests run on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-G, decisions T14 and T16 (docs/plans/2026-10-11-phase-2-8.md). No test runs
// the real TaxTriage, which needs Docker, container images and NCBI downloads. This engine takes
// the place of the managed Nextflow behind the pipeline's own launch, `micromamba run -n nextflow
// nextflow ...`, so every step of today's `TaxTriagePipeline` runs around it.
//
// Since Phase 2.9 lane Q9 M1 (decision N11) it is a wrapper of the shared `NextflowStandInEngine`
// with `NextflowStandInWorkflow.taxTriage`, which say what a launch records and writes. The
// wrapper keeps the 2.8 API, with `Behaviour`, `Launch` and `FASTQRecords` as the shared engine's
// types, the fixtures in `<root>/fixtures` under their 2.8 names, and the 2.8 lines of
// `OutputMode.progressLines25` until lane U10 flips `outputMode`.
//
// Run it with the Nextflow profile `profile`. Any profile but docker skips the pipeline's Docker
// check, and a profile other than conda keeps the conda variables out of the launch environment,
// as a docker run does. The tool root and the Nextflow home live in the engine's own `home`, never
// under the real home.

import Foundation
import LungfishCore
import LungfishWorkflow

public struct TaxTriageStandInEngine: Sendable {
    /// What the stand-in Nextflow does once it has recorded a launch.
    public typealias Behaviour = NextflowStandInEngine.Behaviour
    /// One launch of the stand-in Nextflow, read back from its record folder.
    public typealias Launch = NextflowStandInEngine.Launch
    /// The FASTQ records one samplesheet column named.
    public typealias FASTQRecords = NextflowStandInEngine.FASTQRecords

    /// The Nextflow profile a stand-in run uses.
    public static let profile = "local"
    /// The lines the stand-in prints. Lane U10 flips this one line to `.plainLog26` with its reader.
    public static let outputMode: NextflowStandInEngine.OutputMode = .progressLines25

    /// The shared engine, written with TaxTriage's outputs.
    public let engine: NextflowStandInEngine

    public var root: URL { engine.root }
    /// The home the pipeline runs with. It holds the tool root and the Nextflow home.
    public var home: URL { engine.home }
    /// The conda root under `home`, with the stand-in micromamba in `bin/` and the stand-in
    /// Nextflow in `envs/nextflow/bin/`, where the pipeline finds the managed engine.
    public var condaRoot: URL { engine.condaRoot }
    public var launchesDirectory: URL { engine.launchesDirectory }
    public var behaviour: Behaviour { engine.behaviour }
    public var condaManager: CondaManager { engine.condaManager }
    public var micromamba: URL { engine.micromamba }
    public var nextflow: URL { engine.nextflow }
    /// `<root>/fixtures`, where each launch reads `odr.txt`, `gcfmap.tsv` and `top_report.tsv`.
    public var fixturesDirectory: URL { engine.fixturesDirectory }

    /// Writes the engine into `root`, which must be empty or absent.
    public init(root: URL, behaviour: Behaviour = .completes, maximumWait: Duration = .seconds(120)) throws {
        engine = try NextflowStandInEngine(
            root: root,
            workflow: .taxTriage,
            behaviour: behaviour,
            outputMode: Self.outputMode,
            maximumWait: maximumWait
        )
    }

    // MARK: - Running

    /// A pipeline that launches this engine, as the CLI's pipeline factory needs.
    public func makePipeline(processManager: ProcessManager = .shared) -> TaxTriagePipeline {
        let home = home
        return TaxTriagePipeline(
            processManager: processManager,
            condaManager: condaManager,
            homeDirectoryProvider: { home },
            appIdentity: .preview
        )
    }

    /// The pipeline run of `TaxTriageSerialBatchRunner(runPipeline:)` that launches this engine.
    public var pipelineRun: TaxTriageSerialBatchRunner.PipelineRun {
        let engine = self
        return { config, progress in
            try await engine.makePipeline().run(config: config, progress: progress)
        }
    }

    /// A serial batch runner on this engine, as the GUI's runner factory needs.
    public func makeRunner() -> TaxTriageSerialBatchRunner {
        TaxTriageSerialBatchRunner(runPipeline: pipelineRun)
    }

    // MARK: - Control and records

    /// Lets every waiting launch, and every later one, go on as `completes` would.
    public func release() {
        engine.release()
    }

    /// Ends every waiting launch and heartbeat child with 143, then waits until no recorded
    /// process is alive or `timeout` passes. Call it in teardown, so no stand-in outlives its test.
    public func stopLeftoverProcesses(timeout: Duration = .seconds(30)) async {
        await engine.stopLeftoverProcesses(timeout: timeout)
    }

    /// Every launch that has started or exited, in launch order.
    public func launches() throws -> [Launch] {
        try engine.launches()
    }

    /// The launch at `index` once it has started, or nil when `timeout` passes first.
    public func waitForLaunch(_ index: Int = 0, timeout: Duration = .seconds(30)) async -> Launch? {
        await engine.waitForLaunch(index, timeout: timeout)
    }
}
