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
// - C and C' keep the same records, by their path with the analysis folder masked,
// - each record's text, with what changes between runs masked (`maskedRecordText`), has the SHA-256 pinned below on
//   C and on C', so a fact that both sides lose together fails too (BIO's review of M1, Fix 1).
//
// Every hash is taken from the bytes on disk as the route wrote them, read once, and never from a record read through
// `PortablePath` (B8). A record names absolute paths and times, so the hash of its raw bytes is kept and not pinned.
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
            XCTAssertEqual(side.maskedRecordHashes, TaxTriageParityRawBytes.pinnedRecords[parityCase] ?? [:], "\(label), side \(side.side)'s record hashes")
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
        /// The SHA-256 of `maskedRecordText` of the same bytes.
        let maskedSHA256: String
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
                    path: path,
                    maskedSHA256: TaxTriageParityRawBytes.hex(Data(TaxTriageParityRawBytes.maskedRecordText(bytes).utf8))
                ))
            }
            self.records = records.sorted { $0.key < $1.key }
        }

        /// Each payload's SHA-256 by `<sample>/<key>`.
        var payloadHashes: [String: String] {
            Dictionary(payloads.map { ("\($0.sample)/\($0.key)", $0.sha256) }, uniquingKeysWith: { first, _ in first })
        }

        /// Each record's masked SHA-256 by its key.
        var maskedRecordHashes: [String: String] {
            Dictionary(records.map { ($0.key, $0.maskedSHA256) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// A record's text with what changes between runs and hosts masked, so its hash can be pinned (BIO's review of M1,
    /// Fix 1). JSON is read and written again with sorted keys. In an object with `checksumSHA256`, the digest and
    /// `fileSize` become `<sha>` and `<size>` unless its `path` names a payload file, whose bytes are fixed. Wall and
    /// step times become `<seconds>`, `Runtime: <n>s` becomes `Runtime: <s>`, the project and case folders become
    /// `<root>/Project.lungfish` and `<case>/`, each UUID becomes `<uuid<n>>` by first appearance, an ISO time (the
    /// analysis folder's stamp too) becomes `<time>`, and the app version and macOS version become `<version>` and `<os>`.
    static func maskedRecordText(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
           let data = try? JSONSerialization.data(
               withJSONObject: maskedNode(object), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]
           ) {
            text = String(decoding: data, as: UTF8.self)
        }
        text = replacing(#"Runtime: [0-9.]+s"#, in: text, with: "Runtime: <s>")
        text = replacing(#"/[^"\s]*?/Project\.lungfish"#, in: text, with: "<root>/Project.lungfish")
        text = replacing(#"/[^"\s]*?/(?:X\d-bytes|X\d)/"#, in: text, with: "<case>/")
        text = numberingUUIDs(in: text)
        text = replacing(
            #"\d{4}-\d{2}-\d{2}[T ]\d{2}[\-:]\d{2}[\-:]\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:?\d{2})?"#, in: text, with: "<time>"
        )
        text = replacing(#"Lungfish \d{4}\.\d+\.\d+"#, in: text, with: "Lungfish <version>")
        return replacing(#"macOS \d+(?:\.\d+)*"#, in: text, with: "macOS <os>")
    }

    private static let fixedPayloadSuffixes = [".odr.txt", ".top_report.tsv", ".combined.gcfmap.tsv"]

    private static func maskedNode(_ node: Any) -> Any {
        if let array = node as? [Any] { return array.map(maskedNode) }
        guard let object = node as? [String: Any] else { return node }
        var masked = object.mapValues(maskedNode)
        let path = object["path"] as? String ?? ""
        if object["checksumSHA256"] != nil, !fixedPayloadSuffixes.contains(where: { path.hasSuffix($0) }) {
            masked["checksumSHA256"] = "<sha>"
            if object["fileSize"] != nil { masked["fileSize"] = "<size>" }
        }
        for key in ["wallTimeSeconds", "durationSeconds"] where object[key] != nil {
            masked[key] = "<seconds>"
        }
        return masked
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }

    private static func numberingUUIDs(in text: String) -> String {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var numbers: [String: Int] = [:]
        var result = ""
        var last = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let uuid = text[range].lowercased()
            let number = numbers[uuid] ?? numbers.count + 1
            numbers[uuid] = number
            result += text[last..<range.lowerBound] + "<uuid\(number)>"
            last = range.upperBound
        }
        return result + text[last...]
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

    /// Each case's record SHA-256 after `maskedRecordText` by the record's key, the same on C and C', taken at 0da983f38
    /// on the stand-in, whose records BIO found equal to those of 8aa9193e9 under the same masks.
    /// Lane 13.17 A49-ZSTD (efc9ff3da, 65cc1d641, landing 13) moved X1 to X8. In every moved record the only changed
    /// field is `managedToolLockSHA256`, the SHA-256 of third-party-tools-lock.json, 7e812c49 at 2d459d065 and
    /// ad8a24e9 since the lock names zstd and xz.
    static let pinnedRecords: [TaxTriageParityCase: [String: String]] = [
        .x1: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "e0d550813431c3096bb31e100299971a1203e51f2e246c181cfe6875577accb3",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "d30bc9c459ec5db39a44a725c86841fdc770d5b9df667abdd478f6de8460bc1e",
            "Project.lungfish/Imports/sarscov2-R1.lungfishfastq/derivatives/len-150-any-00000000.lungfishfastq/analyses-manifest.json":
                "5611608100d74f07efc953f90a871ca9e1f566118b36b09ea701b00cab4c8585",
        ],
        .x2: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "d5d601b78390473ab9d0d522055300f508b6ce1014e8bf9f16446a3fe3d4b9bd",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "108fac78319f7db6a2273ef05ee38956952328358d7dd4fc9f5003af4337df03",
            "Project.lungfish/Imports/sarscov2-pair.lungfishfastq/analyses-manifest.json":
                "5611608100d74f07efc953f90a871ca9e1f566118b36b09ea701b00cab4c8585",
        ],
        .x3: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "4a9f4c98afb6631f0d1532ead10a3252ceadc67d8a032518013d9ccd46c7e27c",
            "Project.lungfish/Analyses/<analysis>/negative-control/.lungfish-provenance.json":
                "7fe1dfbdc35a53ee4e8f7fb4478a31344ca6bbec661cab7c883298d5512cdfec",
            "Project.lungfish/Analyses/<analysis>/sarscov2-pair/.lungfish-provenance.json":
                "ce944526147992408574d26b955e5aa4369a53bd1a32b09da742695000de9185",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "8c0141f9355e808b46f16c1e5605ef2d7a6d928cfde48c42d4331fc855fcee12",
            "Project.lungfish/Imports/two-samples/negative-control.lungfishfastq/analyses-manifest.json":
                "138736c54fc2ddfa447d5cb959990857df0d5954edbe87e342955c3109968d15",
            "Project.lungfish/Imports/two-samples/sarscov2-pair.lungfishfastq/analyses-manifest.json":
                "138736c54fc2ddfa447d5cb959990857df0d5954edbe87e342955c3109968d15",
        ],
        .x4: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "9accda959b91f004cc062e1454bf42692b61521021a280f0523b2873982b722b",
            "Project.lungfish/Analyses/<analysis>/negative-control/.lungfish-provenance.json":
                "be59d031cfcac203918e7702f5883c75960b63bdf0da5f2d605920988a0bbe1e",
            "Project.lungfish/Analyses/<analysis>/sarscov2-pair/.lungfish-provenance.json":
                "ce944526147992408574d26b955e5aa4369a53bd1a32b09da742695000de9185",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "37ec7f95200041bef080cb13b3fb4296889b97d92c181ea341571716dbe50de1",
            "Project.lungfish/Imports/two-samples/sarscov2-pair.lungfishfastq/analyses-manifest.json":
                "043e3e7bbe5dfdbf602ae89d09a1bee3cf9727ddcf0e6bd94b06d3809a6e1e7f",
        ],
        .x5: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "7e61bdd8c3b9c54ba8840dc8c345dc0a38f0b6dad7d501a90e1f7ea4891e0394",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "108fac78319f7db6a2273ef05ee38956952328358d7dd4fc9f5003af4337df03",
            "Project.lungfish/Imports/sarscov2-pair.lungfishfastq/analyses-manifest.json":
                "9d72b0d6704ebfbfcbecb06ba0bd63ba162f482dc3d8333967b97109d75e93d2",
        ],
        .x6: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "ab781e7d5625353b4adbc35bfb473e0a49d95ce3b9a60ea36710e40c5577cc9c",
        ],
        .x7: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "afb57ff2fcf1849f35d8a02fbd98c09961de2be251001c6d96c726f0554663b5",
            "Project.lungfish/Analyses/<analysis>/taxtriage.sqlite.lungfish-provenance.json":
                "827ee5bde3b498c524d65f66ebfc8bc8a0a557328c795a4c9d6c929e4c9dc58b",
            "Project.lungfish/Imports/sarscov2-pair.lungfishfastq/analyses-manifest.json":
                "5611608100d74f07efc953f90a871ca9e1f566118b36b09ea701b00cab4c8585",
        ],
        .x8: [
            "Project.lungfish/Analyses/<analysis>/.lungfish-provenance.json":
                "36c106b3b935b5bd3da041a2b04fb7a14bd475a06c9ec4e126a2b535adcda189",
        ],
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
