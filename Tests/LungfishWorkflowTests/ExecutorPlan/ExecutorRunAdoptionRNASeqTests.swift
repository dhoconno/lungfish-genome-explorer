// ExecutorRunAdoptionRNASeqTests.swift - The RNA-seq payload of the adopt: a returned salmon run, or a batch of them,
// becomes one RNA-seq result as rnaseq quant writes it (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionRNASeqTests: XCTestCase {
    private typealias Fixture = SchemaTwoReturnedFolder
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionRNASeq")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var storageRoot: URL { root.appendingPathComponent("storage", isDirectory: true) }
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    /// The refusal of the RNA-seq adopt's preparation, or nil and a failure when it takes the folder.
    private func refusal(_ folder: URL, line: UInt = #line) -> Error? {
        do {
            _ = try ExecutorRunAdoption.prepareCounts(folder, storageRoot: storageRoot, name: "adopted", policy: .release)
            XCTFail("The RNA-seq adopt took the folder", line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - M2 item 1, the set under the storage root

    /// Gene sums need the set the plan names, so a storage root that holds no such set is refused in words that name
    /// the set, the folder looked in and how to get the set, before any result file exists.
    func testAdoptRefusesASetTheStorageRootDoesNotHoldInWordsThatNameIt() throws {
        let returned = try Fixture.make(root: root)
        let refused = refusal(returned.folder) as? ExecutorAdoptRefusal
        let sets = ReferenceSetOwner(storageRoot: storageRoot).setsFolder.path
        XCTAssertEqual(refused?.field, "pipeline.referenceSet")
        XCTAssertEqual(
            refused?.cause,
            "The plan sums genes through the reference set \(Fixture.setID), and \(sets) holds no such set. "
                + "Build the set on this Mac with lungfish-cli rnaseq reference-set, or copy it there, then adopt again."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }

    // MARK: - Fixtures over the refset-mito set

    static let pinnedPlan = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rnaseq/salmon-plan/plan.json")

    /// EX-PLAN-SALMON's pinned plan with the sample named `sample`.
    private func pinned(sample: String = "sample1") throws -> ExecutionPlan {
        var plan = try ExecutionPlan.decode(Data(contentsOf: Self.pinnedPlan))
        plan.sampleValues?.sampleName = sample
        return plan
    }

    /// The refset-mito set of the LGE layout under the storage root, the set the pinned plan names.
    private func buildSet() async throws -> ReferenceSetOutcome {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storageRoot, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(outcome.manifest.id, try pinned().pipeline?.referenceSet.id)
        return outcome
    }

    /// salmon's four files over the set's transcripts, under `quant/` as the pinned plan returns them. Transcript `n`
    /// holds `(n + 1) * scale` reads.
    static func salmonFiles(_ set: ReferenceSetOutcome, scale: Double = 1, version: String = "2.11.0", seqHash: String = "a1")
        throws -> [String: Data] {
        let names = try ReferenceSetAnnotationReader.fastaRecords(set.url.appendingPathComponent("derived/transcripts.fa")).map(\.name)
        let rows = names.enumerated().map { "\($1)\t100\t80.0\t10.0\t\(Double($0 + 1) * scale)\n" }
        let meta = """
            {"salmon_version": "\(version)", "num_processed": 1000, "num_mapped": 900, "percent_mapped": 90.0,
             "library_types": ["IU"], "seq_bias_correct": false, "gc_bias_correct": true, "pos_bias_correct": false,
             "index_seq_hash": "\(seqHash)", "index_name_hash": "b2", "index_decoy_seq_hash": "c3", "index_decoy_name_hash": "d4"}
            """
        return [
            "quant/quant.sf": Data(("Name\tLength\tEffectiveLength\tTPM\tNumReads\n" + rows.joined()).utf8),
            "quant/cmd_info.json": Data(#"{"salmon_version": "\#(version)", "libType": "A"}"#.utf8),
            "quant/lib_format_counts.json": Data(#"{"expected_format": "IU", "compatible_fragment_ratio": 1.0, "strand_mapping_bias": 0.5}"#.utf8),
            "quant/aux_info/meta_info.json": Data(meta.utf8),
        ]
    }

    private func adopt(_ folder: URL, name: String = "mito") throws -> URL {
        try ExecutorRunAdoption.adoptCounts(
            resultFolder: folder, projectDirectory: project, name: name, storageRoot: storageRoot, policy: .release,
            provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    // MARK: - M2 item 1, the payload

    /// A batch folder gives one result that holds all its samples, with gene sums by the set's table, the plan's route
    /// with the run's facts under the Mac route's keys, and each sample's steps in the record.
    func testBatchFolderGivesOneResultOfAllItsSamplesWithThePlansRouteAndTheRunsFacts() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        _ = try Fixture.make(root: batch, name: "sample1", plan: try pinned(), contents: try Self.salmonFiles(set))
        _ = try Fixture.make(root: batch, name: "sample2", plan: try pinned(sample: "sample2"), contents: try Self.salmonFiles(set, scale: 2))
        let result = try adopt(batch)
        let loaded = try RNASeqResultBundle.load(from: result)
        let manifest = loaded.manifest
        XCTAssertEqual(manifest.origin, .init(kind: .quantified, tool: "salmon", toolVersion: "2.11.0"))
        XCTAssertEqual(manifest.referenceSet, .init(id: set.manifest.id, layout: .lge))
        var expected = try XCTUnwrap(try pinned().pipeline?.route?.settings)
        for (key, value) in [
            "detectedLibraryType": "IU", "seqBias": "off", "gcBias": "on", "posBias": "off", "indexSeqHash": "a1",
            "indexNameHash": "b2", "indexDecoySeqHash": "c3", "indexDecoyNameHash": "d4",
        ] { expected[key] = value }
        XCTAssertEqual(manifest.route, .init(id: "salmon-selective-alignment-reads", tool: "salmon", toolVersion: "2.11.0", settings: expected))
        let genes = try XCTUnwrap(loaded.counts.first { $0.entry.rows == .gene }).table
        XCTAssertEqual(genes.sampleIDs, ["sample1", "sample2"])
        XCTAssertEqual(genes.rows.map { $0.counts[1] }, genes.rows.map { $0.counts[0] * 2 })
        XCTAssertEqual(manifest.sourceFiles.filter { $0.sample == "sample2" }.map(\.path).count, 4)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps.map(\.toolName), ["trim_galore", "salmon", "trim_galore", "salmon"])
        let salmon = record.steps[3]
        XCTAssertEqual(salmon.argv, ["/opt/conda/bin/salmon"] + (try pinned().steps[1].arguments))
        XCTAssertEqual(salmon.resolvedOptions["sample"], .string("sample2"))
        XCTAssertEqual(salmon.resolvedOptions["trimming"], .string("Poly-G trimming: off (LGE default)"))
        XCTAssertEqual(salmon.resolvedOptions["instrument"], .string("Instrument: Not recorded"))
        XCTAssertEqual(salmon.resolvedOptions["duplicates"], .string(SalmonQuantRecordLines.duplicates))
        XCTAssertEqual(record.steps[2].resolvedOptions["polyG"], .string("Poly-G trimming: off (LGE default)"))
    }

    // MARK: - M3 item 2, the adopt reads each sample's duplicates entry

    /// The pinned plan of `sample` whose `duplicates` entry and route key read `words` with `source`.
    private func pinned(sample: String, duplicates words: String, source: ImportSettingSource) throws -> ExecutionPlan {
        var plan = try pinned(sample: sample)
        let at = try XCTUnwrap(plan.pipeline?.settings.firstIndex { $0.id == "duplicates" })
        plan.pipeline?.settings[at].value = words
        plan.pipeline?.settings[at].source = source
        plan.pipeline?.route?.settings["duplicates"] = words
        return plan
    }

    private static func removed(by step: String) -> String {
        "Duplicates: removed at import by \(step), without UMIs. This count removes none."
    }

    /// A `duplicates` entry that is neither the removed words with source `recipe` nor the kept or the Not recorded
    /// words with source `default` is refused in words that name `duplicates`, the sample and the value, never read as
    /// kept, and nothing is written.
    func testAdoptRefusesADuplicatesEntryItCannotReadInWordsThatNameDuplicatesAndTheSample() async throws {
        let set = try await buildSet()
        let cases: [(String, ImportSettingSource)] = [
            ("Duplicates: probably kept", .default), (Self.removed(by: "Deduplicate"), .default),
            (SalmonQuantRecordLines.duplicates, .option), (SalmonQuantRecordLines.duplicates, .recipe),
        ]
        for (index, (words, source)) in cases.enumerated() {
            let plan = try pinned(sample: "odd", duplicates: words, source: source)
            let returned = try Fixture.make(root: root.appendingPathComponent("case\(index)"), name: "odd", plan: plan, contents: try Self.salmonFiles(set))
            let refused = refusal(returned.folder) as? ExecutorAdoptRefusal
            XCTAssertEqual(refused?.field, "pipeline.settings", "\(words) \(source)")
            let cause = refused?.cause ?? ""
            XCTAssertTrue(cause.contains("duplicates") && cause.contains("odd") && cause.contains(words), cause)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }

    /// Two samples whose imports removed duplicates by two steps share one state, so the batch gives one result whose
    /// route says every sample, and each sample's record line names its own step.
    func testBatchDeduplicatedByTwoStepsGivesOneResultWhoseRouteSaysEverySample() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        for (sample, step) in [("sample1", "Remove duplicate reads"), ("sample2", "Deduplicate")] {
            let plan = try pinned(sample: sample, duplicates: Self.removed(by: step), source: .recipe)
            _ = try Fixture.make(root: batch, name: sample, plan: plan, contents: try Self.salmonFiles(set))
        }
        let result = try adopt(batch)
        XCTAssertEqual(
            try RNASeqResultBundle.load(from: result).manifest.route.settings["duplicates"],
            "Duplicates: removed at import for every sample, without UMIs. This count removes none.")
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps[1].resolvedOptions["duplicates"], .string(Self.removed(by: "Remove duplicate reads")))
        XCTAssertEqual(record.steps[3].resolvedOptions["duplicates"], .string(Self.removed(by: "Deduplicate")))
    }

    /// A result adopted from plans holds samples of one duplicates state (`executor-plan.md`, the `duplicates`
    /// paragraph), so a batch of a deduplicated and a kept sample is refused in words that name `duplicates`.
    func testBatchOfTwoDuplicatesStatesIsRefusedInWordsThatNameDuplicates() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let removed = try pinned(sample: "sample1", duplicates: Self.removed(by: "Deduplicate"), source: .recipe)
        _ = try Fixture.make(root: batch, name: "sample1", plan: removed, contents: try Self.salmonFiles(set))
        _ = try Fixture.make(root: batch, name: "sample2", plan: try pinned(sample: "sample2"), contents: try Self.salmonFiles(set))
        let refused = refusal(batch) as? ExecutorAdoptRefusal
        XCTAssertEqual(refused?.field, "pipeline.route")
        let cause = refused?.cause ?? ""
        XCTAssertTrue(cause.contains("duplicates") && cause.contains("sample1") && cause.contains("two batches"), cause)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }
}
