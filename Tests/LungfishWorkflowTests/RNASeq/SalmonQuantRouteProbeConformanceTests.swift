// SalmonQuantRouteProbeConformanceTests.swift - the truth probe of rnaseq quant with real salmon (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The truth probe (SCOPE-AND-DELIVERY `:90`). The quant route's counts equal salmon 2.11.0 run directly with the argv the
/// route recorded, on the same index: `quant.sf` byte-equal and gene sums equal. The input is
/// `Tests/Fixtures/rnaseq/salmon-probe-c1`, the first 6,000 pairs of SRR896663 with ERCC92's sequences and GTF as the
/// set's genome and annotation. The set and the index are built by their owners, the index with the key salmon 2.11.0,
/// k 31 and no decoys. salmon and gffread are the rna-seq pack's in the managed storage root, and the test skips through
/// `ToolAvailability` when the root lacks them. `SalmonQuantRouteTests` is the stand-in beside it.
final class SalmonQuantRouteProbeConformanceTests: XCTestCase {
    var base: URL!

    static let linuxRoute = "Run salmon on Linux and import its folders with lungfish-cli import rnaseq"
    static var probe: URL { RNASeqFixtures.root.appendingPathComponent("salmon-probe-c1", isDirectory: true) }

    override func setUpWithError() throws {
        base = try TestTempDirectory.make(prefix: "salmon-quant-probe")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(base)
    }

    /// The pack's executable in the managed storage root, or a skip.
    func packTool(_ environment: String, _ name: String) throws -> URL {
        let root = ManagedStorageConfigStore().currentLocation().rootURL
        let url = root.appendingPathComponent("conda/envs/\(environment)/bin/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            try ToolAvailability.skipOrFail("\(name) of the rna-seq pack is not in \(root.path)")
        }
        return url
    }

    static func rows(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The probe's two mates as one interleaved file, record by record, as `import fastq` keeps a pair.
    static func interleaved() throws -> String {
        func lines(_ name: String) throws -> [Substring] {
            try GzipInputStream(url: probe.appendingPathComponent(name)).readAllSync().split(separator: "\n")
        }
        let one = try lines("SRR896663_1.fastq.gz"), two = try lines("SRR896663_2.fastq.gz")
        XCTAssertEqual(one.count, 24_000, "6,000 records of four lines in each mate")
        XCTAssertEqual(one.count, two.count)
        var text = ""
        for start in stride(from: 0, to: min(one.count, two.count), by: 4) {
            text += one[start..<start + 4].joined(separator: "\n") + "\n" + two[start..<start + 4].joined(separator: "\n") + "\n"
        }
        return text
    }

    /// One pair bundle in a new project, named A_1 as C1's stage names SRR896663.
    func probeBundle(in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("Imports/A_1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq")
        try Data(try Self.interleaved().utf8).write(to: reads)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected)), for: reads)
        return bundle
    }

    /// The results of the lge_quant stages of C1 and C5, given as `LUNGFISH_RNASEQ_QUANT_RESULTS` (paths joined by `:`) on
    /// the one command that runs this test: each record is complete, with one salmon step a sample and no trim step.
    func testEachStageResultsRecordIsComplete() throws {
        guard let paths = ProcessInfo.processInfo.environment["LUNGFISH_RNASEQ_QUANT_RESULTS"], !paths.isEmpty else {
            throw XCTSkip("LUNGFISH_RNASEQ_QUANT_RESULTS names no stage result")
        }
        for path in paths.split(separator: ":").map(String.init) {
            let result = URL(fileURLWithPath: path, isDirectory: true)
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result), "\(path) has a record")
            XCTAssertEqual(ProvenanceCompleteness.issues(in: envelope), [], path)
            let manifest = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: result.appendingPathComponent("rnaseq-result.json")))
                    as? [String: Any])
            // The manifest's `samples` is the file reference {"path": "samples.tsv", "sha256": ...}, one row a sample after the
            // header. The test read it as an array and stopped on every real result (C1, 2026-11-15, FIX-RS-QUANT-2 item 3).
            let table = try XCTUnwrap(
                (manifest["samples"] as? [String: Any])?["path"] as? String, "\(path) names its samples table")
            let samples = try String(contentsOf: result.appendingPathComponent(table), encoding: .utf8)
                .split(whereSeparator: \.isNewline).dropFirst()
            XCTAssertFalse(samples.isEmpty, "\(path) lists its samples")
            XCTAssertEqual(envelope.steps.filter { $0.toolName == "salmon" }.count, samples.count, path)
            XCTAssertFalse(envelope.steps.contains { $0.toolName == "trim_galore" }, path)
        }
    }

    func testTheQuantsCountsEqualSalmonRunDirectlyWithTheRecordedArgv() async throws {
        let salmon = try packTool("salmon", "salmon")
        _ = try packTool("gffread", "gffread")
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = ProvenanceWriter(signingProvider: nil)
        let host = RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
        let roomy: RunFitPreflight.FreeSpaceReader = { _ in 1_000_000_000_000 }
        let set = try await ReferenceSetOwner(storageRoot: root, provenanceWriter: writer).build(ReferenceSetRequest(
            name: "ERCC92 probe", species: "Synthetic construct", assemblyName: "ERCC92", annotationSource: "ERCC",
            annotationRelease: "92", genome: Self.probe.appendingPathComponent("ERCC92.fa"),
            annotation: Self.probe.appendingPathComponent("ERCC92.gtf"), extras: [], layout: .lge))
        let cache = SalmonIndexCache(storageRoot: root, provenanceWriter: writer, host: host, freeSpace: roomy)
        _ = try await cache.ensure(SalmonIndexRequest(setID: set.manifest.id, k: 31, decoys: .none), linuxRoute: Self.linuxRoute)

        let project = base.appendingPathComponent("Probe.lungfish", isDirectory: true)
        let bundle = try probeBundle(in: project)
        let outcome = try await SalmonQuantRoute(storageRoot: root, provenanceWriter: writer, host: host, freeSpace: roomy).run(
            SalmonQuantRequest(
                bundles: [bundle], projectURL: project, name: "Probe", setID: set.manifest.id, k: 31, decoys: .none, threads: 2,
                argv: ["lungfish-cli", "rnaseq", "quant"]),
            linuxRoute: Self.linuxRoute)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: outcome.resultURL), "the result has a record")
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "salmon" }, "one salmon step")
        XCTAssertEqual(step.toolVersion, "2.11.0")

        // salmon run directly: the recorded argv, with the probe's own two files and a folder of its own.
        var argv = Array(step.argv.dropFirst())
        for (flag, value) in [
            ("-1", Self.probe.appendingPathComponent("SRR896663_1.fastq.gz").path),
            ("-2", Self.probe.appendingPathComponent("SRR896663_2.fastq.gz").path),
            ("-o", base.appendingPathComponent("direct", isDirectory: true).path),
        ] {
            let at = try XCTUnwrap(argv.firstIndex(of: flag), "the recorded argv has \(flag)")
            argv[at + 1] = value
        }
        XCTAssertEqual(Array(argv.prefix(5)), ["quant", "-i", argv[2], "-l", "A"])
        XCTAssertFalse(argv.contains { $0.hasSuffix("Bias") }, "no bias flag: \(argv)")
        let ran = try ProcessRunner.run(salmon, argv)
        XCTAssertEqual(ran.status, 0, ran.stderr)

        let direct = base.appendingPathComponent("direct/quant.sf")
        let ours = outcome.resultURL.appendingPathComponent("source/A_1/quant.sf")
        XCTAssertEqual(try Data(contentsOf: ours), try Data(contentsOf: direct), "quant.sf of rnaseq quant equals salmon's own")

        var gene: [String: String] = [:]
        for row in try Self.rows(set.url.appendingPathComponent(set.manifest.derived.transcriptGenes.path)).dropFirst() {
            gene[row[0]] = row[1]
        }
        var sums: [String: Double] = [:]
        for row in try Self.rows(direct).dropFirst() {
            sums[try XCTUnwrap(gene[row[0]], "\(row[0]) has a gene"), default: 0] += try XCTUnwrap(Double(row[4]))
        }
        XCTAssertGreaterThan(sums.values.reduce(0, +), 0, "the probe's reads reach ERCC92")
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: outcome.resultURL.appendingPathComponent("rnaseq-result.json")))
                as? [String: Any])
        let counts = try XCTUnwrap(manifest["counts"] as? [[String: Any]])
        let path = try XCTUnwrap(counts.compactMap { $0["path"] as? String }.first { $0.hasSuffix("genes.counts.tsv") })
        let table = try Self.rows(outcome.resultURL.appendingPathComponent(path))
        XCTAssertEqual(table.first, ["feature_id", "A_1"])
        XCTAssertEqual(Set(table.dropFirst().map { $0[0] }), Set(sums.keys))
        for row in table.dropFirst() {
            XCTAssertEqual(try XCTUnwrap(Double(row[1])), sums[row[0]] ?? -1, accuracy: 1e-9, "gene \(row[0])")
        }
    }
}
