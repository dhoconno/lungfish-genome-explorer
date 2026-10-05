// KrakenReadSetConformanceTests.swift - The real kraken2 classifies staged single reads exactly as a single-end run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Pins the empty-mate staging (decisions 1 and 2) against the managed
/// kraken2 and the installed Viral database. The fixture is
/// Tests/Fixtures/read-pairing/kraken2: bbmerge of sarscov2 test_1 and test_2
/// gives 77 merged reads and 23 unmerged pairs. A kraken2 upgrade that handles
/// an empty mate differently turns this suite red before release. It is a
/// real-tool suite, so its name puts it in the conformance tier, and it skips
/// without the tool or the database.
final class KrakenReadSetConformanceTests: XCTestCase {

    private var work: URL!

    override func setUpWithError() throws {
        work = try ConformanceFixtures.tempDir("kraken-read-set")
    }

    override func tearDown() {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    func testStagedSingleReadsMatchASingleEndRunAndTheCombinedRunSumsTheParts() async throws {
        let database = try await requireKraken2AndViralDatabase()
        let fixture = ConformanceFixtures.fixture("read-pairing/kraken2")
        let bundle = try makeMergeDerivative(from: fixture)
        let merged = bundle.appendingPathComponent("merged.fastq")
        let r1 = bundle.appendingPathComponent("unmerged_R1.fastq")
        let r2 = bundle.appendingPathComponent("unmerged_R2.fastq")

        // Plain runs: the merged reads single-end, the pairs --paired.
        let single = try await kraken2(["--report-minimizer-data"], inputs: [merged.path], database: database, name: "single")
        let pairs = try await kraken2(["--report-minimizer-data", "--paired"], inputs: [r1.path, r2.path], database: database, name: "pairs")

        // Singles only through the staging: the kreport is byte for byte the single-end one.
        let mate = work.appendingPathComponent("merged.emptymate.fastq")
        XCTAssertEqual(try ClassificationPipeline.writeEmptyMate(of: merged, to: mate), 77)
        let staged = try await kraken2(["--report-minimizer-data", "--paired"], inputs: [merged.path, mate.path], database: database, name: "staged")
        XCTAssertEqual(try Data(contentsOf: staged.report), try Data(contentsOf: single.report))
        XCTAssertEqual(try perReadCalls(staged.output), try perReadCalls(single.output))

        // One combined run through the pipeline, planned from the bundle.
        var config = ClassificationConfig(
            inputFiles: [bundle], isPairedEnd: false, databaseName: "Viral", databasePath: database,
            confidence: 0.2, minimumHitGroups: 2, outputDirectory: work.appendingPathComponent("combined", isDirectory: true)
        )
        config.originalInputFiles = [bundle]
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle, materializedInputs: [],
            materializationDirectory: config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
        )
        XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config))
        let result = try await ClassificationPipeline.shared.profile(config: config)

        XCTAssertEqual(result.fragmentComposition, ClassificationFragmentComposition(
            pairedFragments: 23, mergedReads: 77, orphanReads: 0, singleEndReads: 0
        ))
        XCTAssertEqual(result.readPairingContract, 1)
        XCTAssertEqual(try ClassificationPipeline.lineCount(of: result.outputURL), 100, "one per-read line per fragment")
        XCTAssertEqual(result.profileOutcome.state, .completed, "Bracken runs on the combined kreport")

        // The staged single reads get the calls of the single-end run.
        let combinedCalls = try perReadCalls(result.outputURL)
        let singleCalls = try perReadCalls(single.output)
        XCTAssertEqual(combinedCalls.filter { singleCalls.contains($0) }.count, 77)
        XCTAssertEqual(Set(combinedCalls), Set(singleCalls).union(try perReadCalls(pairs.output)))

        // Clade, direct and minimizer columns are the sum of the two plain runs.
        let combined = try kreportCounts(result.reportURL)
        let summed = try kreportCounts(single.report).merging(try kreportCounts(pairs.report)) { a, b in
            zip(a, b).map { $0 + $1 }
        }
        XCTAssertEqual(combined, summed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.emptyMateURL(for: merged.standardizedFileURL).path))
    }

    /// Final review S1. `conda classify --paired R1 R2 --unpaired S` reads the
    /// same reads whether the files are plain, gzip or a mix. The kraken2
    /// wrapper takes the compression of R1 for every input, so each file of
    /// single reads and its staged mate are given that compression. Every run
    /// counts 23 pairs and 77 merged reads, passes the fragment guard and
    /// writes the report and the calls of the plain run.
    func testGzipAndMixedLooseFilesClassifyAsThePlainFilesDo() async throws {
        let database = try await requireKraken2AndViralDatabase()
        let fixture = ConformanceFixtures.fixture("read-pairing/kraken2")
        let plain = ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"].map { fixture.appendingPathComponent($0) }
        let gzipped = try plain.map { file -> URL in
            let copy = work.appendingPathComponent(file.lastPathComponent + ".gz")
            _ = try gzipCompressFASTQ(sourceURL: file, outputURL: copy, failureDescription: "the test copy of")
            return copy
        }
        let runs: [(name: String, files: [URL])] = [
            ("plain", plain),
            ("gzip", gzipped),
            ("gzip-pair", [gzipped[0], gzipped[1], plain[2]]),
            ("gzip-single-reads", [plain[0], plain[1], gzipped[2]]),
        ]

        var reports: [String: Data] = [:]
        var calls: [String: [String]] = [:]
        for run in runs {
            var config = ClassificationConfig(
                inputFiles: Array(run.files.prefix(2)), isPairedEnd: true, databaseName: "Viral", databasePath: database,
                confidence: 0.2, minimumHitGroups: 2, outputDirectory: work.appendingPathComponent(run.name, isDirectory: true)
            )
            config.originalInputFiles = Array(run.files.prefix(2))
            let plan = try KrakenReadSetPlanner.plan(
                r1: run.files[0], r2: run.files[1], singleReads: [run.files[2]],
                materializationDirectory: config.outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
            )
            XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config, recordedWithAuto: false), run.name)
            let result: ClassificationResult
            do {
                result = try await ClassificationPipeline.shared.profile(config: config)
            } catch {
                XCTFail("\(run.name): \(error.localizedDescription)")
                continue
            }
            XCTAssertEqual(result.fragmentComposition?.pairedFragments, 23, run.name)
            XCTAssertEqual(result.fragmentComposition?.singleReadFragments, 77, run.name)
            XCTAssertEqual(try ClassificationPipeline.lineCount(of: result.outputURL), 100, run.name)
            reports[run.name] = try Data(contentsOf: result.reportURL)
            calls[run.name] = try perReadCalls(result.outputURL)
        }
        for run in runs.dropFirst() {
            XCTAssertNotNil(reports[run.name], run.name)
            XCTAssertEqual(reports[run.name], reports["plain"], "\(run.name) writes the report of the plain run")
            XCTAssertEqual(calls[run.name], calls["plain"], "\(run.name) makes the calls of the plain run")
        }
    }

    /// Final review N1. The name the pinned kraken2 writes for each fragment,
    /// which extraction and BLAST verification match their reads by. A
    /// paired run, and so a merged read staged beside an empty mate, drops a
    /// final /1 or /2 once from a name longer than two characters
    /// (TrimPairInfo) and keeps every other name whole, so M.5, M.15, S_2 and
    /// x.1 keep their names. A single-end run writes every ID as it is.
    func testAPairedRunDropsOnlyAFinalSlashOneOrSlashTwoFromAReadID() async throws {
        let database = try await requireKraken2AndViralDatabase()
        let fixture = ConformanceFixtures.fixture("read-pairing/kraken2")
        let names = ["M.5", "M.15", "S_2", "x.1", ".5", "A/1", "B/2", "C/3", "/1", "H/1/1"]
        let records = try String(contentsOf: fixture.appendingPathComponent("merged.fastq"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let renamed = work.appendingPathComponent("renamed.fastq")
        try names.enumerated().map { index, name in
            "@\(name)\n\(records[index * 4 + 1])\n+\n\(records[index * 4 + 3])\n"
        }.joined().write(to: renamed, atomically: true, encoding: .utf8)
        let mate = work.appendingPathComponent("renamed.emptymate.fastq")
        XCTAssertEqual(try ClassificationPipeline.writeEmptyMate(of: renamed, to: mate), names.count)

        let single = try await kraken2(["--report-minimizer-data"], inputs: [renamed.path], database: database, name: "ids-single")
        let paired = try await kraken2(["--report-minimizer-data", "--paired"], inputs: [renamed.path, mate.path], database: database, name: "ids-paired")
        func ids(_ url: URL) throws -> [String] { try perReadCalls(url).map { String($0.split(separator: "\t")[1]) } }
        XCTAssertEqual(try ids(single.output), names)
        XCTAssertEqual(try ids(paired.output), ["M.5", "M.15", "S_2", "x.1", ".5", "A", "B", "C/3", "/1", "H/1"])
    }

    // MARK: - Helpers

    private func requireKraken2AndViralDatabase() async throws -> URL {
        let condaManager = CondaManager.shared
        if !FileManager.default.fileExists(atPath: await condaManager.micromambaPath.path) {
            try ToolAvailability.skipOrFail("micromamba not installed in managed tool environment")
        }
        do {
            _ = try await condaManager.toolPath(name: "kraken2", environment: ClassificationPipeline.kraken2Environment)
        } catch {
            try ToolAvailability.skipOrFail("kraken2 not installed in conda environment")
        }
        do {
            guard let database = try await ConformanceFixtures.viralKrakenDB() else {
                try ToolAvailability.skipOrFail("Viral Kraken2 database not installed")
            }
            return database
        } catch let error as MetagenomicsDatabaseIdentityError {
            // An installation without a bound receipt still classifies. The
            // staging checks compare runs against each other on one database,
            // so they hold without the receipt the release gate pins.
            let registry = MetagenomicsDatabaseRegistry.shared
            guard let info = try await registry.database(named: "Viral"), info.status == .ready, let path = info.path,
                  FileManager.default.fileExists(atPath: path.appendingPathComponent("hash.k2d").path) else {
                try ToolAvailability.skipOrFail("Viral Kraken2 database not installed")
            }
            print("Viral database identity not verified (\(error.localizedDescription)). Using \(path.path).")
            return path
        }
    }

    /// A merge derivative of the fixture, with its files by role.
    private func makeMergeDerivative(from fixture: URL) throws -> URL {
        let bundle = work.appendingPathComponent("Project.lungfish/Imports/merge.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"] {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
        }
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 77),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 23),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 23),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "merge", parentBundleRelativePath: ".", rootBundleRelativePath: ".",
                rootFASTQFilename: "merged.fastq", payload: .fullMixed(classification),
                lineage: [operation], operation: operation,
                cachedStatistics: .placeholder(readCount: 123, baseCount: 1), pairingMode: .pairedEnd,
                readClassification: classification, sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    private func kraken2(
        _ flags: [String], inputs: [String], database: URL, name: String
    ) async throws -> (report: URL, output: URL) {
        let report = work.appendingPathComponent("\(name).kreport")
        let output = work.appendingPathComponent("\(name).kraken")
        let arguments = ["--db", database.path, "--threads", "2", "--confidence", "0.2", "--minimum-hit-groups", "2",
                         "--output", output.path, "--report", report.path] + flags + inputs
        let run = try await CondaManager.shared.runTool(
            name: "kraken2", arguments: arguments, environment: ClassificationPipeline.kraken2Environment
        )
        XCTAssertEqual(run.exitCode, 0, run.stderr)
        return (report, output)
    }

    /// Columns 1 to 3 of each per-read line: the call, the read ID and the taxon.
    private func perReadCalls(_ url: URL) throws -> [String] {
        let text: String
        if url.pathExtension == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        return text.split(separator: "\n").map { $0.split(separator: "\t").prefix(3).joined(separator: "\t") }
    }

    /// Clade, direct and minimizer counts by rank code and taxon.
    private func kreportCounts(_ url: URL) throws -> [String: [Int]] {
        var counts: [String: [Int]] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 8 else { continue }
            counts["\(columns[5])\t\(columns[6])"] = [Int(columns[1]) ?? -1, Int(columns[2]) ?? -1, Int(columns[3]) ?? -1]
        }
        return counts
    }
}
