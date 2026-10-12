// BrackenThresholdPreflightTests.swift - A species report that stops below Bracken's threshold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B15 (row 255 of the Phase 2.8 plan). The stand-in half of the pin, which runs in
// the unit tier. The fake Bracken of `FakeClassificationCondaFixture` keeps a taxon at the level
// the way est_abundance.py does, when its clade reads are not below the threshold, and fails as it
// does when it keeps none. `BrackenThresholdPreflightLiveConformanceTests` holds the same cases
// against the managed Bracken, which is where that rule comes from.
//
// The first commit of the lane pins today's outcome, where Bracken runs on every report and
// degrades the profile with `toolFailed` after it fails. The writer commit flips the first case.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class BrackenThresholdPreflightTests: XCTestCase {

    /// The default threshold, which every case here uses.
    private let threshold = BrackenProfileRequest.automaticDefault.threshold

    private func profile(
        reads: Int
    ) async throws -> (result: ClassificationResult, fixture: FakeClassificationCondaFixture, config: ClassificationConfig) {
        let fixture = try FakeClassificationCondaFixture(rankReads: reads)
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)
        return (result, fixture, config)
    }

    // MARK: - Today's outcome

    func testOneReadBelowTheThresholdReachesBrackenAndDegradesWithItsOwnWords() async throws {
        let run = try await profile(reads: threshold - 1)
        defer { run.fixture.cleanup() }

        XCTAssertEqual(run.result.profileOutcome.state, .degraded)
        XCTAssertEqual(run.result.profileOutcome.reason, .toolFailed)
        XCTAssertTrue(
            run.result.profileOutcome.message?.contains("Error: no reads found. Please check your Kraken report") == true,
            run.result.profileOutcome.message ?? "no message"
        )
        XCTAssertEqual(try run.fixture.brackenProfileInvocations().count, 1, "Bracken ran and failed")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.config.outputDirectory))
        let preflight = try XCTUnwrap(envelope.steps.first { $0.toolName == "Lungfish Bracken Preflight" })
        XCTAssertEqual(preflight.exitStatus, 0)
        let bracken = try XCTUnwrap(envelope.steps.first { $0.toolName == "bracken" })
        XCTAssertEqual(bracken.exitStatus, 1)
    }

    func testAtTheThresholdBrackenRunsAndTheProfileCompletes() async throws {
        let run = try await profile(reads: threshold)
        defer { run.fixture.cleanup() }

        XCTAssertEqual(run.result.profileOutcome.state, .completed)
        XCTAssertNil(run.result.profileOutcome.reason)
        let calls = try run.fixture.brackenProfileInvocations()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.contains("-t \(threshold)") == true, calls.joined(separator: "\n"))
    }

    func testOneReadAboveTheThresholdBrackenRunsAndTheProfileCompletes() async throws {
        let run = try await profile(reads: threshold + 1)
        defer { run.fixture.cleanup() }

        XCTAssertEqual(run.result.profileOutcome.state, .completed)
        XCTAssertNil(run.result.profileOutcome.reason)
        let calls = try run.fixture.brackenProfileInvocations()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.contains("-t \(threshold)") == true, calls.joined(separator: "\n"))
    }
}
