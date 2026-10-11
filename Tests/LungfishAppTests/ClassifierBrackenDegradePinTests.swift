// ClassifierBrackenDegradePinTests.swift - A Bracken profile that degrades ends one way in the GUI and another in the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, step 5 (panel decision T3). The fake Bracken of
// `FakeClassificationCondaFixture` exits 42 after Kraken2 classified the
// reads, so the profile degrades. Today the GUI ends the row Completed with
// Warnings over a `completed` pipeline record, while `conda classify` exits 64
// and writes a `failed` wrapper record (D1 of the 2.7 inventory). Lane A8
// flips the CLI side to exit 0 and `completed` (E4). A Bracken that completes
// is the negative control.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ClassifierBrackenDegradePinTests: XCTestCase {

    func testADegradedProfileCompletesWithWarningsInTheGUIAndFailsTheCLI() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(42))
        defer { fixture.cleanup() }

        let gui = try await guiRun(fixture)
        XCTAssertEqual(gui.result.profileOutcome.state, .degraded)
        XCTAssertTrue(gui.metadata.requiresWarningCompletion, "the row ends Completed with Warnings")
        XCTAssertTrue(gui.metadata.completionDetail.contains("Bracken profiling degraded"), gui.metadata.completionDetail)
        XCTAssertEqual(gui.record.status, .completed)
        XCTAssertEqual(gui.record.exitStatus, 0)
        XCTAssertEqual(gui.record.options.resolvedDefaults["profileState"], .string("degraded"))

        // Lane A8 flips these to exit 0 and `completed` (E4).
        let cli = try await cliRun(fixture)
        XCTAssertEqual(cli.result.profileOutcome.state, .degraded)
        XCTAssertFalse(cli.terminalPolicy.isSuccess)
        XCTAssertEqual(cli.terminalPolicy.exitCode, 64)
        XCTAssertEqual(cli.wrapperEnvelope.exitStatus, 64)
        XCTAssertEqual(cli.wrapperEnvelope.status, .failed)
        XCTAssertEqual(cli.wrapperEnvelope.options.resolvedDefaults["profileState"], .string("degraded"))
    }

    /// The negative control. Both routes end completed and the row ends without warnings.
    func testACompletedProfileCompletesOnBothRoutes() async throws {
        let fixture = try FakeClassificationCondaFixture()
        defer { fixture.cleanup() }

        let gui = try await guiRun(fixture)
        XCTAssertEqual(gui.result.profileOutcome.state, .completed)
        XCTAssertFalse(gui.metadata.requiresWarningCompletion)
        XCTAssertEqual(gui.record.status, .completed)
        XCTAssertEqual(gui.record.options.resolvedDefaults["profileState"], .string("completed"))

        let cli = try await cliRun(fixture)
        XCTAssertTrue(cli.terminalPolicy.isSuccess)
        XCTAssertEqual(cli.terminalPolicy.exitCode, 0)
        XCTAssertEqual(cli.wrapperEnvelope.exitStatus, 0)
        XCTAssertEqual(cli.wrapperEnvelope.status, .completed)
    }

    // MARK: - Routes

    private struct GUIRun {
        let result: ClassificationResult
        /// What the launch completes the row with (`AppDelegate+Classification.swift`, the
        /// `completeWithWarning` branch after `singleResultMetadata`).
        let metadata: ClassificationSingleOutcomeMetadata
        let record: ProvenanceEnvelope
    }

    /// The legacy GUI launch, `resolvedKraken2Config` then the pipeline's profile.
    private func guiRun(_ fixture: FakeClassificationCondaFixture) async throws -> GUIRun {
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let resolved = try await AppDelegate().resolvedKraken2Config(
            config, tempDirectory: fixture.root.appendingPathComponent("gui-scratch", isDirectory: true)
        )
        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: resolved)
        return GUIRun(
            result: result,
            metadata: ClassificationBatchOutcomePolicy.singleResultMetadata(for: result),
            record: try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: config.outputDirectory))
        )
    }

    /// `conda classify` with the command the Operations panel records for the same config.
    private func cliRun(_ fixture: FakeClassificationCondaFixture) async throws -> ClassifierLegacyRuns.CondaClassifyRun {
        var config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        config.outputDirectory = fixture.root.appendingPathComponent("cli-output", isDirectory: true)
        return try await ClassifierLegacyRuns.condaClassify(
            arguments: try ClassifierLegacyRuns.recordedClassifyArguments(for: config),
            databasePath: config.databasePath,
            condaManager: fixture.condaManager
        )
    }
}
