// ExecutorRunAdoptionDefaultRouteTests.swift - LGE's default route in the counts adopt: the M3 gate's two returned
// folders of STAR then salmon -a adopt salmon's gene sums, read alignmentScoring from the argv, and name STAR's files
// as left out, and a batch that mixes the two scorings is refused in words (Phase 5.3 lane EX-ADOPT M6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Edits of a returned plan folder that keep the run record's SHA-256 and sizes true, shared by the M6 suites.
enum ReturnedFolderEdits {
    /// Edits the run record of `folder` as JSON.
    static func editRecord(_ folder: URL, _ edit: (inout [String: Any]) throws -> Void) throws {
        let url = folder.appendingPathComponent("run-record.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    /// Edits the plan of `folder` as JSON and states its new SHA-256 and size in the run record.
    static func editPlan(_ folder: URL, _ edit: (inout [String: Any]) throws -> Void) throws {
        let url = folder.appendingPathComponent("plan.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try edit(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
        try editRecord(folder) { $0["plan"] = ["relativePath": "plan.json", "sha256": PortableDigest.sha256Hex(of: data), "size": data.count] }
    }

    /// Replaces the `home` output `path` of `folder` with `text` and states its new SHA-256 and size in the record.
    static func replace(_ folder: URL, _ path: String, with text: String) throws {
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

    /// The plan's `home` outputs in step order.
    static func homeOutputs(_ plan: ExecutionPlan) -> [String] {
        plan.steps.flatMap { step in step.outputs.filter { step.outputPolicy?[$0] == .home } }
    }
}

final class ExecutorRunAdoptionDefaultRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionDefaultRoute")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var storageRoot: URL { root.appendingPathComponent("storage", isDirectory: true) }
    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    /// The M3 gate's two batches of the launcher-tier run of 2026-11-16 07:52, as the lab's copy step leaves them.
    static let chains = ["star-salmon-none": "none", "star-salmon-errormodel": "errorModel"]
    static let fixtures = RNASeqFixtures.root.appendingPathComponent("star-salmon-adopt", isDirectory: true)
    static let quantFiles = ["quant/quant.sf", "quant/cmd_info.json", "quant/lib_format_counts.json", "quant/aux_info/meta_info.json"]

    private func buildSet() async throws {
        let (outcome, _, _) = try await ReferenceSetMitoFixture.build(.lge, root: storageRoot, deriver: StandInTranscriptDeriver())
        XCTAssertEqual(outcome.manifest.id, ExecutorRunAdoptionSTARTests.setID)
    }

    /// A copy of one returned batch, whose one sample folder is `S1`, at `name` under the test's folder.
    private func batch(_ chain: String, as name: String? = nil) throws -> URL {
        let copy = root.appendingPathComponent("returned/\(name ?? chain)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(chain, isDirectory: true), to: copy)
        return copy
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

    // MARK: - Item 2, the proof on the M3 gate's two returned folders

    /// Each returned batch adopts as one salmon result whose gene table equals the gene sums of its `quant/quant.sf`, 13
    /// genes above 0, with the plan's route and `alignmentScoring` as the plan states it, salmon's four files kept, and
    /// the record naming every other `home` file, STAR's `Log.final.out` and `ReadsPerGene.out.tab` among them, as left
    /// out.
    func testTheTwoReturnedFoldersAdoptSalmonsGeneSumsAndNameSTARsFilesAsLeftOut() async throws {
        try await buildSet()
        for (chain, scoring) in Self.chains.sorted(by: { $0.key < $1.key }) {
            let folder = try batch(chain)
            let sample = folder.appendingPathComponent("S1", isDirectory: true)
            let result = try ExecutorRunAdoption.adoptCounts(
                resultFolder: folder, projectDirectory: project, name: chain, storageRoot: storageRoot, policy: .release,
                provenanceWriter: ProvenanceWriter(signingProvider: nil))
            let loaded = try RNASeqResultBundle.load(from: result)
            let plan = try ExecutionPlan.decode(Data(contentsOf: sample.appendingPathComponent("plan.json")))
            let route = try XCTUnwrap(plan.pipeline?.route)

            // salmon's NumReads summed by gene: each transcript of the set is <gene>:unknown_transcript_1.
            var sums: [String: Double] = [:]
            let quant = try String(contentsOf: sample.appendingPathComponent("quant/quant.sf"), encoding: .utf8)
            for line in quant.split(separator: "\n").dropFirst() {
                let cells = line.components(separatedBy: "\t")
                sums[String(cells[0].split(separator: ":")[0]), default: 0] += Double(cells[4]) ?? -1
            }
            let genes = try XCTUnwrap(loaded.counts.first { $0.entry.rows == .gene })
            XCTAssertEqual(genes.entry.unit, .estimated, chain)
            XCTAssertEqual(genes.table.sampleIDs, ["S1"], chain)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: genes.table.rows.map { ($0.id, $0.counts[0]) }), sums, chain)
            XCTAssertEqual(genes.table.rows.filter { $0.counts[0] > 0 }.count, 13, chain)

            let manifest = loaded.manifest
            XCTAssertEqual(manifest.origin, .init(kind: .quantified, tool: "salmon", toolVersion: route.toolVersion), chain)
            XCTAssertEqual(manifest.route.id, route.id, chain)
            XCTAssertEqual(manifest.route.settings["alignmentScoring"], scoring, chain)
            for (key, value) in route.settings where key != "duplicates" {
                XCTAssertEqual(manifest.route.settings[key], value, "\(chain) \(key)")
            }
            // salmon's folder layout under source/<sample>/, as the import of a salmon folder keeps it.
            XCTAssertEqual(
                manifest.sourceFiles.map(\.path).sorted(), Self.quantFiles.map { "source/S1/\($0.dropFirst("quant/".count))" }.sorted(), chain)

            let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
            let counting = try XCTUnwrap(record.steps.last).resolvedOptions
            let leftOut = ReturnedFolderEdits.homeOutputs(plan).filter { !Self.quantFiles.contains($0) }
            XCTAssertTrue(leftOut.contains("star/Log.final.out") && leftOut.contains("star/ReadsPerGene.out.tab"), "\(leftOut)")
            XCTAssertEqual(counting["filesLeftOut"], .array(leftOut.map { .string($0) }), chain)
        }
    }

    /// `alignmentScoring` is read from the counting step's recorded argv: the errorModel run's `cmd_info.json` names no
    /// flag (EX-PLAN-STAR M3 gate F11) and the run adopts, and the same run without `--errorModel` in its argv is refused
    /// in words that name the step.
    func testAlignmentScoringIsReadFromTheArgvAndNeverFromCmdInfo() async throws {
        try await buildSet()
        let sample = try batch("star-salmon-errormodel").appendingPathComponent("S1", isDirectory: true)
        let cmdInfo = try String(contentsOf: sample.appendingPathComponent("quant/cmd_info.json"), encoding: .utf8)
        XCTAssertFalse(cmdInfo.lowercased().contains("errormodel"))
        _ = try ExecutorRunAdoption.prepareCounts(sample, storageRoot: storageRoot, name: "adopted", policy: .release)

        try ReturnedFolderEdits.editRecord(sample) { record in
            var steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
            steps[2]["argv"] = try XCTUnwrap(steps[2]["argv"] as? [String]).filter { $0 != "--errorModel" }
            record["steps"] = steps
        }
        let refused = refusal(sample)
        XCTAssertEqual(refused?.field, "steps[2].argv")
        XCTAssertEqual(
            refused?.cause, "The step salmon-quant ran salmon without --errorModel, and the plan states alignmentScoring as errorModel.")
    }

    /// A batch of one sample counted with salmon's error model and one without is refused in words that name both
    /// scorings and say to adopt them as two batches.
    func testABatchThatMixesNoneAndErrorModelIsRefusedInWords() async throws {
        try await buildSet()
        let mixed = try batch("star-salmon-none", as: "mixed")
        let other = try batch("star-salmon-errormodel", as: "other")
        let second = mixed.appendingPathComponent("S2", isDirectory: true)
        try FileManager.default.moveItem(at: other.appendingPathComponent("S1", isDirectory: true), to: second)
        try ReturnedFolderEdits.editPlan(second) { plan in
            var sample = try XCTUnwrap(plan["sample"] as? [String: Any])
            sample["sampleName"] = "S2"
            plan["sample"] = sample
        }
        let refused = refusal(mixed)
        XCTAssertEqual(refused?.field, "pipeline.route")
        XCTAssertEqual(
            refused?.cause,
            "The samples S1 and S2 were planned with two alignment scorings, none and errorModel, so salmon weighed the "
                + "alignments of S2 with its error model and those of S1 without it. One result holds one route, so adopt them "
                + "as two batches.")
    }
}
