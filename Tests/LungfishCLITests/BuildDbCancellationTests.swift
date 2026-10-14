// BuildDbCancellationTests.swift - A cancel stops the build-db cores between samples and before they publish
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// What the `build-db kraken2` and `build-db esviritu` cores do when the task that runs them is cancelled, as
/// the analysis run executor cancels the task of its index step (plan decision E5 of Phase 2.7, SWIFT S7 of
/// Phase 2.8). A core checks for the cancel between sample folders and before each step that publishes or
/// removes something. It ends with `CancellationError`, puts back the database of an earlier build and writes
/// no record of a failed build, so the result folder holds no database, sidecar or record of the cancelled run.
///
/// A test cancels the task of the core from inside the core, in the event sink, when the core reports a line
/// that it reports at the point under test, so the cancel arrives at that point on every run. A check at the
/// top of a loop that the core reports nothing inside is tested on a task that is cancelled before it starts.
final class BuildDbCancellationTests: XCTestCase {
    /// The sample folders of `kraken2-mini` and `esviritu-mini`, which are the same three runs.
    private static let fixtureSamples = ["SRR35517702", "SRR35517703", "SRR35517705"]

    // MARK: Kraken2

    /// The parse checks before it reads each sample folder, in the batch layout and with `--sample-dir`, so a
    /// batch of large reports stops after the report it is reading.
    func testKraken2ParseStopsBeforeTheNextSampleFolder() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        let samples = Self.fixtureSamples.map { result.appendingPathComponent($0, isDirectory: true) }

        let batch = await Self.runCancelledFromTheStart {
            try BuildDbCommand.Kraken2Subcommand.parseSampleDirectories(resultURL: result).rows.count
        }
        let explicit = await Self.runCancelledFromTheStart {
            try BuildDbCommand.Kraken2Subcommand.parseSampleDirectories(resultURL: result, sampleDirectories: samples).rows.count
        }

        Self.assertCancelled(batch, "The parse of the batch layout")
        Self.assertCancelled(explicit, "The parse of the --sample-dir folders")
    }

    /// A cancel that arrives after the parse ends the build before it writes the database, a sidecar or a
    /// record, and before it compacts any per-read output.
    func testKraken2CancelAfterTheParsePublishesNothing() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        let before = try Self.listing(of: result)

        let run = await Self.run(cancellingAt: { $0.hasPrefix("Parsed ") }) { sink in
            try await BuildDbCommand.Kraken2Subcommand.buildDatabase(in: result, options: try Self.options(), events: sink)
        }

        run.assertEndedCancelled()
        XCTAssertFalse(run.lines.contains { $0.hasPrefix("Built ") }, "The build went on to write the database")
        XCTAssertEqual(try Self.listing(of: result), before, "A cancel leaves the result folder as the build found it")
    }

    /// The cleanup compacts the per-read output of one sample folder after another. A cancel that arrives while
    /// it works on the first folder stops it before the second, which keeps its raw output. The folder it had
    /// compacted stays compacted, and the database is not kept.
    func testKraken2CancelBetweenSampleFoldersOfTheCleanupStopsTheCompaction() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        let first = Self.fixtureSamples[0]
        // A sidecar that cannot be read makes the cleanup warn once it has compacted the first folder.
        try Data("not json".utf8).write(to: result.appendingPathComponent("\(first)/classification-result.json"))

        let run = await Self.run(cancellingAt: { $0.hasPrefix("Warning: could not update ") }) { sink in
            try await BuildDbCommand.Kraken2Subcommand.buildDatabase(in: result, options: try Self.options(), events: sink)
        }

        run.assertEndedCancelled()
        let fileManager = FileManager.default
        func exists(_ sample: String, _ name: String) -> Bool {
            fileManager.fileExists(atPath: result.appendingPathComponent("\(sample)/\(name)").path)
        }
        XCTAssertTrue(exists(first, "classification.kraken.gz"), "The folder it had compacted stays compacted")
        XCTAssertFalse(exists(first, "classification.kraken"))
        for later in Self.fixtureSamples.dropFirst() {
            XCTAssertTrue(exists(later, "classification.kraken"), "\(later) keeps its raw per-read output")
            XCTAssertFalse(exists(later, "classification.kraken.gz"), "\(later) was compacted after the cancel")
        }
        XCTAssertEqual(
            try Self.topLevelNames(of: result), Self.fixtureSamples,
            "The result folder holds no database, sidecar or record"
        )
    }

    /// A rebuild that is cancelled after it replaced the database puts the earlier database back, and the
    /// record of a failed build does not replace the record of the earlier one. The cleanup is off, so the
    /// check before the record is the next check after the database.
    func testKraken2CancelledRebuildKeepsTheEarlierBuild() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.kraken2Result(in: scratch)
        _ = try await BuildDbCommand.Kraken2Subcommand.buildDatabase(
            in: result, options: try Self.options(noCleanup: true), events: .silent
        )
        let earlier = try Self.topLevelFiles(of: result)
        XCTAssertNotNil(earlier["kraken2.sqlite"], "The first build wrote the database")
        XCTAssertNotNil(earlier[".lungfish-provenance.json"], "and the record of the folder")

        let run = await Self.run(cancellingAt: { $0.hasPrefix("Built ") }) { sink in
            try await BuildDbCommand.Kraken2Subcommand.buildDatabase(
                in: result, options: try Self.options(force: true, noCleanup: true), events: sink
            )
        }

        run.assertEndedCancelled()
        XCTAssertEqual(try Self.topLevelFiles(of: result), earlier, "The cancelled rebuild changed what the first build published")
    }

    // MARK: EsViritu

    /// The parse checks before it reads each sample folder.
    func testEsVirituParseStopsBeforeTheNextSampleFolder() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)

        let parse = await Self.runCancelledFromTheStart {
            try BuildDbCommand.EsVirituSubcommand.parseSampleDirectories(resultURL: result).count
        }

        Self.assertCancelled(parse, "The parse of the detection tables")
    }

    /// The cleanup checks before it removes the `_temp` folder of each sample.
    func testEsVirituCleanupStopsBeforeTheNextTempFolder() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        let temps = try Self.addTempFolders(to: result)

        let cleanup = await Self.runCancelledFromTheStart {
            try BuildDbCommand.EsVirituSubcommand.performCleanup(resultURL: result, events: .silent)
        }

        Self.assertCancelled(cleanup, "The cleanup")
        for temp in temps {
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path), "\(temp.lastPathComponent) was removed after the cancel")
        }
    }

    /// A cancel at each step of the build ends it at the next check and leaves no database, sidecar or record.
    /// The `_temp` folders stand for the intermediate files the cleanup removes, so a build that goes on to
    /// the cleanup shows. The last step is a cancel that arrives with the cleanup, which cannot put back
    /// the `_temp` folders it removed, and the check before the record still stops the record.
    func testEsVirituCancelAtEachStepPublishesNothing() async throws {
        let steps = [
            EsVirituStep(
                name: "the detection rows",
                reportedAtTheStep: { $0.hasSuffix("detection rows from EsViritu results") },
                reportedOnlyAfterwards: { $0.hasSuffix("coverage windows from EsViritu results") },
                cleanupRan: false
            ),
            EsVirituStep(
                name: "the coverage windows",
                reportedAtTheStep: { $0.hasSuffix("coverage windows from EsViritu results") },
                reportedOnlyAfterwards: { $0.hasPrefix("Built ") },
                cleanupRan: false
            ),
            EsVirituStep(
                name: "the database",
                reportedAtTheStep: { $0.hasPrefix("Built ") },
                reportedOnlyAfterwards: { $0.contains("No rows with BAM paths") },
                cleanupRan: false
            ),
            EsVirituStep(
                name: "the read count pass",
                reportedAtTheStep: { $0.contains("No rows with BAM paths") },
                reportedOnlyAfterwards: { $0.hasPrefix("Removed intermediate files") },
                cleanupRan: false
            ),
            EsVirituStep(
                name: "the cleanup",
                reportedAtTheStep: { $0.hasPrefix("Removed intermediate files") },
                reportedOnlyAfterwards: { _ in false },
                cleanupRan: true
            ),
        ]
        for step in steps {
            let scratch = try ImportStreamCapture.Scratch()
            defer { scratch.remove() }
            let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
            let temps = try Self.addTempFolders(to: result)

            let run = await Self.run(cancellingAt: step.reportedAtTheStep) { sink in
                try await BuildDbCommand.EsVirituSubcommand.buildDatabase(in: result, options: try Self.options(), events: sink)
            }

            let cancel = "A cancel after \(step.name)"
            run.assertEndedCancelled(cancel)
            XCTAssertFalse(run.lines.contains(where: step.reportedOnlyAfterwards), "\(cancel) did not stop the build")
            XCTAssertEqual(
                try Self.topLevelNames(of: result), Self.fixtureSamples,
                "\(cancel) left a database, sidecar or record"
            )
            for temp in temps {
                XCTAssertEqual(
                    FileManager.default.fileExists(atPath: temp.path), !step.cleanupRan,
                    "\(cancel) and \(temp.lastPathComponent) \(step.cleanupRan ? "is still there" : "was removed")"
                )
            }
        }
    }

    /// A cancel that arrives with the database leaves the BAMs in the `_temp` folder, where the records of
    /// the EsViritu run name them, because the move to `bams` is a step the cancelled build does not take.
    func testEsVirituCancelAfterTheDatabaseKeepsTheBAMsWhereTheRunLeftThem() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        let sample = Self.fixtureSamples[2]
        let temp = result.appendingPathComponent("\(sample)/\(sample)_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let bam = temp.appendingPathComponent("\(sample).third.filt.sorted.bam")
        try Data("BAM".utf8).write(to: bam)
        let before = try Self.listing(of: result)

        let run = await Self.run(cancellingAt: { $0.hasPrefix("Built ") }) { sink in
            try await BuildDbCommand.EsVirituSubcommand.buildDatabase(in: result, options: try Self.options(), events: sink)
        }

        run.assertEndedCancelled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bam.path), "The BAM moved after the cancel")
        XCTAssertEqual(try Self.listing(of: result), before, "A cancel leaves the result folder as the build found it")
    }

    /// A rebuild that is cancelled after it replaced the database puts the earlier database back, and the
    /// record of a failed build does not replace the record of the earlier one.
    func testEsVirituCancelledRebuildKeepsTheEarlierBuild() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        _ = try await BuildDbCommand.EsVirituSubcommand.buildDatabase(
            in: result, options: try Self.options(noCleanup: true), events: .silent
        )
        let earlier = try Self.topLevelFiles(of: result)
        XCTAssertNotNil(earlier["esviritu.sqlite"], "The first build wrote the database")
        XCTAssertNotNil(earlier[".lungfish-provenance.json"], "and the record of the folder")

        let run = await Self.run(cancellingAt: { $0.hasPrefix("Built ") }) { sink in
            try await BuildDbCommand.EsVirituSubcommand.buildDatabase(
                in: result, options: try Self.options(force: true, noCleanup: true), events: sink
            )
        }

        run.assertEndedCancelled()
        XCTAssertEqual(try Self.topLevelFiles(of: result), earlier, "The cancelled rebuild changed what the first build published")
    }

    /// The read count pass catches the failure of each samtools call and goes on to the next BAM. The markdup
    /// of a BAM after a cancel checks for it before it hashes the BAM, so the pass hashes no BAM after a cancel.
    func testMarkdupAfterACancelHashesNoBAM() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        // A BAM that the hash cannot open, so a markdup that hashes it throws descriptorUnavailable.
        let bam = scratch.root.appendingPathComponent("sample.bam")
        try Data("BAM".utf8).write(to: bam)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bam.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bam.path) }

        let task = Task { () async throws -> Void in
            while !Task.isCancelled { await Task.yield() }
            let tracker = BuildDbSamtoolsProvenanceTracker(
                samtoolsPath: "/usr/bin/false", collector: BuildDbSamtoolsProvenanceCollector()
            )
            _ = try await tracker.markdup(bamURL: bam)
        }
        task.cancel()
        let outcome = await task.result

        Self.assertCancelled(outcome, "The markdup of a BAM after a cancel")
    }

    /// The read count pass turns the failure of one markdup into a warning and goes on to the next BAM. A
    /// cancel that arrives as the loop starts fails the markdup of every BAM, so at the base the pass logs one
    /// "markdup failed" warning for each BAM left (lane S33 M1 pins that count, M2 ends it) and the core ends
    /// at the check after the pass.
    func testACancelInTheMarkdupLoopLogsOneWarningForEachBAMLeft() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        for sample in Self.fixtureSamples {
            let temp = result.appendingPathComponent("\(sample)/\(sample)_temp", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data("BAM".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam"))
        }
        let samtools = try ManagedSamtoolsHome.makeStub(rootURL: scratch.root, namePrefix: "Home")

        let run = await Self.withHome(samtools.homeURL) {
            await Self.run(cancellingAt: { $0.hasPrefix("Running markdup on ") }) { sink in
                try await BuildDbCommand.EsVirituSubcommand.buildDatabase(in: result, options: try Self.options(), events: sink)
            }
        }

        run.assertEndedCancelled()
        XCTAssertTrue(run.lines.contains("Running markdup on 3 BAM file(s)..."), "The three BAMs reached the loop")
        XCTAssertEqual(
            run.lines.filter { $0.contains("markdup failed on ") }.count, 3,
            "The loop logged one warning for each BAM the cancel left"
        )
    }

    // MARK: Running a core under a cancel

    /// Runs `body` with `HOME` at `home`, where `build-db` finds its managed samtools.
    private static func withHome<T>(_ home: URL, _ body: () async -> T) async -> T {
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        return await body()
    }

    private static func options(force: Bool = false, noCleanup: Bool = false) throws -> BuildDbRunOptions {
        BuildDbRunOptions(force: force, noCleanup: noCleanup, globalOptions: try GlobalOptions.parse([]))
    }

    /// Runs `core` in a task of its own and cancels that task at the first line `trigger` accepts.
    private static func run(
        cancellingAt trigger: @escaping @Sendable (String) -> Bool,
        _ core: @escaping @Sendable (BuildDbEventSink) async throws -> BuildDbRunResult
    ) async -> CancelledRun {
        let recorder = CancellingSink(cancelAt: trigger)
        let sink = recorder.sink
        let outcome = await Task { try await core(sink) }.result
        return CancelledRun(outcome: outcome, lines: recorder.lines)
    }

    /// Runs `work` in a task that is cancelled before `work` starts.
    private static func runCancelledFromTheStart<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async -> Result<T, Error> {
        let task = Task { () throws -> T in
            while !Task.isCancelled { await Task.yield() }
            return try work()
        }
        task.cancel()
        return await task.result
    }

    fileprivate static func assertCancelled<T>(
        _ outcome: Result<T, Error>, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        switch outcome {
        case .success(let value):
            XCTFail("\(what) went on after the cancel and returned \(value)", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "\(what) threw \(error) and not CancellationError", file: file, line: line)
        }
    }

    // MARK: What a folder holds

    /// Adds a `_temp` folder with a file to each sample folder of an EsViritu result, as the folder that
    /// EsViritu leaves its intermediate files in, and returns the folders.
    private static func addTempFolders(to result: URL) throws -> [URL] {
        try fixtureSamples.map { sample in
            let temp = result.appendingPathComponent("\(sample)/\(sample)_temp", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data("intermediate".utf8).write(to: temp.appendingPathComponent("scratch.txt"))
            return temp
        }
    }

    /// Every path under `folder`, hidden files included, with the size of each file, so a build that
    /// publishes, removes or rewrites anything shows.
    private static func listing(of folder: URL) throws -> [String] {
        let fileManager = FileManager.default
        let base = folder.standardizedFileURL.path
        return try fileManager.subpathsOfDirectory(atPath: base).sorted().map { path in
            let attributes = try fileManager.attributesOfItem(atPath: base + "/" + path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { return "\(path)/" }
            return "\(path) \(attributes[.size] as? Int ?? 0)"
        }
    }

    /// The names directly under `folder`, hidden files included.
    private static func topLevelNames(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The bytes of each file directly under `folder`, by name, hidden files included.
    private static func topLevelFiles(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try topLevelNames(of: folder) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: folder.appendingPathComponent(name))
        }
        return files
    }
}

/// A step of the EsViritu core at which a test cancels it.
private struct EsVirituStep {
    let name: String
    /// The line the core reports at the step, which cancels it.
    let reportedAtTheStep: @Sendable (String) -> Bool
    /// A line the core reports only if it goes on after the step.
    let reportedOnlyAfterwards: @Sendable (String) -> Bool
    /// Whether the cleanup has removed the `_temp` folders by the step.
    let cleanupRan: Bool
}

/// What a core did when its task was cancelled at one of its lines.
private struct CancelledRun {
    let outcome: Result<BuildDbRunResult, Error>
    /// Every line the core reported, on any channel.
    let lines: [String]

    func assertEndedCancelled(_ what: String = "The core", file: StaticString = #filePath, line: UInt = #line) {
        BuildDbCancellationTests.assertCancelled(
            outcome.map(\.databaseURL.lastPathComponent), what, file: file, line: line
        )
    }
}

/// An event sink that keeps each line a core reports and cancels the task that reports a line `trigger` accepts.
private final class CancellingSink: @unchecked Sendable {
    private let trigger: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var reported: [String] = []

    init(cancelAt trigger: @escaping @Sendable (String) -> Bool) {
        self.trigger = trigger
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }

    var sink: BuildDbEventSink {
        BuildDbEventSink(
            progress: { _, _ in },
            text: { self.take($0) },
            textWarning: { self.take($0) },
            warning: { self.take($0) }
        )
    }

    private func take(_ line: String) {
        lock.lock()
        reported.append(line)
        lock.unlock()
        guard trigger(line) else { return }
        // The core reports the line on its own task, so this cancels the task that runs the core.
        withUnsafeCurrentTask { task in
            if let task { task.cancel() }
        }
    }
}
