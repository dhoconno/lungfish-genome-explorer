// TaxTriageCLIGUIParityReplayTests+RawBytes.swift - Sides C and C' of each TaxTriage parity case, by the bytes they wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.01 M1, BIO B8 and PLAN X11, the pin that lands before K1 deletes the legacy route. Each case runs
// sides C and C' alone on its own stand-in engine, side C through the route the Tools menu launch takes and side C'
// through the argv C's root record names (TaxTriageCLIGUIParityReplayTests+RouteC.swift). The pin holds that
//
// - C against C' and C' against C declare nothing, no fixed fact on either side and no folder or record difference
//   either way (2.7 T2),
// - each sample's payload files have the same SHA-256 on C and C', and the hashes pinned below, taken at 8aa9193e9,
// - C and C' keep the same records, by their path with the analysis folder masked.
//
// Every hash is taken from the bytes on disk as the route wrote them, read once, and never from a record read through
// `PortablePath` (B8). A record names absolute paths and times, so its hash is kept and not pinned.
// `LUNGFISH_PARITY_DUMP=<folder>` writes those same bytes into `<folder>/raw-bytes/<case>/`: `records/<side>/<path>`,
// `payloads/<side>/<sample>/<key>` and `hashes.tsv` (side, what, sample, key, sha256, size, path).

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriageCLIGUIParityReplayTests {
    func testRawBytesOfX1OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x1)
    }

    func testRawBytesOfX2OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x2)
    }

    func testRawBytesOfX3OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x3)
    }

    func testRawBytesOfX4OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x4)
    }

    func testRawBytesOfX5OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x5)
    }

    func testRawBytesOfX6OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x6)
    }

    func testRawBytesOfX7OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x7)
    }

    func testRawBytesOfX8OnSidesCAndCPrime() async throws {
        try await assertRawBytes(.x8)
    }

    /// Runs sides C and C' of `parityCase` and holds the pin of the file's header.
    func assertRawBytes(_ parityCase: TaxTriageParityCase) async throws {
        if parityCase.materializesVirtualBundle {
            _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        }
        let caseRoot = scratch.appendingPathComponent("\(parityCase.rawValue)-bytes", isDirectory: true)
        try? FileManager.default.removeItem(at: caseRoot)
        let engine = try makeStandInEngine(in: caseRoot, for: parityCase)
        let harness = TaxTriageParityHarness(testCase: self, cliBinary: cliBinary)
        func root(_ side: TaxTriageParitySide) -> URL {
            caseRoot.appendingPathComponent(side.folderName, isDirectory: true)
        }
        let projectC = try parityCase.makeProject(in: root(.c))
        let pristine = caseRoot.appendingPathComponent("pristine", isDirectory: true)
            .appendingPathComponent(projectC.lastPathComponent, isDirectory: true)
        for copy in [root(.cPrime).appendingPathComponent(projectC.lastPathComponent, isDirectory: true), pristine] {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: projectC, to: copy)
        }

        var runC = parityCase.runsGUISide
            ? try await harness.runGUISide(parityCase, side: .c, root: root(.c), engine: engine)
            : await harness.runRoutedSide(parityCase, root: root(.c), engine: engine)
        if parityCase.rebuildsAfterTheCleanup { runC = await harness.rebuildAfterTheCleanup(runC) }
        var runCPrime = await harness.runRecordedArgv(of: runC, parityCase, root: root(.cPrime), engine: engine)
        if parityCase.rebuildsAfterTheCleanup { runCPrime = await harness.rebuildAfterTheCleanup(runCPrime) }
        let runs = [runC, runCPrime]

        var sides: [TaxTriageParityRawBytes.Side] = []
        for run in runs {
            sides.append(try TaxTriageParityRawBytes.Side(run, parityCase: parityCase))
        }
        try TaxTriageParityRawBytes.dumpIfRequested(parityCase, sides: sides)

        let label = parityCase.rawValue
        for run in runs {
            let facts = try harness.fixedFactViolations(parityCase, run: run, engine: engine, pristineProject: pristine)
            XCTAssertEqual(facts.map(\.description), [], "\(label), side \(run.side) holds every fixed fact")
        }
        for (reference, candidate) in [(runC, runCPrime), (runCPrime, runC)] {
            let found = try TaxTriageParityComparison.differences(
                reference: reference, candidate: candidate, bundlePaths: parityCase.bundlePaths
            )
            XCTAssertEqual(found.map(\.description), [], "\(label), \(reference.side) against \(candidate.side) declares nothing")
        }
        let payloadDifferences = TaxTriageParityPayloads.differences(
            reference: sides[0].payloads, .c, candidate: sides[1].payloads, .cPrime
        )
        XCTAssertEqual(payloadDifferences.map(\.description), [], "\(label), each payload's SHA-256 is equal on C and C'")
        for side in sides {
            XCTAssertEqual(side.payloadHashes, TaxTriageParityRawBytes.pinnedPayloads[parityCase] ?? [:], "\(label), side \(side.side)'s payload hashes")
            XCTAssertFalse(side.records.isEmpty || side.records.contains { $0.size == 0 }, "\(label), side \(side.side) keeps its records")
        }
        XCTAssertEqual(sides[0].records.map(\.key), sides[1].records.map(\.key), "\(label), C and C' keep the same records")
    }
}

/// The raw bytes of sides C and C' of a TaxTriage parity case (lane 12.01 M1, B8).
enum TaxTriageParityRawBytes {
    /// One file of a side, by the hash of its bytes as the route wrote them.
    struct File {
        /// `record` or the payload's kind.
        let what: String
        /// The sample whose folder or name holds the file, `run` for the analysis folder's own records and `bundle`
        /// for a record of the project's bundles.
        let sample: String
        /// The path below the side root, with the analysis folder masked as `<analysis>`. A payload's key is
        /// `<sample>/<key>` of `TaxTriageParityPayload`.
        let key: String
        let sha256: String
        let size: Int
        /// The path below the side root.
        let path: String
    }

    /// What one side wrote.
    struct Side {
        let side: TaxTriageParitySide
        let root: URL
        let records: [File]
        let payloads: [TaxTriageParityPayload]

        /// Reads every record and source manifest below the side root once, as Evidence.write copies them, and
        /// each sample's payload files (TaxTriageParityPayloads).
        init(_ run: TaxTriageParitySideRun, parityCase: TaxTriageParityCase) throws {
            side = run.side
            root = run.root
            payloads = try TaxTriageParityPayloads.payloads(of: run, parityCase: parityCase, samtools: nil)
            let samples = TaxTriageParityPayloads.sampleNames(of: run, parityCase: parityCase)
            let manifests = parityCase.bundlePaths.map { "\(ClassifierParityFixtures.projectName)/\($0)/\(AnalysisManifest.filename)" }
            var records: [File] = []
            for path in Set(TaxTriageParityComparison.Rules.recordPaths(under: run.root) + manifests).sorted() {
                let file = run.root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let bytes = try Data(contentsOf: file)
                let key = TaxTriageParityRawBytes.masked(path, analysisPath: run.analysisPath)
                records.append(File(
                    what: "record",
                    sample: TaxTriageParityRawBytes.sample(of: key, samples: samples),
                    key: key,
                    sha256: TaxTriageParityRawBytes.hex(bytes),
                    size: bytes.count,
                    path: path
                ))
            }
            self.records = records.sorted { $0.key < $1.key }
        }

        /// Each payload's SHA-256 by `<sample>/<key>`.
        var payloadHashes: [String: String] {
            Dictionary(payloads.map { ("\($0.sample)/\($0.key)", $0.sha256) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// `path` with the side's analysis folder masked, so C and C' pair their records.
    static func masked(_ path: String, analysisPath: String?) -> String {
        guard let analysisPath, path == analysisPath || path.hasPrefix(analysisPath + "/") else { return path }
        return "\(ClassifierParityFixtures.projectName)/Analyses/<analysis>" + path.dropFirst(analysisPath.count)
    }

    /// The sample a record belongs to, by the folder below the analysis folder that names it.
    static func sample(of key: String, samples: [String]) -> String {
        let prefix = "\(ClassifierParityFixtures.projectName)/Analyses/<analysis>/"
        guard key.hasPrefix(prefix) else { return "bundle" }
        let rest = key.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard rest.count > 1, let folder = rest.first, samples.contains(folder) else { return "run" }
        return folder
    }

    static func hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes each side's records and payload files as they are on disk, with `hashes.tsv`, into
    /// `<LUNGFISH_PARITY_DUMP>/raw-bytes/<case>/`, replacing an earlier dump of the case. Nothing is written without it.
    @MainActor
    static func dumpIfRequested(_ parityCase: TaxTriageParityCase, sides: [Side]) throws {
        guard let dump = TaxTriageParityHarness.dumpFolder else { return }
        let folder = dump.appendingPathComponent("raw-bytes/\(parityCase.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = ["side\twhat\tsample\tkey\tsha256\tsize\tpath"]
        for side in sides {
            let sideFolder = folder.appendingPathComponent(side.side.folderName, isDirectory: true)
            for record in side.records {
                try copy(side.root.appendingPathComponent(record.path), to: sideFolder.appendingPathComponent("records/\(record.path)"))
                lines.append([side.side.rawValue, record.what, record.sample, record.key, record.sha256, String(record.size), record.path].joined(separator: "\t"))
            }
            for payload in side.payloads {
                try copy(side.root.appendingPathComponent(payload.path), to: sideFolder.appendingPathComponent("payloads/\(payload.sample)/\(payload.key)"))
                lines.append([
                    side.side.rawValue, payload.kind.rawValue, payload.sample, "\(payload.sample)/\(payload.key)",
                    payload.sha256, String(payload.size), payload.path,
                ].joined(separator: "\t"))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("hashes.tsv"), atomically: true, encoding: .utf8)
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Each case's payload SHA-256 by `<sample>/<key>`, the same on C and C', taken at 8aa9193e9 on the stand-in. X4's
    /// negative control fails and keeps no payload, and X6's cancelled run keeps none.
    static let pinnedPayloads: [TaxTriageParityCase: [String: String]] = [
        .x1: sample("len-150-any-00000000", report: "47fc7730ad43bfbf5f051cb6e7aae677382db2aaa15eda704766f04cee876e6d"),
        .x2: sample("sarscov2-pair", report: pairReport),
        .x3: sample("sarscov2-pair", report: pairReport).merging(sample("negative-control", report: negativeControlReport)) { $1 },
        .x4: sample("sarscov2-pair", report: pairReport),
        .x5: sample("sarscov2-pair", report: pairReport),
        .x7: sample("sarscov2-pair", report: "92a3c5a349c279173d720fbb1b102717774d1a091e7615df8d00450a3b31c2a3"),
        .x8: sample("merge", report: "bf8f3cffde6e8c0d75b29729628535615a0c6e02404c3028488cbcf757661a70")
            .merging(sample("negative-control", report: negativeControlReport)) { $1 },
    ]

    private static let pairReport = "685b9348228b3f3dd060f4ec7197a0f800dc5a88adb456447daad90e09d3e432"
    private static let negativeControlReport = "317e8d637fcfa059e7573caa441b5f75cbd229d70d139cf9c8d0289f98dac4cc"

    /// A sample's organism report, with the stand-in's accession map and top report, which every sample shares.
    private static func sample(_ name: String, report: String) -> [String: String] {
        [
            "\(name)/report/\(name).odr.txt": report,
            "\(name)/combine/\(name).combined.gcfmap.tsv": "9ac45764c0fcbae3dadd59eb923a757bc1b79b6a135f611af64b320928fb6994",
            "\(name)/top/\(name).top_report.tsv": "11fc38f85ab28fed056dfd106cf0ba802571de52bfa74b3073e58fb33adc78f5",
        ]
    }
}
