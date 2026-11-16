// ExecutorRunAdoptionDuplicatesTests.swift - One writer of the route's `duplicates` for rnaseq quant and the adopt, so a
// Mac result and an adopted Linux result of one deduplicated bundle share a route (Phase 5.3 lane EX-ADOPT M3, ruling
// ARCH-ADOPT-ROUTE items 1 to 5, backlog row RNASEQ-QUANT-DUPLICATES-NO-RECORD)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// These rows run the Mac route of `SalmonQuantRouteTests` with its stand-ins, so they extend that class.
extension SalmonQuantRouteTests {
    static let dedupStep = "Remove duplicate reads + Adapter + quality trim"
    static let removedLine = "Duplicates: removed at import by \(dedupStep), without UMIs. This count removes none."
    static let removedForEvery = "Duplicates: removed at import for every sample, without UMIs. This count removes none."
    static let notRecordedLine = "Duplicates: Not recorded (the bundle holds no import record that names its steps)"

    /// The recipe of an import that removed duplicates with fastp, without UMIs.
    static var deduplicatingImport: [RecipeStepResult] {
        [RecipeStepResult(
            stepName: dedupStep, tool: "fastp", toolVersion: "1.0.1", commandArguments: ["fastp", "--dedup", "-i", "a", "-o", "b"],
            inputReadCount: 10, outputReadCount: 8, durationSeconds: 1)]
    }

    /// A copy of the interleaved pair bundle with no sidecar and no record, so nothing says what its import did.
    func bareBundle(_ name: String) throws -> URL {
        let url = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.copyItem(at: fixtures.interleavedRoot, to: url)
        let reads = url.appendingPathComponent("reads.fastq")
        FASTQMetadataStore.delete(for: reads)
        XCTAssertNil(FASTQMetadataStore.load(for: reads))
        XCTAssertNil(SalmonQuantRecordLines.importRecord(of: url))
        return url
    }

    /// The refset-mito set the pinned plan names, under the storage root, and its index. salmon's stand-in is swapped
    /// for one whose index states the hashes of the adopt fixture's `meta_info.json` and whose quant writes the adopt
    /// fixture's four files at `-o`, so the Mac route counts the very salmon folder that a returned run holds.
    func mitoSetIndexAndSalmon() async throws -> (set: ReferenceSetOutcome, salmon: [String: Data]) {
        let (set, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: root, deriver: StandInTranscriptDeriver())
        let salmon = try ExecutorRunAdoptionRNASeqTests.salmonFiles(set)
        let folder = base.appendingPathComponent("salmon-folder", isDirectory: true)
        for (path, data) in salmon {
            let url = folder.appendingPathComponent(String(path.dropFirst("quant/".count)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let fixture = RNASeqFixtures.salmonRun("SRR896663").deletingLastPathComponent().path
        let script = Self.salmonScript(capture: capture)
            .replacingOccurrences(
                of: #""seq_hash": "seq1", "name_hash": "name1", "decoy_seq_hash": "dseq1", "decoy_name_hash": "dname1""#,
                with: #""seq_hash": "a1", "name_hash": "b2", "decoy_seq_hash": "c3", "decoy_name_hash": "d4""#)
            .replacingOccurrences(of: "\"\(fixture)/$run/\"", with: "\"\(folder.path)/\"")
        XCTAssertTrue(script.contains(folder.path) && script.contains(#""seq_hash": "a1""#), "the stand-in was swapped")
        try stand.install("salmon", script: script)
        let cache = SalmonIndexCache(
            storageRoot: root, runner: runner, provenanceWriter: ProvenanceWriter(signingProvider: nil), host: Self.roomy,
            freeSpace: { _ in 1_000_000_000_000 })
        _ = try await cache.ensure(SalmonIndexRequest(setID: set.manifest.id), linuxRoute: Self.linuxRoute)
        return (set, salmon)
    }

    /// The pinned plan of `sample`, whose reads the import deduplicated when `removed` (its `duplicates` entry and route
    /// key in the sample form, with source `recipe`, as the plan writer states them), or kept them.
    func plan(sample: String, removed: Bool) throws -> ExecutionPlan {
        var plan = try ExecutionPlan.decode(Data(contentsOf: ExecutorRunAdoptionRNASeqTests.pinnedPlan))
        plan.sampleValues?.sampleName = sample
        guard removed else { return plan }
        let at = try XCTUnwrap(plan.pipeline?.settings.firstIndex { $0.id == "duplicates" })
        plan.pipeline?.settings[at].value = Self.removedLine
        plan.pipeline?.settings[at].source = .recipe
        plan.pipeline?.route?.settings["duplicates"] = Self.removedLine
        return plan
    }

    /// Adopts one returned run, or a batch of them, of these plans, each returning `salmon`, into its own project.
    func adoptLinux(_ plans: [ExecutionPlan], salmon: [String: Data], name: String = "Linux") throws -> URL {
        let batch = base.appendingPathComponent("returned-\(name)", isDirectory: true)
        var folders: [URL] = []
        for plan in plans {
            let sample = try XCTUnwrap(plan.sampleValues?.sampleName)
            let contents = salmon.merging(try ExecutorRunAdoptionRNASeqTests.trimFiles()) { salmon, _ in salmon }
            folders.append(try SchemaTwoReturnedFolder.make(root: batch, name: sample, plan: plan, contents: contents).folder)
        }
        return try ExecutorRunAdoption.adoptCounts(
            resultFolder: plans.count == 1 ? folders[0] : batch,
            projectDirectory: base.appendingPathComponent("\(name).lungfish", isDirectory: true), name: name,
            storageRoot: root, policy: .release, provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    func route(of result: URL) throws -> RNASeqResultManifest.Route {
        try RNASeqResultBundle.load(from: result).manifest.route
    }

    // MARK: - Ruling ARCH-ADOPT-ROUTE item 5

    /// The plan row's proof (prog:250): a Mac result and an adopted Linux result of one deduplicated bundle's salmon
    /// folder have an equal whole `route`, whose `duplicates` states how the reads were counted with no step names and no
    /// sample count. Each sample's record line keeps the sample form with the step names, the same on both.
    func testMacAndLinuxResultsOfOneDeduplicatedBundleShareARoute() async throws {
        let (set, salmon) = try await mitoSetIndexAndSalmon()
        let bundle = try pairBundle("Dedup", importSteps: Self.deduplicatingImport)
        let mac = try await quant([bundle], set: set.manifest.id, trim: .trimGalore(polyG: false)).resultURL
        let linux = try adoptLinux([try plan(sample: "L1", removed: true)], salmon: salmon)
        let macRoute = try route(of: mac)
        XCTAssertEqual(try route(of: linux), macRoute)
        XCTAssertEqual(macRoute.settings["duplicates"], Self.removedForEvery)
        XCTAssertEqual(salmonLine(try record(mac), sample: "Dedup", "duplicates"), Self.removedLine)
        XCTAssertEqual(salmonLine(try record(linux), sample: "L1", "duplicates"), Self.removedLine)
    }

    /// The route holds no sample count, so an adopted batch of four deduplicated samples joins a Mac result of one in
    /// the one table `rnaseq export` writes.
    func testAdoptedBatchOfFourDeduplicatedSamplesJoinsAMacResultOfOne() async throws {
        let (set, salmon) = try await mitoSetIndexAndSalmon()
        let bundle = try pairBundle("Dedup", importSteps: Self.deduplicatingImport)
        let mac = try await quant([bundle], set: set.manifest.id, trim: .trimGalore(polyG: false)).resultURL
        let linux = try adoptLinux(try ["L1", "L2", "L3", "L4"].map { try plan(sample: $0, removed: true) }, salmon: salmon)
        let join = try RNASeqExportJoin.make(try RNASeqExportReader.read([mac, linux]))
        XCTAssertEqual(join.counts.sampleIDs, ["Dedup", "L1", "L2", "L3", "L4"])
        XCTAssertEqual(join.route.settings["duplicates"], Self.removedForEvery)
    }

    /// A Mac result whose samples differ in their duplicates state keeps the n-of-m form, so it never joins an adopted
    /// result, and the refusal prints both results' `duplicates` words.
    func testMixedMacResultAndAdoptedResultRefuseInWordsThatPrintDuplicates() async throws {
        let (set, salmon) = try await mitoSetIndexAndSalmon()
        let bundles = [try pairBundle("Dedup", importSteps: Self.deduplicatingImport), try pairBundle("Plain")]
        let mac = try await quant(bundles, set: set.manifest.id, trim: .trimGalore(polyG: false)).resultURL
        let linux = try adoptLinux([try plan(sample: "L1", removed: true)], salmon: salmon)
        let mixed = "Duplicates: removed at import for 1 of 2 samples, without UMIs. This count removes none."
        XCTAssertEqual(try route(of: mac).settings["duplicates"], mixed)
        do {
            _ = try RNASeqExportJoin.make(try RNASeqExportReader.read([mac, linux]))
            XCTFail("A Mac result of two duplicates states joined an adopted deduplicated result")
        } catch let refusal as RNASeqExportRefusal {
            let words = refusal.errorDescription ?? ""
            XCTAssertTrue(words.contains(", duplicates \(mixed)"), words)
            XCTAssertTrue(words.contains(", duplicates \(Self.removedForEvery)"), words)
        }
    }

    /// A Mac result and an adopted Linux result of the same kept reads share a route (`SCR/lanes/FIX-EX-SCHEMA.md:70`).
    func testMacAndLinuxResultsOfOneKeptBundleShareARoute() async throws {
        let (set, salmon) = try await mitoSetIndexAndSalmon()
        let mac = try await quant([try pairBundle("Kept")], set: set.manifest.id, trim: .trimGalore(polyG: false)).resultURL
        let linux = try adoptLinux([try plan(sample: "L1", removed: false)], salmon: salmon)
        let macRoute = try route(of: mac)
        XCTAssertEqual(try route(of: linux), macRoute)
        XCTAssertEqual(macRoute.settings["duplicates"], SalmonQuantRecordLines.duplicates)
    }

    /// The forms of the route's `duplicates` from its one writer (ruling ARCH-ADOPT-ROUTE item 1): one state names no
    /// step and no sample count, and only a mix counts the samples of each state.
    func testTheRoutesDuplicatesFormsFromItsOneWriter() {
        let write = SalmonQuantRecordLines.duplicatesSetting(removed:unrecorded:of:)
        let counted = "Duplicates: removed at import for 3 of 4 samples, without UMIs. This count removes none."
        XCTAssertEqual(write(0, 0, 4), SalmonQuantRecordLines.duplicates)
        XCTAssertEqual(write(0, 4, 4), Self.notRecordedLine)
        XCTAssertEqual(write(4, 0, 4), Self.removedForEvery)
        XCTAssertEqual(write(1, 0, 1), Self.removedForEvery)
        XCTAssertEqual(write(3, 0, 4), counted)
        XCTAssertEqual(write(3, 1, 4), counted + " Not recorded for 1 of 4 samples.")
        XCTAssertEqual(write(0, 1, 4), "Duplicates: Not recorded for 1 of 4 samples (the bundle holds no import record that names its steps)")
    }

    // MARK: - Backlog row RNASEQ-QUANT-DUPLICATES-NO-RECORD

    /// Reads whose bundle holds no import metadata and no import record read Not recorded in the line and the route,
    /// never kept, in the plan writer's words.
    func testABundleWithNoImportMetadataReadsNotRecordedAndNeverKept() async throws {
        let set = try await makeSetAndIndex()
        let result = try await quant([try bareBundle("Bare")], set: set).resultURL
        XCTAssertEqual(salmonLine(try record(result), sample: "Bare", "duplicates"), Self.notRecordedLine)
        XCTAssertEqual(try route(of: result).settings["duplicates"], Self.notRecordedLine)
        XCTAssertEqual(SalmonPlan.duplicatesNotRecorded, Self.notRecordedLine)
    }

    /// One run of a bundle whose import kept duplicates, one whose import removed them and one with no import metadata
    /// gives each sample its own line, and the route counts the removed and the Not recorded samples.
    func testOneRunOfKeptRemovedAndUnrecordedBundlesGivesEachSampleItsLine() async throws {
        let set = try await makeSetAndIndex()
        let bundles = [try pairBundle("Kept"), try pairBundle("Dedup", importSteps: Self.deduplicatingImport), try bareBundle("Bare")]
        let result = try await quant(bundles, set: set).resultURL
        let envelope = try record(result)
        XCTAssertEqual(salmonLine(envelope, sample: "Kept", "duplicates"), SalmonQuantRecordLines.duplicates)
        XCTAssertEqual(salmonLine(envelope, sample: "Dedup", "duplicates"), Self.removedLine)
        XCTAssertEqual(salmonLine(envelope, sample: "Bare", "duplicates"), Self.notRecordedLine)
        XCTAssertEqual(
            try route(of: result).settings["duplicates"],
            "Duplicates: removed at import for 1 of 3 samples, without UMIs. This count removes none. Not recorded for 1 of 3 samples.")
    }
}
