// ExecutorRunAdoptionSTARTests.swift - The STAR chains' payload of the counts adopt: EX-PLAN-STAR's three returned
// folders adopt STAR GeneCounts' column 2 or featureCounts' table, and the checks before any table refuse in words
// (Phase 5.3 lane EX-ADOPT M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionSTARTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionSTAR")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var storageRoot: URL { root.appendingPathComponent("storage", isDirectory: true) }
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    /// The set every returned plan names, built from `refset-mito` as M2's tests build it.
    static let setID = "macaca_fascicularis-Macaca_fascicularis_5.0-refseq101-lge-425be5f343ed"
    static let gtfSHA256 = "59418328435c67055273327b0421d42540c8e8ca32dd9086de09751a7001d45b"
    /// EX-PLAN-STAR's three batches of the launcher-tier run of 2026-11-16 00:11, as the lab's copy step leaves them.
    static let chains = ["star-2711-genecounts", "star-2711-featurecounts", "star-273a-genecounts"]
    static let fixtures = RNASeqFixtures.root.appendingPathComponent("star-adopt", isDirectory: true)

    private func buildSet() async throws -> ReferenceSetOutcome {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storageRoot, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(outcome.manifest.id, Self.setID)
        XCTAssertEqual(outcome.manifest.derived.countingGTF?.sha256, Self.gtfSHA256)
        return outcome
    }

    /// A copy of one returned batch, whose one sample folder is `S1`.
    private func batch(_ chain: String) throws -> URL {
        let copy = root.appendingPathComponent("returned/\(chain)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(chain, isDirectory: true), to: copy)
        return copy
    }

    /// Edits the run record of `folder` as JSON.
    private func editRecord(_ folder: URL, _ edit: (inout [String: Any]) throws -> Void) throws {
        let url = folder.appendingPathComponent("run-record.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    /// Replaces the `home` output `path` of `folder` with `text` and states its new SHA-256 and size in the record.
    private func replace(_ folder: URL, _ path: String, with text: String) throws {
        let data = Data(text.utf8)
        try data.write(to: folder.appendingPathComponent(path))
        try editRecord(folder) { record in
            var steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                var outputs = step["outputs"] as? [[String: Any]] ?? []
                for (position, output) in outputs.enumerated() where output["path"] as? String == path {
                    outputs[position]["sha256"] = PortableDigest.sha256Hex(of: data)
                    outputs[position]["bytes"] = data.count
                }
                steps[index]["outputs"] = outputs
            }
            record["steps"] = steps
        }
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

    /// The cells of each line of a tab-separated file.
    private func cells(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
    }

    // MARK: - Item 3, the proof on the three returned folders

    /// Each returned batch adopts as one result whose gene table equals column 2 of `ReadsPerGene.out.tab`, or the count
    /// column of `counts.txt`, gene for gene, with the 13 genes above 0 (BIO-COUNTING-GTF item 8), in pairs. The route is
    /// the plan's with `geneCountsColumn` for GeneCounts, the kept files are the ones the reader read with their bytes,
    /// and the record states the totals, the strand share 0.511 with no warning and each other `home` file as left out
    /// (ruling BIO-ADOPT-M5-Q1 items 3, 4, 5, 7 and 10).
    func testTheThreeReturnedFoldersAdoptColumnTwoOrTheCountColumnGeneForGene() async throws {
        _ = try await buildSet()
        for chain in Self.chains {
            let folder = try batch(chain)
            let sample = folder.appendingPathComponent("S1", isDirectory: true)
            let result = try adopt(folder, name: chain)
            let loaded = try RNASeqResultBundle.load(from: result)
            let plan = try ExecutionPlan.decode(Data(contentsOf: sample.appendingPathComponent("plan.json")))
            let route = try XCTUnwrap(plan.pipeline?.route)
            let geneCounts = route.tool == "STAR"
            let kept = geneCounts ? ["star/ReadsPerGene.out.tab"] : ["featurecounts/counts.txt", "featurecounts/counts.txt.summary"]
            let lines = try cells(sample.appendingPathComponent(kept[0]))
            let expected = geneCounts
                ? lines.dropFirst(4).map { ($0[0], Double($0[1]) ?? -1) }
                : lines.dropFirst(2).map { ($0[0], Double($0[6]) ?? -1) }

            XCTAssertEqual(loaded.counts.map(\.entry.rows), [.gene], chain)
            XCTAssertEqual(loaded.counts.map(\.entry.unit), [.pairs], chain)
            let table = try XCTUnwrap(loaded.counts.first).table
            XCTAssertEqual(table.sampleIDs, ["S1"])
            XCTAssertEqual(table.rows.map(\.id), ReferenceSetMitoFixture.genes, chain)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: table.rows.map { ($0.id, $0.counts[0]) }), Dictionary(uniqueKeysWithValues: expected), chain)
            XCTAssertEqual(table.rows.filter { $0.counts[0] > 0 }.count, 13, chain)
            if geneCounts {
                // Column 2, never 3 or 4: all 13 genes differ between them in these folders (ruling item 8).
                XCTAssertTrue(lines.dropFirst(4).allSatisfy { $0[1] != $0[2] && $0[1] != $0[3] }, chain)
            }

            let manifest = loaded.manifest
            XCTAssertEqual(manifest.origin, .init(kind: .quantified, tool: route.tool, toolVersion: route.toolVersion))
            XCTAssertEqual(manifest.referenceSet, .init(id: Self.setID, layout: .lge))
            var settings = route.settings
            if geneCounts {
                settings["geneCountsColumn"] = "Column 2 of STAR's ReadsPerGene.out.tab, unstranded: a pair counted for the gene "
                    + "whose exons it overlaps, on either strand. Columns 3 (read 1 on the gene's strand) and 4 (read 2 on the "
                    + "gene's strand) are not counts of this result and stay in source/<sample>/star/ReadsPerGene.out.tab."
            }
            XCTAssertEqual(manifest.route, .init(id: route.id, tool: route.tool, toolVersion: route.toolVersion, settings: settings), chain)
            XCTAssertEqual(manifest.sourceFiles.map(\.path), kept.map { "source/S1/\($0)" }, chain)
            XCTAssertEqual(
                manifest.sourceFiles.map(\.sha256),
                try kept.map { PortableDigest.sha256Hex(of: try Data(contentsOf: sample.appendingPathComponent($0))) }, chain)
            XCTAssertEqual(Set(manifest.sourceFiles.map(\.tool)), [route.tool])

            let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
            let counting = try XCTUnwrap(record.steps.last).resolvedOptions
            let home = plan.steps.flatMap { step in step.outputs.filter { step.outputPolicy?[$0] == .home } }
            XCTAssertEqual(counting["filesLeftOut"], .array(home.filter { !kept.contains($0) }.map { .string($0) }), chain)
            if geneCounts {
                let totals = lines.prefix(4).map { "\($0[0]) \($0[1])" }.joined(separator: ", ")
                XCTAssertEqual(counting["countsSummary"], .string("STAR's N_ lines in column 2, unstranded: \(totals)"), chain)
                XCTAssertEqual(counting["strandShare"], .string("Strand share 0.511 (column 3 over columns 3 and 4): reads unstranded"))
            } else {
                XCTAssertEqual(counting["countsSummary"], .string("featureCounts' summary: Assigned 2585, Unassigned_Ambiguity 15"))
                XCTAssertNil(counting["strandShare"])
            }
            XCTAssertNil(counting["strandWarning"], chain)
        }
    }

    // MARK: - Ruling BIO-ADOPT-M5-Q1 items 6 and 7, reads that do not look unstranded

    /// A hand-made table whose column 3 holds 0.9 of columns 3 and 4 still adopts column 2, and the record keeps the
    /// strand share and the warning in the ruling's words.
    func testATableOfStrandedReadsAdoptsColumnTwoWithTheWarning() async throws {
        _ = try await buildSet()
        let sample = try batch("star-2711-genecounts").appendingPathComponent("S1", isDirectory: true)
        let genes = ReferenceSetMitoFixture.genes.map { "\($0)\t100\t90\t10\n" }.joined()
        try replace(sample, "star/ReadsPerGene.out.tab", with: "N_unmapped\t0\t0\t0\nN_multimapping\t0\t0\t0\nN_noFeature\t3\t30\t40\n"
            + "N_ambiguous\t5\t2\t1\n" + genes)
        let result = try adopt(sample, name: "stranded")
        let table = try XCTUnwrap(try RNASeqResultBundle.load(from: result).counts.first).table
        XCTAssertEqual(table.rows.map { $0.counts[0] }, Array(repeating: 100, count: 13))
        let counting = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result)?.steps.last).resolvedOptions
        XCTAssertEqual(counting["countsSummary"], .string(
            "STAR's N_ lines in column 2, unstranded: N_unmapped 0, N_multimapping 0, N_noFeature 3, N_ambiguous 5"))
        XCTAssertEqual(
            counting["strandShare"], .string("Strand share 0.900 (column 3 over columns 3 and 4): read 1 mostly on the gene's strand"))
        XCTAssertEqual(counting["strandWarning"], .string(
            "S1's reads do not look unstranded (strand share 0.900, read 1 mostly on the gene's strand). The counts kept are "
                + "column 2, unstranded, as the plan's chain counts. LGE does not yet count STAR GeneCounts by strand."))
    }

    // MARK: - Item 1, a table of another GTF

    /// A hand-made table that lacks the 13 genes and holds one id the set lacks is refused in words that name the set,
    /// the numbers missing and extra with the first three of each, and what a table of another GTF would do, for each of
    /// the two readers (BIO-COUNTING-GTF item 5).
    func testATableOfAnotherGTFIsRefusedInWordsThatNameTheSetAndTheIds() async throws {
        _ = try await buildSet()
        let tail = "13 of the set's 13 genes with a length above 0 are missing (ND1, ND2, COX1 and 10 more), and 1 id is not "
            + "the set's (NOT_A_GENE). It was counted on a GTF other than the set's derived/genes.gtf, so its genes would read "
            + "0 where the reads are. Make the plan again with this version of Lungfish, run it, and adopt the folder it returns."
        let star = try batch("star-2711-genecounts").appendingPathComponent("S1", isDirectory: true)
        try replace(star, "star/ReadsPerGene.out.tab", with: "N_unmapped\t0\t0\t0\nN_multimapping\t0\t0\t0\nN_noFeature\t0\t0\t0\n"
            + "N_ambiguous\t0\t0\t0\nNOT_A_GENE\t5\t3\t2\n")
        let refused = refusal(star)
        XCTAssertEqual(refused?.field, "steps[1].outputs")
        XCTAssertEqual(refused?.cause, "The genes of star/ReadsPerGene.out.tab of the sample S1 are not the genes of the set "
            + "\(Self.setID): \(tail)")

        let featureCounts = try batch("star-2711-featurecounts").appendingPathComponent("S1", isDirectory: true)
        let table = try String(contentsOf: featureCounts.appendingPathComponent("featurecounts/counts.txt"), encoding: .utf8)
            .split(separator: "\n").prefix(2).joined(separator: "\n") + "\nNOT_A_GENE\tNC_012670.1\t1\t10\t+\t10\t5\n"
        try replace(featureCounts, "featurecounts/counts.txt", with: table)
        let other = refusal(featureCounts)
        XCTAssertEqual(other?.field, "steps[2].outputs")
        XCTAssertEqual(other?.cause, "The genes of featurecounts/counts.txt of the sample S1 are not the genes of the set "
            + "\(Self.setID): \(tail)")
    }

    // MARK: - Item 2, the two checks before any table is read

    /// A plan whose `countingGTF` names another `derived/genes.gtf` by SHA-256 than the set on this Mac holds is refused in
    /// words that name the counting step, before its table, here not a table at all, is read.
    func testAPlanCountedOnAnotherGenesGTFIsRefusedNamingTheStep() async throws {
        _ = try await buildSet()
        let sample = try batch("star-2711-genecounts").appendingPathComponent("S1", isDirectory: true)
        let other = String(repeating: "0", count: 64)
        let planURL = sample.appendingPathComponent("plan.json")
        let plan = Data(try String(contentsOf: planURL, encoding: .utf8).replacingOccurrences(of: Self.gtfSHA256, with: other).utf8)
        try plan.write(to: planURL)
        try editRecord(sample) { record in
            record["plan"] = ["relativePath": "plan.json", "sha256": PortableDigest.sha256Hex(of: plan), "size": plan.count]
        }
        try replace(sample, "star/ReadsPerGene.out.tab", with: "not a table\n")
        let refused = refusal(sample)
        XCTAssertEqual(refused?.field, "pipeline.route.settings")
        XCTAssertEqual(
            refused?.cause,
            "The step star-align of the sample S1 counted on a derived/genes.gtf of SHA-256 \(other), and the set \(Self.setID) "
                + "on this Mac holds derived/genes.gtf of SHA-256 \(Self.gtfSHA256), so its genes are not the ones counted. "
                + "Adopt the folder with the set the plan was made on, or make the plan again on this set.")
    }

    /// STAR's recorded argv shows `--outFilterMultimapNmax` only when the plan chose the loci, so a run that passed it for a
    /// plan of STAR's default is refused in words that name the step, before its table is read.
    func testARunWhoseSTARArgvDisagreesWithMultimapNmaxIsRefusedNamingTheStep() async throws {
        _ = try await buildSet()
        let sample = try batch("star-273a-genecounts").appendingPathComponent("S1", isDirectory: true)
        try replace(sample, "star/ReadsPerGene.out.tab", with: "not a table\n")
        try editRecord(sample) { record in
            var steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
            steps[1]["argv"] = (steps[1]["argv"] as? [String] ?? []) + ["--outFilterMultimapNmax", "1000"]
            record["steps"] = steps
        }
        let refused = refusal(sample)
        XCTAssertEqual(refused?.field, "steps[1].argv")
        XCTAssertEqual(
            refused?.cause,
            "The step star-align ran STAR with --outFilterMultimapNmax 1000, and the plan states multimapNmax as 10 loci, "
                + "STAR's default (no --outFilterMultimapNmax). Make the plan again with this version of Lungfish, run it, and "
                + "adopt the folder it returns.")
    }
}
