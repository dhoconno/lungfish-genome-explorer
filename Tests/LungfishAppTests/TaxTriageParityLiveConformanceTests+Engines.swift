// TaxTriageParityLiveConformanceTests+Engines.swift - The real and the stand-in engine of the live TaxTriage parity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32 and the QA ruling on 2.9 O5. `TaxTriageParityEngine` takes its root, profile, database, CPU
// count and wait as parameters, so the live class runs the harness's sides on the managed root with no seam in
// TaxTriageParityHarness. The real engine is the root's Nextflow with the docker profile, the Kraken2 Viral
// database that B60 bound at `databases/kraken2/kraken2-viral`, the wizard's CPU count, the 10 minutes of
// `LiveNextflowRun.runTimeout` for each side and, in this process, the Stable identity whose Nextflow home holds
// the pipeline, as the other live TaxTriage classes run it. The built lungfish-cli of sides C and C' reads the same
// root through `childEnvironment`. The stand-in engine is the stand-in class's, built the same way.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriageParityLiveConformanceTests {
    /// The real engine of `run`. The side that runs in this process resolves its tools from this process's root,
    /// so the root must be the run's (`requireProcessRoot`), and the root must hold the Kraken2 Viral database.
    nonisolated static func liveEngine(_ run: LiveNextflowRun) async throws -> TaxTriageParityEngine {
        try run.requireProcessRoot()
        let database = try await ToolAvailability.requireDatabase(
            {
                let folder = run.root.appendingPathComponent("databases/kraken2/kraken2-viral", isDirectory: true)
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent("hash.k2d").path) ? folder : nil
            },
            name: "Kraken2 Viral in \(run.root.path)"
        )
        return TaxTriageParityEngine(
            root: run.root,
            profile: "docker",
            databasePath: database,
            maxCpus: ProcessInfo.processInfo.activeProcessorCount,
            processWait: .seconds(LiveNextflowRun.runTimeout),
            makePipeline: { TaxTriagePipeline(appIdentity: .stable) },
            standIn: nil,
            cliEnvironment: run.childEnvironment(base: [:])
        )
    }

    /// The stand-in engine of `parityCase` in `caseRoot`, as TaxTriageCLIGUIParityReplayTests builds it, with an empty
    /// Kraken2 database folder beside it and, for a virtual bundle, the managed seqkit linked into its conda root.
    func standInEngine(in caseRoot: URL, for parityCase: TaxTriageParityCase) throws -> TaxTriageParityEngine {
        let database = caseRoot.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let engine = try TaxTriageStandInEngine(
            root: caseRoot.appendingPathComponent("engine", isDirectory: true),
            behaviour: parityCase.behaviour,
            maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        if parityCase.materializesVirtualBundle {
            let managed = ManagedStorageConfigStore().currentCondaRootURL().appendingPathComponent("envs/seqkit", isDirectory: true)
            if FileManager.default.fileExists(atPath: managed.path) {
                try FileManager.default.createSymbolicLink(
                    at: engine.condaRoot.appendingPathComponent("envs/seqkit", isDirectory: true),
                    withDestinationURL: managed
                )
            }
        }
        return .standIn(engine, databasePath: database)
    }

    /// The work folders the launches below `root` name in their `taxtriage-launch-command.txt`, so a teardown and a
    /// container check find a task container of the run whose work folder lies outside `root`.
    nonisolated static func engineWorkFolders(under root: URL) -> [URL] {
        let prefix = "nextflow_work_directory: "
        return TaxTriageParityComparison.Rules.relativeFiles(under: root)
            .filter { ($0 as NSString).lastPathComponent == "taxtriage-launch-command.txt" }
            .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .flatMap { text in
                text.split(separator: "\n")
                    .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
                    .map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
            }
    }
}
