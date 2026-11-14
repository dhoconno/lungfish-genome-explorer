// RNASeqResultWriterTests.swift - The one writer of an RNA-seq result (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqObservation: @unchecked Sendable {
    var stageName = ""
    var stageHeldManifestAndRecord = false
    var resultExisted = true
}

final class RNASeqResultWriterTests: XCTestCase {
    var tempRoot: URL!
    var analyses: URL!
    var resultURL: URL { analyses.appendingPathComponent("seqc-c1.lungfishrnaseq", isDirectory: true) }
    let unsigned = ProvenanceWriter(signingProvider: nil)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-writer-\(UUID().uuidString)", isDirectory: true)
        analyses = tempRoot.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempRoot) }

    func envelope() -> ProvenanceEnvelope {
        ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
    }

    func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func names(in folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }

    /// Transcripts by the two runs, with each NumReads as quant.sf gives it.
    func quantTable() throws -> RNASeqCountTable {
        let columns: [[(String, Double)]] = try RNASeqFixtures.salmonRunIDs.map { run in
            let text = try String(contentsOf: RNASeqFixtures.salmonRun(run).appendingPathComponent("quant.sf"), encoding: .utf8)
            return text.split(separator: "\n").dropFirst().map { line in
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
                return (String(cells[0]), Double(cells[4])!)
            }
        }
        XCTAssertEqual(columns[0].map(\.0), columns[1].map(\.0))
        return RNASeqCountTable(sampleIDs: RNASeqFixtures.salmonRunIDs, rows: columns[0].indices.map {
            RNASeqCountTable.Row(id: columns[0][$0].0, counts: [columns[0][$0].1, columns[1][$0].1])
        })
    }

    func salmonRequest(_ table: RNASeqCountTable) -> RNASeqResultWriter.Request {
        let files = RNASeqFixtures.salmonRunIDs.flatMap { run in
            RNASeqFixtures.salmonFiles.map {
                RNASeqResultWriter.SourceFile(url: RNASeqFixtures.salmonRun(run).appendingPathComponent($0), relativePath: $0, sample: run, tool: "salmon")
            }
        }
        return RNASeqResultWriter.Request(
            name: "SEQC C1 salmon", modality: .bulk,
            origin: .init(kind: .imported, tool: "salmon", toolVersion: "2.11.0"),
            route: .init(id: "salmon-selective-alignment", tool: "salmon", toolVersion: "2.11.0", settings: ["unit": "NumReads"]),
            referenceSet: nil,
            samples: RNASeqFixtures.salmonRunIDs.map { RNASeqSampleRecord(id: $0, runs: [$0]) },
            genes: .ids(table.rows.map(\.id)),
            counts: [.init(rows: .transcript, column: .default, unit: .estimated, table: table)],
            sourceFiles: files, notHost: [])
    }

    func testRoundTripOnTheTwoSalmonRuns() throws {
        let table = try quantTable()
        let seen = RNASeqObservation()
        let url = resultURL
        let writer = RNASeqResultWriter(provenanceWriter: unsigned, stageObserver: { stage, stageURL in
            guard stage == .recordWritten else { return }
            seen.stageName = stageURL.lastPathComponent
            let held = try FileManager.default.contentsOfDirectory(atPath: stageURL.path)
            seen.stageHeldManifestAndRecord = held.contains("rnaseq-result.json") && held.contains(ProvenanceWriter.provenanceFilename)
            seen.resultExisted = FileManager.default.fileExists(atPath: url.path)
        })
        let written = try writer.write(salmonRequest(table), to: url, envelope: envelope())
        XCTAssertEqual(written.standardizedFileURL, url.standardizedFileURL)
        XCTAssertTrue(seen.stageName.hasPrefix(".seqc-c1.lungfishrnaseq.creating-"), seen.stageName)
        XCTAssertTrue(seen.stageHeldManifestAndRecord, "at the rename the stage holds the manifest and the root record")
        XCTAssertFalse(seen.resultExisted)
        XCTAssertEqual(try names(in: analyses), ["seqc-c1.lungfishrnaseq"])

        let result = try RNASeqResultBundle.load(from: url)
        XCTAssertEqual(result.counts.map(\.table), [table])
        XCTAssertEqual(result.manifest.counts.map(\.rows), [.transcript])
        XCTAssertEqual(result.manifest.counts.map(\.unit), [.estimated])
        XCTAssertEqual(result.samples.map(\.sourceFolder), RNASeqFixtures.salmonRunIDs)
        XCTAssertEqual(result.manifest.sourceFiles.count, 8)
        for entry in result.manifest.sourceFiles {
            let original = RNASeqFixtures.salmonRun(entry.sample).appendingPathComponent(String(entry.path.dropFirst("source/\(entry.sample)/".count)))
            let bytes = try Data(contentsOf: url.appendingPathComponent(entry.path))
            XCTAssertEqual(bytes, try Data(contentsOf: original), entry.path)
            XCTAssertEqual(entry.sha256, sha256(bytes))
            XCTAssertEqual(entry.size, Int64(bytes.count))
        }
        XCTAssertTrue(try RNASeqResultBundle.verifyChecksums(of: url).isEmpty)
    }

    func testAThrowAfterTheCopyLeavesNoStageAndNoResult() throws {
        struct Boom: Error {}
        let writer = RNASeqResultWriter(provenanceWriter: unsigned, stageObserver: { stage, _ in
            if stage == .sourcesCopied { throw Boom() }
        })
        XCTAssertThrowsError(try writer.write(salmonRequest(quantTable()), to: resultURL, envelope: envelope())) {
            XCTAssertTrue($0 is Boom)
        }
        XCTAssertEqual(try names(in: analyses), [])
    }

    func testACancelRemovesTheStage() async throws {
        let writer = RNASeqResultWriter(provenanceWriter: unsigned, stageObserver: { stage, _ in
            if stage == .sourcesCopied { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let request = try salmonRequest(quantTable())
        let url = resultURL
        let env = envelope()
        let outcome = await Task { try writer.write(request, to: url, envelope: env) }.result
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled write must throw") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertEqual(try names(in: analyses), [])
    }

    func testTheQualityTableIsWrittenAndTheManifestHashesIt() throws {
        let runs = RNASeqFixtures.salmonRunIDs
        let table = try quantTable()
        let writer = RNASeqResultWriter(provenanceWriter: unsigned)
        let plain = analyses.appendingPathComponent("plain.lungfishrnaseq", isDirectory: true)
        try writer.write(salmonRequest(table), to: plain, envelope: envelope())
        XCTAssertNil(try RNASeqResultBundle.load(from: plain).manifest.quality)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent("quality").path))

        var request = salmonRequest(table)
        let quality = RNASeqQualityTable(
            columns: ["library_type", "num_processed", "percent_mapped"],
            rows: [
                RNASeqQualityTable.Row(sample: runs[0], values: ["IU", "1000", nil]),
                RNASeqQualityTable.Row(sample: runs[1], values: ["IU", "2000", "55.5"]),
            ])
        request.quality = quality
        try writer.write(request, to: resultURL, envelope: envelope())
        let file = resultURL.appendingPathComponent("quality/samples.quality.tsv")
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            "sample_id\tlibrary_type\tnum_processed\tpercent_mapped\n\(runs[0])\tIU\t1000\t\n\(runs[1])\tIU\t2000\t55.5\n")
        let result = try RNASeqResultBundle.load(from: resultURL)
        XCTAssertEqual(result.manifest.quality, RNASeqResultManifest.FileEntry(path: "quality/samples.quality.tsv", sha256: sha256(bytes)))
        XCTAssertEqual(result.quality, quality)
        XCTAssertTrue(try RNASeqResultBundle.verifyChecksums(of: resultURL).isEmpty)
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: resultURL).map(\.path), ["quality/samples.quality.tsv"])
    }

    func testAQualityRowForASampleThatIsNotInTheResultIsRefusedAndNothingIsWritten() throws {
        var request = try salmonRequest(quantTable())
        request.quality = RNASeqQualityTable(
            columns: ["library_type"], rows: [RNASeqQualityTable.Row(sample: "SRR000000", values: ["IU"])])
        XCTAssertThrowsError(try RNASeqResultWriter(provenanceWriter: unsigned).write(request, to: resultURL, envelope: envelope())) {
            XCTAssertTrue($0.localizedDescription.contains("SRR000000"), $0.localizedDescription)
        }
        XCTAssertEqual(try names(in: analyses), [])
    }
}
