// BrackenThresholdPreflightTests.swift - A species report that stops below Bracken's threshold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B15 (row 255 of the Phase 2.8 plan). The stand-in half of the pin, which runs in
// the unit tier. The fake Bracken of `FakeClassificationCondaFixture` keeps a taxon at the level
// the way est_abundance.py does, when its clade reads are not below the threshold, and fails as it
// does when it keeps none. `BrackenThresholdPreflightLiveConformanceTests` holds the same cases
// against the managed Bracken, which is where the rule comes from, and holds this preflight to the
// same answer on the same reports.
//
// A report that stops below the threshold used to reach Bracken, which failed, and the profile
// degraded with `toolFailed` and Bracken's stderr. The preflight now degrades it before Bracken
// runs, with `belowThreshold` and a sentence that holds the threshold and the largest count.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class BrackenThresholdPreflightTests: XCTestCase {

    /// The default threshold, which every pipeline case here uses.
    private let threshold = BrackenProfileRequest.automaticDefault.threshold

    private func profile(
        reads: Int
    ) async throws -> (result: ClassificationResult, fixture: FakeClassificationCondaFixture, config: ClassificationConfig) {
        let fixture = try FakeClassificationCondaFixture(rankReads: reads)
        let config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
        let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)
        return (result, fixture, config)
    }

    private func resolution(
        _ rank: TaxonomicRank = .species,
        threshold: Int = BrackenProfileRequest.automaticDefault.threshold
    ) -> BrackenProfileResolution {
        BrackenDatabaseCapabilities.resolve(
            catalogID: nil,
            installationRecipe: nil,
            request: BrackenProfileRequest(rank: .explicit(rank), threshold: threshold)
        )
    }

    private func check(
        _ report: String,
        _ resolution: BrackenProfileResolution
    ) throws -> (BrackenProfileDegradationReason, String)? {
        BrackenReportCheck.failure(in: try KreportParser.parse(text: report), resolution: resolution)
    }

    private func report(species: Int, direct: Int? = nil, genus: Int? = nil) -> String {
        BrackenThresholdPreflightLiveConformanceTests.report(species: species, direct: direct, genus: genus)
    }

    // MARK: - The pipeline

    func testOneReadBelowTheThresholdDegradesBeforeBrackenRunsAndSaysWhy() async throws {
        let run = try await profile(reads: threshold - 1)
        defer { run.fixture.cleanup() }
        let message = "No species reaches the Bracken threshold of 10 reads. The species with the most reads has 9."

        XCTAssertEqual(run.result.profileOutcome.state, .degraded)
        XCTAssertEqual(run.result.profileOutcome.reason, .belowThreshold)
        XCTAssertEqual(run.result.profileOutcome.message, message)
        XCTAssertNil(run.result.brackenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.config.brackenURL.path))
        XCTAssertEqual(try run.fixture.brackenProfileInvocations(), [], "Bracken never ran")

        // The record: a preflight step with exit 2 and the sentence, no Bracken step, and the
        // reason and the message where every degraded profile files them (E4).
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.config.outputDirectory))
        let preflight = try XCTUnwrap(envelope.steps.first { $0.toolName == "Lungfish Bracken Preflight" })
        XCTAssertEqual(preflight.exitStatus, 2)
        XCTAssertEqual(preflight.stderr, message)
        XCTAssertFalse(envelope.steps.contains { $0.toolName == "bracken" })
        XCTAssertEqual(envelope.exitStatus, 0, "a degraded profile is not a failed run")
        XCTAssertEqual(envelope.options.resolvedDefaults["profileState"], .string("degraded"))
        XCTAssertEqual(envelope.options.resolvedDefaults["profileReason"], .string("belowThreshold"))
        XCTAssertEqual(envelope.options.resolvedDefaults["profileMessage"], .string(message))

        // The row reads Completed with Warnings, with the sentence as its reason (E4).
        let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: run.result)
        XCTAssertTrue(metadata.requiresWarningCompletion)
        XCTAssertEqual(
            metadata.completionDetail,
            "9 of 9 reads classified; Bracken profiling degraded at resolved rank S: \(message)"
        )
    }

    func testTheSidecarAddsNoKeyForTheNumbers() async throws {
        let run = try await profile(reads: threshold - 1)
        defer { run.fixture.cleanup() }

        let sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: run.config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename))
            ) as? [String: Any]
        )
        let outcome = try XCTUnwrap(sidecar["profileOutcome"] as? [String: Any])
        // A degraded outcome of any other reason is encoded with the same keys, so the numbers
        // are in the message and in no key of their own.
        let other = BrackenProfileOutcome.degraded(resolution: resolution(), reason: .toolFailed, message: "x")
        let otherKeys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(other)) as? [String: Any]
        ).keys
        XCTAssertEqual(Set(outcome.keys), Set(otherKeys))
        XCTAssertEqual(outcome["reason"] as? String, "belowThreshold")
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

    // MARK: - The check

    /// The count, the comparison and the rank, one rule each, as the managed Bracken applies them.
    func testTheCheckKeepsATaxonAtTheThresholdAndDropsOneBelowIt() throws {
        let below = try XCTUnwrap(try check(report(species: threshold - 1), resolution()))
        XCTAssertEqual(below.0, .belowThreshold)
        XCTAssertNil(try check(report(species: threshold), resolution()))
        XCTAssertNil(try check(report(species: threshold + 1), resolution()))
    }

    func testTheCountIsTheCladeCountAndNotTheReadsOnTheRowAlone() throws {
        // Species reads 10 with 4 on the row and 6 on a strain below it: kept, as Bracken keeps it.
        XCTAssertNil(try check(report(species: 10, direct: 4), resolution()))
        // The strain's reads count towards the species and still fall short at 9.
        let short = try XCTUnwrap(try check(report(species: 9, direct: 3), resolution()))
        XCTAssertEqual(short.0, .belowThreshold)
        XCTAssertTrue(short.1.hasSuffix("has 9."), short.1)
    }

    func testTheRankIsTheResolvedOneAlone() throws {
        // A genus of 25 reads above a species of 9 gives species level nothing to estimate.
        let aboveGenus = report(species: 9, genus: 25)
        let species = try XCTUnwrap(try check(aboveGenus, resolution(.species)))
        XCTAssertEqual(species.0, .belowThreshold)
        XCTAssertTrue(species.1.hasSuffix("has 9."), species.1)
        // At genus level the same report passes, because the genus holds 25.
        XCTAssertNil(try check(aboveGenus, resolution(.genus)))
    }

    func testARowAtNoSuchRankKeepsItsOwnReasonAndWords() throws {
        // A report that holds a strain row (S1) and no species row has nothing at species level.
        let report = """
         10.00\t10\t0\tR\t1\troot
         10.00\t10\t0\tD\t10239\t  Viruses
         10.00\t10\t10\tS1\t2697049\t    Severe acute respiratory syndrome coronavirus 2

        """
        let absent = try XCTUnwrap(try check(report, resolution(.species)))
        XCTAssertEqual(absent.0, .rankAbsentFromReport)
        XCTAssertEqual(absent.1, "The Kraken report has no rows at resolved rank S (Species).")
    }

    func testTheMessageHoldsTheThresholdAndTheLargestCountInPlainWords() throws {
        let genus = try XCTUnwrap(try check(report(species: 24, genus: 24), resolution(.genus, threshold: 25)))
        XCTAssertEqual(genus.0, .belowThreshold)
        XCTAssertEqual(genus.1, "No genus reaches the Bracken threshold of 25 reads. The genus with the most reads has 24.")

        let species = try XCTUnwrap(try check(report(species: 1), resolution()))
        XCTAssertEqual(species.1, "No species reaches the Bracken threshold of 10 reads. The species with the most reads has 1.")
    }

    func testTheLargestCountDecidesWhenSeveralTaxaSitAtTheRank() throws {
        let report = """
         50.00\t20\t0\tR\t1\troot
         50.00\t20\t0\tD\t10239\t  Viruses
         25.00\t10\t10\tS\t3418604\t    Betacoronavirus pandemicum
         25.00\t5\t5\tS\t11320\t    Influenza A virus
         25.00\t5\t5\tS\t11520\t    Influenza B virus

        """
        XCTAssertNil(try check(report, resolution()), "the largest species holds 10 and reaches the threshold")
        let higher = try XCTUnwrap(try check(report, resolution(.species, threshold: 11)))
        XCTAssertTrue(higher.1.hasSuffix("has 10."), higher.1)
    }
}
