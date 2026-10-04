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

    // MARK: - Files the user names inside a bundle

    // The coordinator's ruling of 2026-10-04. An explicit file or chunk path
    // means that file, as `taxtriage run --input <file>` always read it. A
    // bundle path is the whole bundle. Naming every member file of one bundle
    // collapses to the bundle, as `assemble` reads the files of one bundle.

    private func resolved(_ fastq1: URL, _ fastq2: URL) async throws -> TaxTriageSample {
        try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: "sample", fastq1: fastq1, fastq2: fastq2),
            materializationDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true),
            materializer: fixtures.materializer
        )
    }

    private func names(_ sample: TaxTriageSample) throws -> [[String]] {
        try ([sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])).map(ReadSetFixtures.readNames(in:))
    }

    /// Case 1. One file inside a bundle is read as named. The mate that sits
    /// beside it, or the chunks around it, are not read, and nothing is planned
    /// or written. Before, the whole enclosing bundle was planned.
    func testASingleFileInsideABundleIsReadAsNamed() async throws {
        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let mate = try await resolved(r1)
        XCTAssertEqual(mate.fastq1.standardizedFileURL, r1.standardizedFileURL)
        XCTAssertNil(mate.fastq2, "the R2 beside it is not read")
        XCTAssertEqual(try names(mate), [["p1/1", "p2/1"]])
        XCTAssertNil(mate.readSetPlan, "nothing was planned")
        XCTAssertNil(mate.readLayout)

        let chunk = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.chunkedRoot)?.last)
        XCTAssertEqual(chunk.lastPathComponent, "run_1.fastq")
        let named = try await resolved(chunk)
        XCTAssertEqual(named.fastq1.standardizedFileURL, chunk.standardizedFileURL)
        XCTAssertEqual(try names(named), [["c3"]], "one chunk, not the chunks of the bundle joined")
        XCTAssertNil(named.readSetPlan)

        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        let mergedSample = try await resolved(merged)
        XCTAssertEqual(try names(mergedSample), [["x1", "x2", "x3"]], "the merged file, not the whole merge derivative")
        XCTAssertNil(mergedSample.readSetPlan)
    }

    /// Case 2. Naming every member file of one bundle collapses the inputs to
    /// the bundle, planned as the bundle is. Two chunks of one run are single
    /// reads, so they are joined and never written as `fastq_1` and `fastq_2`.
    /// Before, the two chunks were handed over as a pair that never existed.
    func testEveryMemberFileOfOneBundleCollapsesToThePlannedBundle() async throws {
        let chunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.chunkedRoot))
        XCTAssertEqual(chunks.map(\.lastPathComponent), ["run_0.fastq", "run_1.fastq"])
        let joined = try await resolved(chunks[0], chunks[1])
        XCTAssertNil(joined.fastq2, "chunks of one run are not mates")
        XCTAssertEqual(try names(joined), [["c1", "c2", "c3"]])
        XCTAssertEqual(joined.readLayout, .singleEnd)
        XCTAssertNotNil(joined.readSetPlan)
        let join = try XCTUnwrap(SequenceInputConcatenation.load(for: joined.fastq1), "the join is recorded")
        XCTAssertEqual(join.memberURLs.map(\.lastPathComponent), ["run_0.fastq", "run_1.fastq"])

        // The two files of a paired derivative are a pair, planned as the bundle.
        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq")
        let r2 = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")
        let pair = try await resolved(r1, r2)
        XCTAssertEqual(try names(pair), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(pair.readLayout, .pairedFiles)
        XCTAssertNotNil(pair.readSetPlan, "the bundle was planned")
        XCTAssertEqual(pair.readSetPlan?.inputURL, fixtures.pairedDerivative.standardizedFileURL)

        // Whichever file is named first, the bundle's own R1 is `fastq_1`.
        let swapped = try await resolved(r2, r1)
        XCTAssertEqual(try names(swapped), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])

        // Two chunks of an Illumina run named as R1 and R2 are one pair, as the bundle plans them.
        let namedChunks = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: fixtures.namedPairChunkedRoot))
        let namedPair = try await resolved(namedChunks[0], namedChunks[1])
        XCTAssertEqual(try names(namedPair), [["q1/1"], ["q1/2"]])
        XCTAssertNotNil(namedPair.readSetPlan)
    }

    /// Some of a bundle's files, not every one, are the files named. The R1 and
    /// R2 of a merge derivative leave its merged file out, as the user chose.
    func testPartOfABundlesFilesAreReadAsNamed() async throws {
        let r1 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R1.fastq")
        let r2 = fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq")
        let pair = try await resolved(r1, r2)
        XCTAssertEqual(pair.fastq1.standardizedFileURL, r1.standardizedFileURL)
        XCTAssertEqual(pair.fastq2?.standardizedFileURL, r2.standardizedFileURL)
        XCTAssertEqual(try names(pair), [["u1/1"], ["u1/2"]])
        XCTAssertNil(pair.readSetPlan, "nothing was planned")

        // Files of two bundles are each read as named.
        let other = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq")
        let across = try await resolved(r1, other)
        XCTAssertEqual(try names(across), [["u1/1"], ["p1/2", "p2/2"]])
        XCTAssertNil(across.readSetPlan)
    }

    /// Case 3. A bundle path is the whole bundle, planned as it always was.
    func testABundlePathIsPlannedAsTheWholeBundle() async throws {
        let pair = try await resolved(fixtures.pairedDerivative)
        XCTAssertEqual(try names(pair), [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(pair.readLayout, .pairedFiles)
        XCTAssertNotNil(pair.readSetPlan)

        let chunks = try await resolved(fixtures.chunkedRoot)
        XCTAssertEqual(try names(chunks), [["c1", "c2", "c3"]])
        XCTAssertNotNil(chunks.readSetPlan)

        let merge = try await resolved(fixtures.mergeDerivative)
        XCTAssertEqual(try names(merge).first?.count, 5)
        XCTAssertNotNil(merge.readSetPlan?.singleReadReason)
    }

    /// The only FASTQ inside a virtual bundle is a preview of its reads. A
    /// file named there is that preview, which holds a few reads of the sample
    /// and not the sample, so it names its bundle, and the bundle is
    /// materialized as `fastq` subcommands read it. A classifier never runs on
    /// a preview.
    func testThePreviewOfAVirtualBundleNamesItsBundle() async throws {
        let preview = fixtures.subsetOfSingle.appendingPathComponent("preview.fastq")
        XCTAssertEqual(try ReadSetFixtures.readNames(in: preview), ["preview"])
        let notes = NoteLog()
        let sample = try await TaxTriageReadSetPlanner.resolve(
            TaxTriageSample(sampleId: "sample", fastq1: preview),
            materializationDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true),
            materializer: fixtures.materializer,
            progress: { notes.add($0) }
        )
        XCTAssertEqual(try names(sample), [["s1", "s3"]], "the materialized reads, not the preview")
        XCTAssertNotNil(sample.readSetPlan)
        XCTAssertTrue(
            notes.lines.contains { $0.contains("preview of the virtual bundle single-subset.lungfishfastq") },
            "\(notes.lines)"
        )
    }

    private final class NoteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func add(_ line: String) {
            lock.withLock { recorded.append(line) }
        }

        var lines: [String] { lock.withLock { recorded } }
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
