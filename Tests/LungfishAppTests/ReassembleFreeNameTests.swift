// ReassembleFreeNameTests.swift - Reassemble picks a free output name (backlog REASSEMBLE-FREE-NAME)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The walk of 2026-10-22 (obs-23) ran Reassemble twice on one input. The second run named its output
// `HG002.chrM_assembly` again and stopped in under a second on `Output assembly bundle already exists`.
// MAFFT, IQ-TREE and Extract Subtree take the next free name through
// `ViewerViewController.nextAvailableBundleURL`, and Reassemble does the same before it begins its row.
// `lungfish-cli assemble` keeps refusing a bundle that exists, since the command never overwrites
// (ARCH's ruling on obs-23). The route runs a stand-in `lungfish-cli`, so no tool runs.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReassembleFreeNameTests: XCTestCase {
    /// A stand-in run ends in well under a second. The budget leaves room for a loaded Mac.
    private static let standInRun = WaitBudget(name: "stand-in CLI run", duration: .seconds(30))

    /// What one Reassemble run did: its ended row, the argv the stand-in saw and the folder it ran in.
    private struct Run {
        let item: OperationCenter.Item
        let argv: [String]
        let analyses: URL
    }

    /// The walk's case. `HG002.chrM_assembly` and its folder are taken, so the second run writes `-2`.
    func testAReassembleIntoAFolderHoldingItsNameRunsUnderTheNextFreeName() async throws {
        let run = try await reassemble(projectName: "HG002.chrM_assembly", existing: ["HG002.chrM_assembly"])

        let command = try RecordedCLICommand.parse(run.item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.projectName, "HG002.chrM_assembly-2")
        XCTAssertEqual(
            command.outputDir,
            run.analyses.appendingPathComponent("HG002.chrM_assembly-2", isDirectory: true).path,
            "the pipeline's folder takes the free name too"
        )
        XCTAssertEqual(run.item.title, "SPAdes Assembly: HG002.chrM_assembly-2")
        XCTAssertEqual(run.argv, try RecordedCLICommand.arguments(of: run.item.cliCommand), "the route runs what its row records")
    }

    /// A third run finds `-2` taken as well, the way the tree and alignment tools count on.
    func testTheNextFreeNameSkipsANameAnEarlierRunTook() async throws {
        let run = try await reassemble(projectName: "demo", existing: ["demo", "demo-2"])

        let command = try RecordedCLICommand.parse(run.item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.projectName, "demo-3")
        XCTAssertEqual(command.outputDir, run.analyses.appendingPathComponent("demo-3", isDirectory: true).path)
    }

    /// The bundle builder names `Mito Assembly` as `Mito_Assembly.lungfishref`, so that bundle takes the name.
    func testAProjectNameWithSpacesIsTakenByItsUnderscoredBundle() async throws {
        let run = try await reassemble(projectName: "Mito Assembly", existing: ["Mito_Assembly"])

        let command = try RecordedCLICommand.parse(run.item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.projectName, "Mito_Assembly-2")
        XCTAssertEqual(run.item.title, "SPAdes Assembly: Mito_Assembly-2")
    }

    /// A name nothing holds stays as the person typed it, spaces included.
    func testANameNothingHoldsKeepsItsWords() async throws {
        let run = try await reassemble(projectName: "Mito Assembly", existing: [])

        let command = try RecordedCLICommand.parse(run.item.cliCommand, as: AssembleCommand.self)
        XCTAssertEqual(command.projectName, "Mito Assembly")
        XCTAssertEqual(run.item.title, "SPAdes Assembly: Mito Assembly")
    }

    // MARK: - Helpers

    /// Starts the Reassemble run of `projectName` in a project's `Analyses` folder that already holds a
    /// folder and a `.lungfishref` bundle for each of `existing`, on a stand-in `lungfish-cli` that
    /// saves its argv and fails, and returns the row once it ended.
    private func reassemble(projectName: String, existing: [String]) async throws -> Run {
        let root = try TestTempDirectory.make(prefix: "reassemble-free-name")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        for name in existing {
            try FileManager.default.createDirectory(
                at: analyses.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: analyses.appendingPathComponent("\(name).lungfishref", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let launched = root.appendingPathComponent("argv")
        let cli = try standInCLI(in: root, body: """
        printf '%s\\n' "$@" > '\(launched.path)'
        echo '{"error":"the stand-in refused","event":"failed","schemaVersion":2}'
        exit 1
        """)
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [root.appendingPathComponent("reads.fastq")],
            projectName: projectName,
            outputDirectory: analyses,
            threads: 1
        ).normalizedForExecution()

        let opID = try XCTUnwrap(AssemblyRunner.startManagedAssembly(
            request: request,
            routeContext: nil,
            runner: CLIReadsRunner(cliURLOverride: cli)
        ))
        let ended = await waitUntil(budget: Self.standInRun) {
            OperationCenter.shared.items.first { $0.id == opID }?.state == .failed
        }
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == opID })
        OperationCenter.shared.clearItem(id: opID)
        XCTAssertTrue(ended, "the stand-in's failed line ends the row: \(item.state)")
        let argv = try String(contentsOf: launched, encoding: .utf8).split(separator: "\n").map(String.init)
        return Run(item: item, argv: argv, analyses: analyses)
    }

    /// A `lungfish-cli` stand-in in `root` that runs `body` whatever it is given.
    private func standInCLI(in root: URL, body: String) throws -> URL {
        let script = root.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
