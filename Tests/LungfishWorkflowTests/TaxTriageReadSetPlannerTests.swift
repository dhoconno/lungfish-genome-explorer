// TaxTriageReadSetPlannerTests.swift - How TaxTriage takes the reads of each sample and what its run records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md. A sample named by one bundle is planned by
// `SamplesheetReadSetPlanner`, and a sample that names two inputs as R1 and R2
// reads each as one file. A sample whose plan holds only single reads or only
// pairs records nothing new, so earlier runs compare byte for byte. A sample
// that mixes pairs and single reads records why every read ran single-end, and
// a sample of several files joined into one records the `cat` step that made
// the file, so the run's inputs trace back to the bundle.

import XCTest
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageReadSetPlannerTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-read-set-planner")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func resolved(_ bundle: URL) async throws -> TaxTriageSample {
        try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: "sample", fastq1: bundle),
            materializationDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true),
            materializer: fixtures.materializer
        )
    }

    private func config(_ samples: [TaxTriageSample]) -> TaxTriageConfig {
        TaxTriageConfig(samples: samples, outputDirectory: root.appendingPathComponent("out", isDirectory: true))
    }

    // MARK: - Named mates

    /// A sample that names two bundles as R1 and R2 reads each as one file. A
    /// bundle that holds pairs or several files is refused, never read in part.
    func testTaxTriageTakesOneFilePerNamedMateAndRefusesABundleOfPairs() async throws {
        XCTAssertEqual(TaxTriageReadSetPlanner.consumerID, "classify.taxtriage")
        let sample = TaxTriageSample(sampleId: "s", fastq1: fixtures.singleRoot, fastq2: fixtures.fullDerivative)
        let resolved = try await TaxTriageReadSetPlanner.resolve(
            sample,
            materializationDirectory: root.appendingPathComponent("mates", isDirectory: true),
            materializer: fixtures.materializer
        )
        XCTAssertEqual(try ReadSetFixtures.readNames(in: resolved.fastq1), ["s1", "s2", "s3"])
        XCTAssertEqual(try ReadSetFixtures.readNames(in: try XCTUnwrap(resolved.fastq2)), ["g1", "g2"])

        let pairs = TaxTriageSample(sampleId: "s", fastq1: fixtures.pairedDerivative, fastq2: fixtures.singleRoot)
        do {
            _ = try await TaxTriageReadSetPlanner.resolve(
                pairs,
                materializationDirectory: root.appendingPathComponent("mates", isDirectory: true),
                materializer: fixtures.materializer
            )
            XCTFail("a bundle of pairs named as one mate must be refused")
        } catch let error as SamplesheetReadSetPlannerError {
            guard case .notOneReadFile = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Run parameters

    func testASampleOfSingleReadsOrPairsRecordsNothingNew() async throws {
        for bundle in [fixtures.singleRoot, fixtures.interleavedRoot, fixtures.pairedDerivative, fixtures.chunkedRoot] {
            let sample = try await resolved(bundle)
            XCTAssertEqual(
                TaxTriagePipeline.readSetProvenanceParameters(for: config([sample])),
                [:],
                "\(bundle.lastPathComponent) adds no run parameter"
            )
        }
    }

    func testAMixedSampleRecordsWhyEveryReadRanSingleEnd() async throws {
        let mixed = try await resolved(fixtures.mergeDerivative)
        var other = try await resolved(fixtures.singleRoot)
        other = TaxTriageSample(sampleId: "other", fastq1: other.fastq1)
        let parameters = TaxTriagePipeline.readSetProvenanceParameters(for: config([mixed, other]))
        guard case .dictionary(let plans)? = parameters["read_set_plans"] else {
            return XCTFail("the run records the plans of its mixed samples: \(parameters)")
        }
        XCTAssertEqual(Set(plans.keys), ["sample"], "only the sample with something to say records a plan")
        guard case .dictionary(let plan)? = plans["sample"],
              case .string(let reason)? = plan["singleReadReason"] else {
            return XCTFail("the plan states the reason: \(plans)")
        }
        XCTAssertTrue(reason.contains("cannot pair part of a sample"), reason)
        XCTAssertEqual(plan["capability"], .string("pairs_only_when_all_paired"))
        XCTAssertEqual(plan["pairedFragments"], .integer(1))
        XCTAssertEqual(plan["mergedReads"], .integer(3))
    }

    func testTheRunParametersCarryThePlanOfAMixedSample() async throws {
        let mixed = try await resolved(fixtures.mixedRoot)
        let parameters = TaxTriagePipeline().provenanceParameters(for: config([mixed]))
        XCTAssertNotNil(parameters["read_set_plans"])
        XCTAssertEqual(parameters["sample_count"], .integer(1))

        let single = try await resolved(fixtures.singleRoot)
        XCTAssertNil(TaxTriagePipeline().provenanceParameters(for: config([single]))["read_set_plans"])
    }

    // MARK: - Steps

    /// The join of a chunked root is a `cat` step whose inputs are the chunks
    /// and whose output is the file the samplesheet names.
    func testAJoinedSampleRecordsTheCatStepThatMadeItsFile() async throws {
        let sample = try await resolved(fixtures.chunkedRoot)
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage read set test")
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: config([sample]), splits: [])
        let recorded = await ProvenanceRecorder.shared.getRun(runID)
        let run = try XCTUnwrap(recorded)

        let step = try XCTUnwrap(run.steps.first, "the join is recorded")
        XCTAssertEqual(run.steps.count, 1)
        XCTAssertEqual(step.toolName, SequenceInputConcatenation.toolName)
        XCTAssertEqual(step.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["run_0.fastq", "run_1.fastq"])
        XCTAssertEqual(step.outputs.map(\.path), [sample.fastq1.standardizedFileURL.path])
        XCTAssertEqual(step.resolvedOptions?["sample"], .string("sample"))
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertEqual(step.durableReplayArgv, step.command, "the join can be replayed")
        XCTAssertTrue(step.command.last?.hasPrefix("cat ") == true, "\(step.command)")
    }

    func testASampleReadInPlaceRecordsNoStep() async throws {
        let sample = try await resolved(fixtures.pairedDerivative)
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage read set test")
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: config([sample]), splits: [])
        let recorded = await ProvenanceRecorder.shared.getRun(runID)
        let run = try XCTUnwrap(recorded)
        XCTAssertEqual(run.steps.count, 0, "files read where they are need no step")
    }

    /// The split of a strictly interleaved file is recorded as before.
    func testAnInterleavedSplitIsStillRecordedAsItWas() async throws {
        let sample = try await resolved(fixtures.interleavedRoot)
        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: config([sample]),
            splitRoot: root.appendingPathComponent("split", isDirectory: true)
        )
        XCTAssertEqual(prepared.splits.count, 1)
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage read set test")
        await TaxTriagePipeline.recordReadSetSteps(runID: runID, config: config([sample]), splits: prepared.splits)
        let recorded = await ProvenanceRecorder.shared.getRun(runID)
        let run = try XCTUnwrap(recorded)
        XCTAssertEqual(run.steps.map(\.toolName), ["Lungfish TaxTriage Interleaved Split"])
        XCTAssertEqual(run.steps.first?.resolvedOptions?["pairs"], .integer(2))
        XCTAssertEqual(run.steps.first?.resolvedOptions?["sample"], .string("sample"))
    }
}
