// ExecutorRunAdoptionSoloTests.swift - The single-cell payload of the adopt: a returned STARsolo run becomes one
// single-cell RNA-seq result that states the plan's route, BIO-SOLO-GTF item 4's facts and the list (Phase 5.3 lane
// SOLO-PLAN M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionSoloTests: XCTestCase {
    private typealias Fixture = SchemaTwoReturnedFolder
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionSolo") }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private var storageRoot: URL { root.appendingPathComponent("storage", isDirectory: true) }
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    static let genes = ["ND1", "ND2", "COX1", "COX2", "ATP8", "ATP6", "COX3", "ND3", "ND4L", "ND4", "ND5", "ND6", "CYTB"]
    static let multimappers = "STARsolo counts an intronic read that maps to several loci when only one locus lies in a gene, "
        + "and Cell Ranger keeps a multi-mapper only for a single exonic locus"

    /// The plan SOLO-PLAN M2 pinned for `preset` on refset-mito, whose index is the `mkgtf-3.0.0` variant.
    static func pinned(_ preset: String) throws -> ExecutionPlan {
        try ExecutionPlan.decode(Data(contentsOf: RNASeqFixtures.root.appendingPathComponent("solo-plan/plan-\(preset).json")))
    }

    /// The refset-mito set of the LGE layout under the storage root, the set the pinned plans name.
    private func buildSet() async throws -> ReferenceSetOutcome {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storageRoot, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(outcome.manifest.id, try Self.pinned("tenx-3p-v3").pipeline?.referenceSet.id)
        return outcome
    }

    /// STARsolo's files of `feature` as a run returns them under `solo/`: 13 genes in 2 cells, each count 3. Every other
    /// `home` output takes the fixture's stand-in bytes.
    static func soloFiles(feature: String = "Gene") -> [String: Data] {
        let filtered = "solo/Solo.out/\(feature)/filtered"
        let entries = (1...13).flatMap { row in (1...2).map { "\(row) \($0) 3\n" } }.joined()
        return [
            "\(filtered)/features.tsv": Data(genes.map { "\($0)\t\($0)\tGene Expression\n" }.joined().utf8),
            "\(filtered)/barcodes.tsv": Data("AAACCCAAGAAACACT\nAAACCCAAGAAACCAT\n".utf8),
            "\(filtered)/matrix.mtx": Data(("%%MatrixMarket matrix coordinate integer general\n%\n13 2 26\n" + entries).utf8),
            "solo/Solo.out/\(feature)/Summary.csv": Data("Number of Reads,78\nEstimated Number of Cells,2\n".utf8),
            "solo/Log.final.out": Data("                          Number of input reads |\t78\n".utf8),
        ]
    }

    private func adopt(_ folder: URL, name: String = "solo") throws -> URL {
        try ExecutorRunAdoption.adoptCounts(
            resultFolder: folder, projectDirectory: project, name: name, storageRoot: storageRoot, policy: .release,
            provenanceWriter: ProvenanceWriter(signingProvider: nil))
    }

    private func refusal(_ folder: URL, line: UInt = #line) -> ExecutorAdoptRefusal? {
        do {
            _ = try ExecutorRunAdoption.prepareCounts(folder, storageRoot: storageRoot, name: "solo", policy: .release)
            XCTFail("The adopt took the folder", line: line)
            return nil
        } catch let refused as ExecutorAdoptRefusal {
            return refused
        } catch {
            XCTFail("Not an adopt refusal: \(error)", line: line)
            return nil
        }
    }

    // MARK: - Item 2, the single-cell payload

    /// A returned STARsolo run adopts as one single-cell result: the filtered `Gene` matrix read with the folder reader, no
    /// `raw` file kept, the plan's route under STAR's name, the set's genes, and a record whose counting step states BIO
    /// item 4's facts, the list in item 9's words and the multi-mapper line.
    func testAReturnedSTARsoloRunAdoptsAsOneSingleCellResultWithThePlansRouteAndFacts() async throws {
        let set = try await buildSet()
        let plan = try Self.pinned("tenx-3p-v3")
        let route = try XCTUnwrap(plan.pipeline?.route)
        let returned = try Fixture.make(root: root, name: "S1", plan: plan, contents: Self.soloFiles())
        let result = try adopt(returned.folder)
        let loaded = try RNASeqResultBundle.load(from: result)
        let manifest = loaded.manifest
        XCTAssertEqual(manifest.modality, .singleCell)
        XCTAssertEqual(manifest.origin, .init(kind: .quantified, tool: "STAR", toolVersion: "2.7.11b"))
        XCTAssertEqual(manifest.route, .init(id: "starsolo-gene", tool: "STAR", toolVersion: "2.7.11b", settings: route.settings))
        XCTAssertEqual(manifest.referenceSet, .init(id: set.manifest.id, layout: .lge))
        let matrix = try XCTUnwrap(manifest.matrices?.first)
        XCTAssertEqual(matrix.sample, "S1")
        XCTAssertEqual([matrix.cellCount, matrix.featureCount, matrix.entryCount], [2, 13, 26])
        XCTAssertEqual(manifest.sourceFiles.map(\.path).sorted(), [
            "Log.final.out", "Solo.out/Gene/Summary.csv", "Solo.out/Gene/filtered/barcodes.tsv",
            "Solo.out/Gene/filtered/features.tsv", "Solo.out/Gene/filtered/matrix.mtx",
        ].map { "source/S1/\($0)" })
        XCTAssertFalse(manifest.sourceFiles.contains { $0.path.contains("/raw/") }, "a raw matrix holds the whole list")

        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        XCTAssertEqual(record.steps.map(\.toolName), ["STAR"])
        let options = try XCTUnwrap(record.steps.first?.resolvedOptions)
        XCTAssertEqual(options["countingGTF"], .string(try XCTUnwrap(route.settings["countingGTF"])))
        let countingGTF = try XCTUnwrap(route.settings["countingGTF"])
        for fact in ["mkgtf-3.0.0", "version 1", "genes left out", set.manifest.id, try set.manifest.requireCountingGTF().sha256] {
            XCTAssertTrue(countingGTF.contains(fact), "BIO item 4: \(fact) in \(countingGTF)")
        }
        XCTAssertEqual(options["barcodeList"], .string(try XCTUnwrap(route.settings["barcodeList"])))
        XCTAssertEqual(options["barcodeListSource"], .string("list in the tool image"))
        XCTAssertEqual(options["multimappers"], .string(Self.multimappers))
        XCTAssertEqual(options["duplicates"], .string(try XCTUnwrap(route.settings["duplicates"])))
        guard case .array(let leftOut)? = options["filesLeftOut"] else { return XCTFail("no filesLeftOut in \(options)") }
        XCTAssertTrue(leftOut.contains(.string("S1/Solo.out/Gene/raw/")), "\(leftOut)")
        XCTAssertTrue(leftOut.contains(.string("S1/Solo.out/GeneFull_Ex50pAS/")), "\(leftOut)")
    }

    /// The introns preset counts `GeneFull_Ex50pAS`, and the folder reader reads `Solo.out/Gene`, so its run is refused in
    /// words that name the matrix, the folder import that keeps the exon matrix the run also returned, and the presets the
    /// adopt takes, and nothing is written (review SOLO-PLAN-M2-M3-BIO SF1).
    func testTheIntronsPresetIsRefusedInWordsThatNameTheMatrixTheAdoptReads() async throws {
        _ = try await buildSet()
        let plan = try Self.pinned("tenx-3p-v3-introns")
        let returned = try Fixture.make(root: root, name: "S1", plan: plan, contents: Self.soloFiles(feature: "GeneFull_Ex50pAS"))
        let refused = refusal(returned.folder)
        XCTAssertEqual(refused?.field, "pipeline.route")
        for words in ["GeneFull_Ex50pAS", "Solo.out/Gene", "tenx-3p-v3", "tenx-5p-v2", "lungfish-cli import rnaseq", "/solo"] {
            XCTAssertTrue(refused?.cause.contains(words) == true, "\(words) in \(refused?.cause ?? "")")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }

    /// The 5' v2 plan's list is supplied, so its words reach the record's `barcodeListSource`, with the list's name and
    /// SHA-256 in `barcodeList`. The adopt copies the plan's words with no check of its own, so this pins the supplied form
    /// that only the conformance case adopted before (review SOLO-PLAN-M2-M3-BIO SF2, BIO-SOLO-GTF item 9).
    func testASuppliedBarcodeListsSourceWordsReachTheRecord() async throws {
        _ = try await buildSet()
        let plan = try Self.pinned("tenx-5p-v2")
        let returned = try Fixture.make(root: root, name: "S1", plan: plan, contents: Self.soloFiles())
        let result = try adopt(returned.folder)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        let options = try XCTUnwrap(record.steps.first?.resolvedOptions)
        XCTAssertEqual(options["barcodeListSource"], .string("list supplied by the user"))
        XCTAssertEqual(options["barcodeList"],
                       .string("737K-august-2016, SHA-256 b0dda4b114d8fc7ea8def94fb472e6205c1831a72e3ac245ed13cc332d9f20d1"))
    }

    /// A plan whose index read another `derived/genes.gtf` than the set's under the storage root is refused in words that
    /// name the step and both SHA-256 values, before any matrix is read.
    func testAPlanCountedOnAnotherGenesGTFIsRefusedNamingTheStepAndBothDigests() async throws {
        let set = try await buildSet()
        let plan = try Self.pinned("tenx-3p-v3")
        let gtf = try set.manifest.requireCountingGTF().sha256
        let other = String(repeating: "c", count: 64)
        let words = try XCTUnwrap(plan.pipeline?.route?.settings["countingGTF"]).replacingOccurrences(of: gtf, with: other)
        let returned = try Fixture.make(root: root, name: "S1", plan: try Self.planStating(words, in: plan), contents: Self.soloFiles())
        let refused = refusal(returned.folder)
        XCTAssertEqual(refused?.field, "pipeline.route.settings")
        for words in ["starsolo", "S1", other, gtf, set.manifest.id] {
            XCTAssertTrue(refused?.cause.contains(words) == true, "\(words) in \(refused?.cause ?? "")")
        }
    }

    /// The check compares the digest of the set's own `derived/genes.gtf`, which the plan names after `derived/genes.gtf
    /// (SHA-256 `, and never the made file's. On a set that loses genes under a filter rule the two differ, so a plan whose
    /// made file differs from the set's file is adopted, and a plan counted on another `derived/genes.gtf` is refused naming
    /// both digests (review SOLO-PLAN-M2-M3-BIO SF3).
    func testTheAdoptComparesOnlyTheSetsOwnGTFDigestNotTheMadeFilesOne() async throws {
        let set = try await buildSet()
        let plan = try Self.pinned("tenx-3p-v3")
        let gtf = try set.manifest.requireCountingGTF().sha256
        let other = String(repeating: "c", count: 64)
        let words = try XCTUnwrap(plan.pipeline?.route?.settings["countingGTF"])
        // The pinned plan comes from the plain set, where the made file and `derived/genes.gtf` share one SHA-256.
        let made = "SHA-256 \(gtf), 13888 bytes, 0 genes left out"
        XCTAssertTrue(words.contains(made), words)

        // (1) Only the made file's facts differ from the set's file, as when the rule leaves genes out: the adopt takes it.
        let lossy = words.replacingOccurrences(of: made, with: "SHA-256 \(String(repeating: "e", count: 64)), 13000 bytes, 2 genes left out")
        let taken = try Fixture.make(root: root, name: "S1", plan: try Self.planStating(lossy, in: plan), contents: Self.soloFiles())
        let result = try adopt(taken.folder)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
        let options = try XCTUnwrap(record.steps.first?.resolvedOptions)
        guard case .string(let stated)? = options["countingGTF"] else { return XCTFail("no countingGTF in \(options)") }
        XCTAssertTrue(stated.contains("2 genes left out"), stated)

        // (2) Only the set's digest differs: the run is refused in words that name both values.
        let moved = words.replacingOccurrences(of: "derived/genes.gtf (SHA-256 \(gtf))", with: "derived/genes.gtf (SHA-256 \(other))")
        XCTAssertNotEqual(moved, words)
        let named = try Fixture.make(root: root, name: "S2", plan: try Self.planStating(moved, in: plan), contents: Self.soloFiles())
        let refused = refusal(named.folder)
        XCTAssertEqual(refused?.field, "pipeline.route.settings")
        for digest in [other, gtf] {
            XCTAssertTrue(refused?.cause.contains(digest) == true, "\(digest) in \(refused?.cause ?? "")")
        }
    }

    /// The plan with `words` as its `countingGTF`, in the route and in the plan's settings, which state one value as the
    /// plan writer writes them.
    private static func planStating(_ words: String, in plan: ExecutionPlan) throws -> ExecutionPlan {
        var plan = plan
        var pipeline = try XCTUnwrap(plan.pipeline)
        pipeline.route?.settings["countingGTF"] = words
        pipeline.settings = pipeline.settings.map { setting in
            var setting = setting
            if setting.id == "countingGTF" { setting.value = words }
            return setting
        }
        plan.pipeline = pipeline
        return plan
    }
}

/// The adopt of the STARsolo batches SOLO-PLAN M2's launcher-tier gate returned (M3 item 2's proof). Their `raw`
/// barcodes are the whole 10x lists, 115 MB for 3M, so the folders stay in the records and this case reads them behind
/// `LUNGFISH_SOLO_RETURNED`, the gate's `batches` folder. It copies each batch's `S1/plan.json`, `S1/staging.json` and
/// `S1/result/` into one returned folder, as a person copies a result home.
final class ExecutorRunAdoptionSoloConformanceTests: XCTestCase {
    func testTheGatesReturnedBatchesAdoptWithEveryGeneAboveZeroInEachCell() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_SOLO_RETURNED"] else {
            throw XCTSkip("Set LUNGFISH_SOLO_RETURNED to the batches folder of the SOLO-PLAN M2 gate")
        }
        let root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionSoloConformance")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let (set, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storage, deriver: StandInTranscriptDeriver())
        let fm = FileManager.default
        for batch in ["solo-3p-v3", "solo-5p-v2"] {
            let given = URL(fileURLWithPath: path).appendingPathComponent("\(batch)/S1", isDirectory: true)
            let folder = root.appendingPathComponent("home/\(batch)/S1", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["plan.json", "staging.json"] {
                try fm.copyItem(at: given.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            }
            for name in try fm.contentsOfDirectory(atPath: given.appendingPathComponent("result").path) {
                try fm.copyItem(at: given.appendingPathComponent("result/\(name)"), to: folder.appendingPathComponent(name))
            }
            let result = try ExecutorRunAdoption.adoptCounts(
                resultFolder: folder, projectDirectory: root.appendingPathComponent("project-\(batch)", isDirectory: true),
                name: batch, storageRoot: storage, policy: .release, provenanceWriter: ProvenanceWriter(signingProvider: nil))
            let manifest = try RNASeqResultBundle.load(from: result).manifest
            let matrix = try XCTUnwrap(manifest.matrices?.first)
            // 13 genes in 2 cells and 26 entries: each gene counts above 0 in each cell (BIO-SOLO-GTF item 1).
            XCTAssertEqual([matrix.featureCount, matrix.cellCount, matrix.entryCount], [13, 2, 26], batch)
            XCTAssertEqual(manifest.referenceSet?.id, set.manifest.id, batch)
            XCTAssertEqual(manifest.route.id, "starsolo-gene", batch)
            print("SOLO-PLAN adopt: \(batch) \(manifest.route.settings["barcodeList"] ?? "") \(result.path)")
        }
    }
}
