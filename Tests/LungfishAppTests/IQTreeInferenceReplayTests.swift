// IQTreeInferenceReplayTests.swift - The IQ-TREE dialog's recorded command replays the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md, "Tests that enforce it". The test imports
// the known-sarcopterygian alignment once, copies the bundle into two sibling
// roots, builds the argv the GUI runs from the dialog state with
// IQTreeInferenceLaunch.make, runs it on root A, rebases the recorded command
// onto root B and runs it there. The two trees must be the same bytes, and
// each provenance argv must be the command that made it. It runs iqtree3, so
// its class name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

final class IQTreeInferenceReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "iqtree-replay")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    @MainActor
    func testDialogLaunchReplaysToTheSameTree() async throws {
        // The CLI resolves this managed path when no --iqtree-path is given,
        // so the recorded command needs no executable path.
        let managedIQTree = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lungfish/conda/envs/iqtree/bin/iqtree3")
        guard FileManager.default.isExecutableFile(atPath: managedIQTree.path) else {
            throw XCTSkip("iqtree3 is not installed at \(managedIQTree.path)")
        }

        // 1. One imported bundle, copied into two sibling roots.
        let staging = scratch.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedBundle = staging.appendingPathComponent("Sarcopterygians.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: fixtureAlignment(),
            to: stagedBundle,
            options: .init(name: "Sarcopterygians")
        )
        let rootA = scratch.appendingPathComponent("A", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B", isDirectory: true)
        for root in [rootA, rootB] {
            let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent("Phylogenetic Trees", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: stagedBundle, to: project.appendingPathComponent(stagedBundle.lastPathComponent))
        }
        let projectA = rootA.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundleA = projectA.appendingPathComponent(stagedBundle.lastPathComponent, isDirectory: true)
        let outputA = projectA.appendingPathComponent("Phylogenetic Trees/Sarcopterygians.lungfishtree", isDirectory: true)
        let outputB = rootB.appendingPathComponent("Project.lungfish/Phylogenetic Trees/Sarcopterygians.lungfishtree", isDirectory: true)

        // 2. The dialog state on root A, with a fixed seed, one thread,
        // UFBoot and SH-aLRT at 1000, and the zebrafish row as the outgroup.
        let alignment = try XCTUnwrap(IQTreeAlignmentSummary.load(bundleURL: bundleA))
        let state = IQTreeInferenceDialogState(
            request: MultipleSequenceAlignmentTreeInferenceRequest(
                bundleURL: bundleA,
                rows: nil,
                columns: nil,
                suggestedName: "Sarcopterygians.lungfishtree",
                displayName: "Sarcopterygians"
            ),
            projectURL: projectA,
            alignment: alignment
        )
        state.modelChoice = .fixed("JC")
        state.seedText = "12345"
        state.threadsText = "1"
        let zebrafish = try XCTUnwrap(alignment.rows.first { $0.displayName == "Zebrafish_outgroup" })
        state.setOutgroup(rowID: zebrafish.id, selected: true)
        state.prepareForRun()
        let options = try XCTUnwrap(state.pendingOptions, state.validationMessage ?? "no message")
        XCTAssertEqual(options.bootstrap, 1000)
        XCTAssertEqual(options.alrt, 1000)

        let launch = IQTreeInferenceLaunch.make(
            bundleURL: bundleA,
            projectURL: projectA,
            outputURL: outputA,
            outputName: "Sarcopterygians",
            options: options
        )
        let recorded = launch.cliCommand
        XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), launch.arguments)
        try await RecordedCLICommand.runInProcess(recorded)

        // 3. Rebase onto root B and run the same command there.
        let replay = try RecordedCLICommand.rebased(recorded, from: rootA, to: rootB)
        XCTAssertFalse(replay.contains(rootA.path), replay)
        try await RecordedCLICommand.runInProcess(replay)

        // 4. The two trees are the same bytes.
        let treeA = try Data(contentsOf: outputA.appendingPathComponent("tree/primary.nwk"))
        let treeB = try Data(contentsOf: outputB.appendingPathComponent("tree/primary.nwk"))
        XCTAssertFalse(treeA.isEmpty)
        XCTAssertEqual(treeA, treeB)

        // 5. Each provenance argv is the command that made the tree.
        let envelopeA = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: outputA))
        let envelopeB = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: outputB))
        XCTAssertEqual(envelopeA.argv, try AdvancedCommandLineOptions.parse(recorded))
        XCTAssertEqual(envelopeB.argv, try AdvancedCommandLineOptions.parse(replay))
    }

    private func fixtureAlignment() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phylogenetics/known-sarcopterygian/alignment.fasta")
    }
}
