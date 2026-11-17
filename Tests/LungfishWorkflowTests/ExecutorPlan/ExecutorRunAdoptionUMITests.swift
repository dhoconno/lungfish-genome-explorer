// ExecutorRunAdoptionUMITests.swift - The UMI branch in the counts adopt: EX-UMI M2's S1 adopts umi_tools' count per
// gene in UMIs with the check's and the extraction's lines, and S2, whose UMI layout check failed, is refused in words
// that name the check's verdict (Phase 5.3 lane EX-ADOPT M6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionUMITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionUMI")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var storageRoot: URL { root.appendingPathComponent("storage", isDirectory: true) }
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    /// EX-UMI M2's batch of the launcher-tier run of 2026-11-16 07:56, as the lab's copy step leaves it.
    static let fixture = RNASeqFixtures.root.appendingPathComponent("umi-adopt/umi-2711", isDirectory: true)

    /// The words S2's check printed on standard error, which its run record keeps.
    static let s2CheckWords = "UMI layout check failed: 0 of 364 pairs read (0.0%) start within one mismatch of ATCAATC, "
        + "under the 90% the Quartz-Seq2 primer X910 (ATCAATC then a 16-nt UMI on Read 1) preset needs. These reads may come "
        + "from another kit, or Read 1 and Read 2 may be swapped. Try: check the sample sheet's kit column, and that the file "
        + "named Read 1 holds the UMI. This sample gets no UMI counts. UMI layout check failed: 0 of 364 pairs read (0.0%) "
        + "hold a distinct UMI, under 50%, because only 0 (0.0%) start with ATCAATC exactly while 0 (0.0%) are within one "
        + "mismatch. The kit's fixed sequence may differ from the preset's by one base. Try: check that the Quartz-Seq2 "
        + "primer X910 (ATCAATC then a 16-nt UMI on Read 1) preset matches the kit. This sample gets no UMI counts."

    static var s2Cause: String {
        "The UMI layout check of the sample S2 failed in the step umi-layout-check-pair1, so the run stopped there and the "
            + "sample has no UMI counts to adopt. A failed check never falls back to counting without UMIs. The check said: "
            + s2CheckWords
    }

    private func buildSet() async throws {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storageRoot, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(outcome.manifest.id, ExecutorRunAdoptionSTARTests.setID)
    }

    /// A copy of the returned batch, whose sample folders are `S1` and `S2`.
    private func batch() throws -> URL {
        let copy = root.appendingPathComponent("returned/umi-2711", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: copy)
        return copy
    }

    private func adopt(_ folder: URL, name: String) throws -> URL {
        try ExecutorRunAdoption.adoptCounts(
            resultFolder: folder, projectDirectory: project, name: name, storageRoot: storageRoot, policy: .release,
            provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    private func refusal(_ folder: URL, line: UInt = #line) -> ExecutorAdoptRefusal? {
        do {
            _ = try ExecutorRunAdoption.prepareCounts(folder, storageRoot: storageRoot, name: "adopted", policy: .release)
            XCTFail("The adopt took the folder", line: line)
            return nil
        } catch {
            XCTAssertTrue(error is ExecutorAdoptRefusal, "\(error)", line: line)
            return error as? ExecutorAdoptRefusal
        }
    }

    // MARK: - Item 3, the proof on S1

    /// S1 adopts as one gene table of umi_tools' counts in UMIs, each of the 13 genes at 24, with `umi/counts.tsv` kept,
    /// the route's `duplicates` in the result's UMI form, and the record's counting step holding the check's words, the
    /// extraction share, the sample's duplicates line and every other `home` file as left out.
    func testS1AdoptsEachOfTheThirteenGenesAtTwentyFourUMIs() async throws {
        try await buildSet()
        let sample = try batch().appendingPathComponent("S1", isDirectory: true)
        let result = try adopt(sample, name: "umi")
        let loaded = try RNASeqResultBundle.load(from: result)
        let plan = try ExecutionPlan.decode(Data(contentsOf: sample.appendingPathComponent("plan.json")))
        let route = try XCTUnwrap(plan.pipeline?.route)

        XCTAssertEqual(loaded.counts.map(\.entry.rows), [.gene])
        XCTAssertEqual(loaded.counts.map(\.entry.unit), [.umis])
        let table = try XCTUnwrap(loaded.counts.first).table
        XCTAssertEqual(table.sampleIDs, ["S1"])
        XCTAssertEqual(table.rows.map(\.id), ReferenceSetMitoFixture.genes)
        XCTAssertEqual(table.rows.map { $0.counts[0] }, Array(repeating: 24, count: 13))

        let manifest = loaded.manifest
        XCTAssertEqual(manifest.origin, .init(kind: .quantified, tool: "umi_tools", toolVersion: "1.1.6"))
        var settings = route.settings
        settings["duplicates"] = SalmonQuantRecordLines.duplicatesUMI
        XCTAssertEqual(manifest.route, .init(id: "umi-counts", tool: "umi_tools", toolVersion: "1.1.6", settings: settings))
        XCTAssertEqual(manifest.sourceFiles.map(\.path), ["source/S1/umi/counts.tsv"])
        XCTAssertEqual(
            manifest.sourceFiles.map(\.sha256), [PortableDigest.sha256Hex(of: try Data(contentsOf: sample.appendingPathComponent("umi/counts.tsv")))])

        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps.last?.toolName, "umi_tools")
        let counting = try XCTUnwrap(record.steps.last).resolvedOptions
        XCTAssertEqual(counting["umiCheck"], .string(
            "UMI layout check passed: 364 of 364 pairs read (100.0%) start within one mismatch of ATCAATC, 364 (100.0%) "
                + "exactly, and 312 (85.7%) hold a distinct UMI."))
        XCTAssertEqual(counting["umiExtraction"], .string(
            "umi_tools extract kept 364 of 364 reads (100.0%), the reads whose UMI read starts with the motif, in umi/pair1-extract.log"))
        XCTAssertEqual(counting["duplicates"], .string(try XCTUnwrap(route.settings["duplicates"])))
        XCTAssertEqual(counting["filesLeftOut"], .array(
            ["umi-check/pair1-layout-check.json", "umi/pair1-extract.log", "star/Log.final.out", "featurecounts/counts.txt.summary"]
                .map { .string($0) }))
    }

    /// S2's UMI layout check failed, so its run stopped and it has no counts: it is refused alone and in the batch in words
    /// that name the check's verdict and give the check's own words, and the batch imports nothing.
    func testS2WhoseCheckFailedIsRefusedInWordsThatNameTheVerdict() async throws {
        try await buildSet()
        let folder = try batch()
        let alone = refusal(folder.appendingPathComponent("S2", isDirectory: true))
        XCTAssertEqual(alone?.field, "failedStepID")
        XCTAssertEqual(alone?.cause, Self.s2Cause)

        do {
            _ = try adopt(folder, name: "umi-batch")
            XCTFail("The adopt took the batch")
        } catch ExecutorBatchAdoptError.refused(let refusals, let count) {
            XCTAssertEqual(count, 2)
            XCTAssertEqual(refusals, [ExecutorBatchAdoptRefusal(sample: "S2", field: "failedStepID", cause: Self.s2Cause, gap: nil)])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Analyses").path))
    }

    // MARK: - Item 3, the genes

    /// umi_tools lists only the genes it counted a UMI on, so a table without ND6 adopts ND6 at 0, and a table with an id
    /// the set lacks is refused in the words of the set's gene rule (BIO-COUNTING-GTF item 5).
    func testAGeneTheTableDoesNotListCountsNoneAndAnIdTheSetLacksIsRefused() async throws {
        try await buildSet()
        let sample = try batch().appendingPathComponent("S1", isDirectory: true)
        let rows = ReferenceSetMitoFixture.genes.filter { $0 != "ND6" }.map { "\($0)\t24\n" }.joined()
        try ReturnedFolderEdits.replace(sample, "umi/counts.tsv", with: "gene\tcount\n" + rows)
        let table = try XCTUnwrap(try RNASeqResultBundle.load(from: try adopt(sample, name: "no-nd6")).counts.first).table
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: table.rows.map { ($0.id, $0.counts[0]) })["ND6"], 0)
        XCTAssertEqual(table.rows.filter { $0.counts[0] == 24 }.count, 12)

        try ReturnedFolderEdits.replace(sample, "umi/counts.tsv", with: "gene\tcount\n" + rows + "NOT_A_GENE\t5\n")
        let refused = refusal(sample)
        XCTAssertEqual(refused?.field, "steps[6].outputs")
        XCTAssertEqual(
            refused?.cause,
            "The genes of umi/counts.tsv of the sample S1 are not the genes of the set \(ExecutorRunAdoptionSTARTests.setID): 1 id "
                + "is not the set's (NOT_A_GENE). It was counted on a GTF other than the set's derived/genes.gtf, so its genes "
                + "would read 0 where the reads are. Make the plan again with this version of Lungfish, run it, and adopt the "
                + "folder it returns.")
    }
}
