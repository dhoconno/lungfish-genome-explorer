// ClassifierBrackenDegradePinTests.swift - A Bracken profile that degrades ends one way in the GUI and another in the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, step 5 (panel decision T3). The fake Bracken of
// `FakeClassificationCondaFixture` exits 42 after Kraken2 classified the
// reads, so the profile degrades. The GUI ends the row Completed with
// Warnings over a `completed` pipeline record. At the base `conda classify`
// exited 64 and wrote a `failed` wrapper record (D1 of the 2.7 inventory).
// Lane A8 runs it on the analysis run executor, so it exits 0 with a
// `completed` root record and a warning (E4). Both records also name
// why the profile degraded, in `profileReason` and `profileMessage`, and the
// GUI's warning line carries the message, so a lane that drops or rewords
// any of them shows here. A Bracken that completes is the negative control,
// and its GUI record holds neither key.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ClassifierBrackenDegradePinTests: XCTestCase {

    func testADegradedProfileCompletesWithWarningsInTheGUIAndCompletesTheCLI() async throws {
        let fixture = try FakeClassificationCondaFixture(brackenBehavior: .nonzero(42))
        defer { fixture.cleanup() }

        let gui = try await guiRun(fixture)
        XCTAssertEqual(gui.result.profileOutcome.state, .degraded)
        XCTAssertTrue(gui.metadata.requiresWarningCompletion, "the row ends Completed with Warnings")
        // The warning line names the reason, which the fake Bracken wrote to stderr. Lanes A8 and A10 keep it.
        XCTAssertEqual(
            gui.metadata.completionDetail,
            "1 of 1 reads classified; Bracken profiling degraded at resolved rank S: synthetic bracken failure"
        )
        XCTAssertEqual(gui.record.status, .completed)
        XCTAssertEqual(gui.record.exitStatus, 0)
        let guiResolved = gui.record.options.resolvedDefaults
        XCTAssertEqual(guiResolved["profileState"], .string("degraded"))
        XCTAssertEqual(guiResolved["profileReason"], .string("toolFailed"))
        XCTAssertEqual(guiResolved["profileMessage"], .string("synthetic bracken failure"))

        // Lane A8 flipped these from exit 64 and `failed` (E4).
        let cli = try await cliRun(fixture)
        XCTAssertEqual(cli.result.profileOutcome.state, .degraded)
        XCTAssertEqual(cli.status, .completed)
        XCTAssertEqual(cli.exitCode, 0)
        XCTAssertEqual(cli.wrapperEnvelope.exitStatus, 0)
        XCTAssertEqual(cli.wrapperEnvelope.status, .completed)
        // The root record names the reason and the message as the pipeline record does, in
        // `resolvedDefaults` and nowhere else, as the wrapper record did before lane A8 (E4).
        let cliOptions = cli.wrapperEnvelope.options
        XCTAssertEqual(cliOptions.resolvedDefaults["profileState"], .string("degraded"))
        XCTAssertEqual(cliOptions.resolvedDefaults["profileReason"], .string("toolFailed"))
        XCTAssertEqual(cliOptions.resolvedDefaults["profileMessage"], .string("synthetic bracken failure"))
        for key in ["profileReason", "profileMessage"] {
            XCTAssertNil(cliOptions.explicit[key], "\(key) is not an explicit option")
            XCTAssertNil(cliOptions.defaults[key], "\(key) is not a default")
        }
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
        XCTAssertNil(gui.record.options.resolvedDefaults["profileReason"], "a completed profile has no reason")
        XCTAssertNil(gui.record.options.resolvedDefaults["profileMessage"], "a completed profile has no message")

        let cli = try await cliRun(fixture)
        XCTAssertEqual(cli.status, .completed)
        XCTAssertEqual(cli.exitCode, 0)
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
