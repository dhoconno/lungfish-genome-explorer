// LoosePairShortMateTests.swift - A loose R1 and R2 of different record counts are refused before a paired run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// S1 LOOSE-PAIR-SHORT-MATE, BIO ruling BIO-REACH row B. `taxtriage run --input R1 --input2 R2`, and a
/// loose pair that `esviritu detect` or the Kraken2 classify command runs as paired, handed mate files
/// of different record counts to fastp or kraken2, which pair by position and leave the extra reads out
/// with no word. Each plan (phase P0, before any folder exists or any tool starts) now reads both files
/// as the paired import does and refuses a mismatch, a record cut short and a cut gzip with the
/// interleaver's words and the input exit code 3. Every test stops at the plan, so none runs Nextflow,
/// EsViritu or kraken2, at the base or after the fix.
final class LoosePairShortMateTests: XCTestCase {

    var root: URL!
    var loose: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "loose-pair-short-mate").resolvingSymlinksInPath()
        loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Mismatched counts

    func testA100RecordR1WithA60RecordR2IsRefusedByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let r2 = try writeMates("S_R2.fastq", mate: 2, count: 60)

        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(
                refusal.words,
                "Paired FASTQ mates do not match. S_R1.fastq has 100 reads, but S_R2.fastq has 60. Nothing ran. Check that both files are complete or run each as single reads.",
                route.rawValue
            )
            XCTAssertEqual(refusal.exitCode, 3, route.rawValue)
        }
    }

    // MARK: - Files that cannot be parsed

    func testAnR2CutMidRecordIsRefusedWithTheReadersWordsByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let whole = ReadSetFixtures.fastq((1...99).map { "frag\($0)/2" })
        let cuts: [(name: String, tail: String, words: String)] = [
            ("in the sequence line", "@frag100/2\nACGTA", "Malformed FASTQ record 100 in S_R2.fastq: file ends inside the record"),
            ("in the quality line", "@frag100/2\nACGTACGTAC\n+\nIIII", "Malformed FASTQ record 100 in S_R2.fastq: sequence length 10 differs from quality length 4"),
        ]
        for cut in cuts {
            let r2 = loose.appendingPathComponent("S_R2.fastq")
            try Data((whole + cut.tail).utf8).write(to: r2)
            for route in Route.allCases {
                let refusal = await planRefusal(route, r1: r1, r2: r2)
                XCTAssertEqual(refusal.words, cut.words, "\(route.rawValue), cut \(cut.name)")
                XCTAssertEqual(refusal.exitCode, 3, "\(route.rawValue), cut \(cut.name)")
            }
        }
    }

    func testATruncatedGzipR2IsRefusedWithTheReadersWordsByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let plain = try writeMates("whole-R2.fastq", mate: 2, count: 100, in: root)
        let gzip = root.appendingPathComponent("whole-R2.fastq.gz")
        try await SystemToolProbe.gzip(plain, to: gzip)
        let compressed = try Data(contentsOf: gzip)
        let r2 = loose.appendingPathComponent("S_R2.fastq.gz")
        try compressed.prefix(compressed.count / 2).write(to: r2)

        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(refusal.words, "Cannot read S_R2.fastq.gz: gzip decompression failed (exit 1)", route.rawValue)
            XCTAssertEqual(refusal.exitCode, 3, route.rawValue)
        }
    }

    /// BIO review FIX-AB, should-fix 2. A whole gzip R2 that holds fewer records is refused by the count.
    func testAGzipR2WithFewerWholeRecordsIsRefusedByEveryLoosePairedRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let plain = try writeMates("short-R2.fastq", mate: 2, count: 60, in: root)
        let r2 = loose.appendingPathComponent("S_R2.fastq.gz")
        try await SystemToolProbe.gzip(plain, to: r2)

        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(
                refusal.words,
                "Paired FASTQ mates do not match. S_R1.fastq has 100 reads, but S_R2.fastq.gz has 60. Nothing ran. Check that both files are complete or run each as single reads.",
                route.rawValue
            )
            XCTAssertEqual(refusal.exitCode, 3, route.rawValue)
        }
    }

    // MARK: - Equal pairs (guard)

    func testEqualPairsPlainAndGzipPlanAsBefore() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let plainR2 = try writeMates("S_R2.fastq", mate: 2, count: 100)
        let gzipDirectory = root.appendingPathComponent("gzip", isDirectory: true)
        let gzipR1 = try writeMates("S_R1.fastq", mate: 1, count: 100, in: gzipDirectory)
        let gzipSource = try writeMates("whole-R2.fastq", mate: 2, count: 100, in: root)
        let gzipR2 = gzipDirectory.appendingPathComponent("S_R2.fastq.gz")
        try await SystemToolProbe.gzip(gzipSource, to: gzipR2)
        let output = root.appendingPathComponent("out", isDirectory: true)

        for (r1, r2) in [(r1, plainR2), (gzipR1, gzipR2)] {
            let name = r2.lastPathComponent

            for samplesheet in [false, true] {
                let taxTriage = try await taxTriageTool(r1: r1, r2: r2, samplesheet: samplesheet).plan(runRequest(output, batch: false), context: AnalysisRunPlanningContext(projectURL: nil))
                let samples = taxTriage.units.flatMap(\.value.config.samples)
                XCTAssertEqual(samples.map(\.sampleId), ["S1"], "\(name) samplesheet \(samplesheet)")
                XCTAssertEqual(samples.map(\.fastq1.path), [r1.path], "\(name) samplesheet \(samplesheet)")
                XCTAssertEqual(samples.map { $0.fastq2?.path }, [r2.path], "\(name) samplesheet \(samplesheet)")
            }

            for batch in [false, true] {
                let esViritu = try await esVirituTool(batch: batch).plan(runRequest(output, batch: batch, inputs: [r1, r2]), context: AnalysisRunPlanningContext(projectURL: nil))
                XCTAssertEqual(esViritu.units.map(\.value.inputs), [[r1, r2]], "\(name) batch \(batch)")
                XCTAssertEqual(esViritu.units.map(\.value.readFormat), [.paired], "\(name) batch \(batch)")

                let kraken2 = try await kraken2Tool(r1: r1, r2: r2, batch: batch).plan(runRequest(output, batch: batch), context: AnalysisRunPlanningContext(projectURL: nil))
                XCTAssertEqual(kraken2.units.map(\.value.inputURLs), [[r1, r2]], "\(name) batch \(batch)")
                XCTAssertEqual(kraken2.units.map(\.value.readFormat.format), [.paired], "\(name) batch \(batch)")
            }
        }
    }

    /// SAD:106 (FIX-B review SWIFT, SF1). The shapes real equal pairs have, which the guard above lacks:
    /// Casava names, a `+` line that repeats the header (SRA dumps) and an R1 of two gzip members joined
    /// (lanes merged with `cat`).
    func testRealShapedEqualPairsAreNotRefused() async throws {
        func fastq(_ range: ClosedRange<Int>, mate: Int, repeatsHeader: Bool) -> Data {
            let sequence = "ACGTNACGTACGTAC"
            let quality = "#" + String(repeating: "F", count: sequence.count - 2) + ":"
            let text = range.map { index -> String in
                let name = "A00123:45:HXXXXXXXX:1:1101:\(1000 + index):\(2000 + index) \(mate):N:0:ACGTACGT+TGCATGCA"
                let plus = repeatsHeader ? "+" + name : "+"
                return "@\(name)\n\(sequence)\n\(plus)\n\(quality)\n"
            }.joined()
            return Data(text.utf8)
        }
        let part1 = root.appendingPathComponent("part1.fastq")
        let part2 = root.appendingPathComponent("part2.fastq")
        try fastq(1...50, mate: 1, repeatsHeader: true).write(to: part1)
        try fastq(51...100, mate: 1, repeatsHeader: true).write(to: part2)
        let gzip1 = root.appendingPathComponent("part1.fastq.gz")
        let gzip2 = root.appendingPathComponent("part2.fastq.gz")
        try await SystemToolProbe.gzip(part1, to: gzip1)
        try await SystemToolProbe.gzip(part2, to: gzip2)
        let r1 = loose.appendingPathComponent("S_R1.fastq.gz")
        try (Data(contentsOf: gzip1) + Data(contentsOf: gzip2)).write(to: r1)
        let r2 = loose.appendingPathComponent("S_R2.fastq")
        try fastq(1...100, mate: 2, repeatsHeader: false).write(to: r2)

        XCTAssertEqual(try LooseMatePairCheck.refusal(r1: r1, r2: r2), nil)
    }

    /// FIX-B review SWIFT, SF2. A pair inside a `.lungfishfastq` folder was counted when the bundle was
    /// imported, so a run does not read it again. The loose control proves the same counts are refused
    /// outside a bundle.
    func testFilesInsideABundleAreNotCountedAgain() throws {
        let bundle = root.appendingPathComponent("S.lungfishfastq", isDirectory: true)
        let inR1 = try writeMates("S_R1.fastq", mate: 1, count: 100, in: bundle)
        let inR2 = try writeMates("S_R2.fastq", mate: 2, count: 60, in: bundle)
        XCTAssertEqual(try LooseMatePairCheck.refusal(r1: inR1, r2: inR2), nil)

        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let r2 = try writeMates("S_R2.fastq", mate: 2, count: 60)
        XCTAssertEqual(
            try LooseMatePairCheck.refusal(r1: r1, r2: r2),
            "Paired FASTQ mates do not match. S_R1.fastq has 100 reads, but S_R2.fastq has 60. Nothing ran. Check that both files are complete or run each as single reads."
        )
    }

    // MARK: - Routes

    /// Each setup that runs two loose files as one pair.
    enum Route: String, CaseIterable {
        case taxTriageInput2 = "taxtriage run --input --input2"
        case taxTriageSamplesheet = "taxtriage run --samplesheet"
        case esVirituPaired = "esviritu detect --paired"
        case esVirituBatch = "esviritu detect --batch"
        case kraken2Paired = "kraken2 classify --paired"
        case kraken2Batch = "kraken2 classify --batch"
    }

    /// The words and exit code of the plan's refusal of `r1` and `r2` on `route`, both nil when it plans.
    func planRefusal(_ route: Route, r1: URL, r2: URL) async -> (words: String?, exitCode: Int32?) {
        let output = root.appendingPathComponent("out", isDirectory: true)
        let context = AnalysisRunPlanningContext(projectURL: nil)
        do {
            switch route {
            case .taxTriageInput2, .taxTriageSamplesheet:
                let tool = taxTriageTool(r1: r1, r2: r2, samplesheet: route == .taxTriageSamplesheet)
                _ = try await tool.plan(runRequest(output, batch: false), context: context)
            case .esVirituPaired, .esVirituBatch:
                let batch = route == .esVirituBatch
                _ = try await esVirituTool(batch: batch).plan(runRequest(output, batch: batch, inputs: [r1, r2]), context: context)
            case .kraken2Paired, .kraken2Batch:
                let batch = route == .kraken2Batch
                _ = try await kraken2Tool(r1: r1, r2: r2, batch: batch).plan(runRequest(output, batch: batch), context: context)
            }
            return (nil, nil)
        } catch {
            return (error.localizedDescription, (error as? any AnalysisRunExitCoding)?.analysisRunExitCode)
        }
    }

    func runRequest(_ output: URL, batch: Bool, inputs: [URL] = []) -> AnalysisRunRequest {
        AnalysisRunRequest(inputs: inputs, destination: .directory(output), groupsSamples: batch, commandLine: ["lungfish-cli"])
    }

    /// `taxtriage run --input r1 --input2 r2 --sample S1`, or with `samplesheet` a samplesheet whose one
    /// row names sample `S1` with `r1` as `fastq_1` and `r2` as `fastq_2`.
    func taxTriageTool(r1: URL, r2: URL, samplesheet: Bool = false) -> TaxTriageAnalysisRunTool {
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try? FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let settings = TaxTriageConfig(samples: [], outputDirectory: root, kraken2DatabasePath: database, maxCpus: 2)
        var sheetPath: String?
        if samplesheet {
            let sheet = root.appendingPathComponent("samplesheet.csv")
            try? "sample,fastq_1,fastq_2,platform\nS1,\(r1.path),\(r2.path),ILLUMINA\n".write(to: sheet, atomically: true, encoding: .utf8)
            sheetPath = sheet.path
        }
        return TaxTriageAnalysisRunTool(
            request: samplesheet
                ? TaxTriageRunRequest(input: nil, samplesheet: sheetPath, settings: settings)
                : TaxTriageRunRequest(input: r1.path, input2: r2.path, sampleID: "S1", settings: settings),
            services: TaxTriageRunServices(materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]))
        )
    }

    func esVirituTool(batch: Bool) -> EsVirituAnalysisRunTool {
        let database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try? FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        return EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: batch ? nil : "S", pairedEnd: !batch, databasePath: database, threads: 1),
            groupsSamples: batch,
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
            installedDatabase: { nil }
        )
    }

    func kraken2Tool(r1: URL, r2: URL, batch: Bool) -> Kraken2AnalysisRunTool {
        var request = Kraken2RunRequest(inputArguments: [r1.path, r2.path], databaseName: "Viral", threads: 1)
        request.pairedEnd = !batch
        let databaseURL = root.appendingPathComponent("kraken2-viral", isDirectory: true)
        try? FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let database = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "2026.1", sizeBytes: 1, sizeOnDisk: 1, downloadURL: nil,
            description: "stand-in", collection: nil, path: databaseURL, isExternal: false, bookmarkData: nil,
            lastUpdated: Date(), status: .ready, recommendedRAM: 1
        )
        return Kraken2AnalysisRunTool(
            request: request,
            services: Kraken2RunServices(
                database: { $0 == "Viral" ? database : nil },
                availableDatabases: { [database] },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
                runPipeline: { _, _ in throw CancellationError() }
            )
        )
    }

    /// Writes `count` records named `frag<i>/<mate>` to `name` in `folder`, the loose folder by default.
    @discardableResult
    func writeMates(_ name: String, mate: Int, count: Int, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? loose!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq((1...count).map { "frag\($0)/\(mate)" }).utf8).write(to: url)
        return url
    }
}
