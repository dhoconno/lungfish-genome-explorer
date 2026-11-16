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

    static var adapterFixtures: URL { RNASeqFixtures.root.appendingPathComponent("trim-galore-adapter", isDirectory: true) }

    /// The pinned plan's trim outputs from the fixtures: both JSON reports, the saved C7 report that names Illumina or,
    /// when `nextera`, the same report naming Nextera, and the console file `console`, by default the Docker run's.
    static func trimFiles(console: String = "trim-pair1.stderr", nextera: Bool = false) throws -> [String: Data] {
        var report = try String(contentsOf: adapterFixtures.appendingPathComponent("c7_1.fq.gz_trimming_report.json"), encoding: .utf8)
        if nextera {
            let illumina = #"{"name": "Illumina", "sequence": "AGATCGGAAGAGC"}"#
            XCTAssertTrue(report.contains(illumina), "the saved report names Illumina")
            report = report.replacingOccurrences(of: illumina, with: #"{"name": "Nextera", "sequence": "CTGTCTCTTATA"}"#)
        }
        return [
            "trim-pair1/pair1_R1.fastq_trimming_report.json": Data(report.utf8),
            "trim-pair1/pair1_R2.fastq_trimming_report.json": Data(report.utf8),
            "logs/trim-pair1.stderr": try Data(contentsOf: adapterFixtures.appendingPathComponent(console)),
        ]
    }

    /// A returned run's `home` bytes: salmon's four files and the trim call's reports and console.
    static func returnedFiles(_ set: ReferenceSetOutcome, scale: Double = 1, console: String = "trim-pair1.stderr", nextera: Bool = false)
        throws -> [String: Data] {
        try salmonFiles(set, scale: scale).merging(try trimFiles(console: console, nextera: nextera)) { salmon, _ in salmon }
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
        _ = try Fixture.make(root: batch, name: "sample1", plan: try pinned(), contents: try Self.returnedFiles(set))
        _ = try Fixture.make(root: batch, name: "sample2", plan: try pinned(sample: "sample2"), contents: try Self.returnedFiles(set, scale: 2))
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
        // A plan pins its reads by digest and names no import record, so the adopt says what it cannot know, in words.
        XCTAssertEqual(
            salmon.resolvedOptions["importPolyG"],
            .string("Poly-G trimming at import: Not recorded (the plan names no import record that names its tools)"))
        XCTAssertEqual(salmon.resolvedOptions["duplicates"], .string(SalmonQuantRecordLines.duplicates))
        XCTAssertEqual(record.steps[2].resolvedOptions["polyG"], .string("Poly-G trimming: off (LGE default)"))
    }

    // MARK: - Review EX-ADOPT-M2M3-BIO should-fix 1, the name a sample keeps

    /// A sample whose name holds a space or punctuation keeps that name in the count tables, the samples and the record,
    /// as the Mac route labels it, since the plan and the adopt's own refusals say that name. The adopt relabelled it
    /// "Mock_1__rep.2".
    func testAdoptKeepsTheNameOfASampleWithSpacesAndPunctuation() async throws {
        let set = try await buildSet()
        let name = "Mock 1 (rep.2)"
        let returned = try Fixture.make(
            root: root.appendingPathComponent("named"), name: "mock-1", plan: try pinned(sample: name),
            contents: try Self.returnedFiles(set))
        let result = try adopt(returned.folder)
        let loaded = try RNASeqResultBundle.load(from: result)
        let genes = try XCTUnwrap(loaded.counts.first { $0.entry.rows == .gene }).table
        XCTAssertEqual(genes.sampleIDs, [name])
        XCTAssertEqual(loaded.samples.map(\.id), [name])
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps[1].resolvedOptions["sample"], .string(name))
    }

    /// Two samples whose names differ only in characters a folder name cannot hold, "S 1" and "S_1", are two samples of
    /// one result. The sanitizer made them one name and refused the batch as a repeated sample.
    func testBatchOfTwoSamplesWhoseNamesSanitizeAlikeGivesOneResultOfBoth() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        _ = try Fixture.make(root: batch, name: "first", plan: try pinned(sample: "S 1"), contents: try Self.returnedFiles(set))
        _ = try Fixture.make(root: batch, name: "second", plan: try pinned(sample: "S_1"), contents: try Self.returnedFiles(set, scale: 2))
        let loaded = try RNASeqResultBundle.load(from: try adopt(batch))
        let genes = try XCTUnwrap(loaded.counts.first { $0.entry.rows == .gene }).table
        XCTAssertEqual(genes.sampleIDs, ["S 1", "S_1"])
    }

    /// A plan whose sample has no name is refused in words that name the step, since the result could not label its
    /// counts, and nothing is written.
    func testAdoptRefusesAPlanWhoseStepNamesNoSample() async throws {
        let set = try await buildSet()
        let stepID = try pinned().steps[1].id
        let returned = try Fixture.make(root: root, name: "nameless", plan: try pinned(sample: ""), contents: try Self.returnedFiles(set))
        let refused = refusal(returned.folder) as? ExecutorAdoptRefusal
        XCTAssertEqual(refused?.field, "sample.sampleName")
        XCTAssertEqual(refused?.cause, "The plan of the step \(stepID) names no sample, so the result could not label its counts.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
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
            let returned = try Fixture.make(root: root.appendingPathComponent("case\(index)"), name: "odd", plan: plan, contents: try Self.returnedFiles(set))
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
            _ = try Fixture.make(root: batch, name: sample, plan: plan, contents: try Self.returnedFiles(set))
        }
        let result = try adopt(batch)
        XCTAssertEqual(
            try RNASeqResultBundle.load(from: result).manifest.route.settings["duplicates"],
            "Duplicates: removed at import for every sample, without UMIs. This count removes none.")
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps[1].resolvedOptions["duplicates"], .string(Self.removed(by: "Remove duplicate reads")))
        XCTAssertEqual(record.steps[3].resolvedOptions["duplicates"], .string(Self.removed(by: "Deduplicate")))
    }

    // MARK: - M3 item 3, the poly-G proof

    /// A poly-G off result and a poly-G on result of one chain never join, and the refusal prints both `trimming` words.
    func testPolyGOffAndPolyGOnResultsOfOneChainRefuseInWordsThatPrintTrimming() async throws {
        let set = try await buildSet()
        let on = "Poly-G trimming: on (chosen), Trim Galore 2.3.0 --poly_g"
        var plan = try pinned(sample: "on")
        let at = try XCTUnwrap(plan.pipeline?.settings.firstIndex { $0.id == "trimming" })
        plan.pipeline?.settings[at].value = on
        plan.pipeline?.settings[at].source = .option
        plan.pipeline?.route?.settings["trimming"] = on
        for index in plan.steps.indices where plan.steps[index].tool?.id == "trim_galore" {
            plan.steps[index].arguments = plan.steps[index].arguments.map { $0 == "--no_poly_g" ? "--poly_g" : $0 }
        }
        XCTAssertTrue(plan.steps.contains { $0.arguments.contains("--poly_g") })
        let off = try adopt(try Fixture.make(root: root.appendingPathComponent("off"), name: "off", plan: try pinned(sample: "off"),
                                             contents: try Self.returnedFiles(set)).folder, name: "off")
        let onResult = try adopt(try Fixture.make(root: root.appendingPathComponent("on"), name: "on", plan: plan,
                                                  contents: try Self.returnedFiles(set)).folder, name: "on")
        do {
            _ = try RNASeqExportJoin.make(try RNASeqExportReader.read([off, onResult]))
            XCTFail("A poly-G off result joined a poly-G on result")
        } catch let refusal as RNASeqExportRefusal {
            let words = refusal.errorDescription ?? ""
            XCTAssertTrue(words.contains(", trimming Poly-G trimming: off (LGE default)"), words)
            XCTAssertTrue(words.contains(", trimming \(on)"), words)
        }
    }

    /// A result adopted from plans holds samples of one duplicates state (`executor-plan.md`, the `duplicates`
    /// paragraph), so a batch of a deduplicated and a kept sample is refused in words that name `duplicates`.
    func testBatchOfTwoDuplicatesStatesIsRefusedInWordsThatNameDuplicates() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        let removed = try pinned(sample: "sample1", duplicates: Self.removed(by: "Deduplicate"), source: .recipe)
        _ = try Fixture.make(root: batch, name: "sample1", plan: removed, contents: try Self.returnedFiles(set))
        _ = try Fixture.make(root: batch, name: "sample2", plan: try pinned(sample: "sample2"), contents: try Self.returnedFiles(set))
        let refused = refusal(batch) as? ExecutorAdoptRefusal
        XCTAssertEqual(refused?.field, "pipeline.route")
        let cause = refused?.cause ?? ""
        XCTAssertTrue(cause.contains("duplicates") && cause.contains("sample1") && cause.contains("two batches"), cause)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }

    // MARK: - M4, the adapter of each trim call (ruling BIO-PLAN-ADAPTER items 4 and 8)

    static let illuminaWords = "Trim Galore 2.3.0 auto-detected the Illumina adapter AGATCGGAAGAGC in read 1."
    static let routeAdapter = "Adapter: chosen by Trim Galore 2.3.0 from read 1 (auto-detection)"

    /// Each trim call's step states, from its JSON reports and the console line the Docker run returned, the adapter's
    /// name and sequence, the read 2 adapter, the length cutoff and the line. A result of one adapter has no sentence.
    func testAdoptStatesEachTrimCallsAdapterFromItsReportsAndConsoleLine() async throws {
        let set = try await buildSet()
        let returned = try Fixture.make(root: root, name: "S1", plan: try pinned(sample: "S1"), contents: try Self.returnedFiles(set))
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: try adopt(returned.folder)))
        let trim = record.steps[0]
        XCTAssertEqual(trim.toolName, "trim_galore")
        XCTAssertEqual(trim.resolvedOptions["adapter"], .string(Self.illuminaWords))
        XCTAssertEqual(trim.resolvedOptions["adapterName"], .string("Illumina"))
        XCTAssertEqual(trim.resolvedOptions["adapterSequence"], .string("AGATCGGAAGAGC"))
        XCTAssertEqual(trim.resolvedOptions["adapterRead2"], .string("none"))
        XCTAssertEqual(trim.resolvedOptions["lengthCutoff"], .integer(20))
        XCTAssertEqual(
            trim.resolvedOptions["adapterDetection"],
            .string("Using Illumina adapter for trimming (count: 365). Second best hit was Nextera (count: 0)."))
        XCTAssertEqual(trim.resolvedOptions["polyG"], .string("Poly-G trimming: off (LGE default)"))
        XCTAssertNil(record.options.resolvedDefaults["adapters"])
    }

    /// A batch whose samples got different adapters gives one result whose record says so in one sentence. The route
    /// states how the adapter was chosen, which both samples share, so it keeps the plan's words.
    func testAdoptedBatchWhoseSamplesGotDifferentAdaptersSaysSoInOneSentence() async throws {
        let set = try await buildSet()
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        _ = try Fixture.make(root: batch, name: "S1", plan: try pinned(sample: "S1"), contents: try Self.returnedFiles(set))
        _ = try Fixture.make(
            root: batch, name: "S2", plan: try pinned(sample: "S2"),
            contents: try Self.returnedFiles(set, console: "cy0721_01-detection.txt", nextera: true))
        let result = try adopt(batch)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(
            record.options.resolvedDefaults["adapters"],
            .string("Trim Galore chose different adapters for the samples of this result, the Illumina adapter AGATCGGAAGAGC "
                + "for S1 and the Nextera adapter CTGTCTCTTATA for S2."))
        XCTAssertEqual(record.steps[0].resolvedOptions["adapter"], .string(Self.illuminaWords))
        XCTAssertEqual(
            record.steps[2].resolvedOptions["adapter"],
            .string("Trim Galore 2.3.0 auto-detected the Nextera adapter CTGTCTCTTATA in read 1."))
        XCTAssertEqual(try RNASeqResultBundle.load(from: result).manifest.route.settings["adapter"], Self.routeAdapter)
    }

    /// A trim call whose returned JSON report is not a Trim Galore report is refused in words that name the step, the
    /// report and the adapter, and nothing is written.
    func testAdoptRefusesATrimCallWhoseReportIsNotATrimGaloreReport() async throws {
        let set = try await buildSet()
        let returned = try Fixture.make(root: root, name: "S1", plan: try pinned(sample: "S1"), contents: try Self.salmonFiles(set))
        let refused = refusal(returned.folder) as? ExecutorAdoptRefusal
        XCTAssertEqual(refused?.field, "steps[0].outputs")
        let cause = refused?.cause ?? ""
        XCTAssertTrue(
            cause.contains("trim-pair1") && cause.contains("adapter") && cause.contains("trim-pair1/pair1_R1.fastq_trimming_report.json"),
            cause)
        XCTAssertTrue(cause.contains("the sample S1") && cause.contains("Make the plan again"), cause)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }
}
