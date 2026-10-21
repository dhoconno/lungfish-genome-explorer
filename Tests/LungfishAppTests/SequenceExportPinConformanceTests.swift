// SequenceExportPinConformanceTests.swift - What the sequence export writes today, pinned after decompression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A49 M3 (BIO 1, QA 3). The Import Center compresses a sequence export with /usr/bin/gzip or
// /usr/bin/zstd. Lane A49 M3 moves that compression into `convert --compress` and runs the exports through
// lungfish-cli. This pin exports four fixtures once for each compressor the export offers, a FASTA file, an
// annotated reference bundle to GenBank, two FASTA files and a captured snapshot, and keeps each export as
// text after decompression, with the GenBank date taken out. The route must leave those texts as they are.
// It also checks the container of each output by its first bytes and that its record sits beside it. A gzip
// header holds the name and the time of the file it compressed, so the bytes of a `.gz` differ from run to
// run and only the text after decompression is pinned.
//
// macOS ships no /usr/bin/zstd, which was the only path the export launched, so at the base the zstd export
// failed and published nothing on a Mac without one, and the pin said so. The route now runs the zstd that
// Lungfish manages (lane 13.17), so with that zstd installed the pin holds the same text, and without it the
// export still fails and publishes nothing. The test at the end replays the row's recorded
// command on a copy of the folder.
//
// It runs the system gzip, so its name ends in Conformance, which keeps it out of the unit tier, and it
// skips without gzip unless `LUNGFISH_REQUIRE_TOOLS=1`. It points `LUNGFISH_CLI_PATH` at the built
// lungfish-cli, which the base never starts for these cases and the route does. To capture the texts again set
// `LUNGFISH_RECAPTURE_SEQUENCE_EXPORT=1`, which rewrites `SequenceExportPinExpected.swift`.
//
// Phase 2.12 lane 12.13 M1 (A49-PARITY, BIO 1, QA 1 and 3) adds four input kinds that 2.11 sent to `convert` and
// never compared with the app's writer, and freezes the app writer's texts in `SequenceExportParityExpected.swift`
// (`LUNGFISH_RECAPTURE_SEQUENCE_EXPORT_PARITY=1` wrote them at the base of 12.13, while the app's writer existed).
//
// Lane 12.13 M2 (A49-GAP) deletes the app's writer. A captured snapshot and a file `convert` does not read are
// staged by `SequenceExportStaging` and `convert` runs on them, so every export here runs the command, and
// the frozen texts are A. Each selection the writer took alone is also replayed from its record on a copy of
// the folder (C against C'). The frozen texts cannot be captured again, since A no longer exists.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class SequenceExportPinConformanceTests: XCTestCase {
    private var root: URL!
    private var priorCLIPath: String?
    private var stagedFolders: [URL] = []

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sequence-export-pin")
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        if let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products) {
            setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        }
    }

    override func tearDownWithError() throws {
        if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        if let root { TestTempDirectory.cleanup(root) }
        // A selection outside a project stages in the system temporary folder, which the test removes too.
        for folder in stagedFolders { try? FileManager.default.removeItem(at: folder) }
    }

    func testEachExportPinsItsTextAfterDecompression() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("first.fa")
        let second = inputs.appendingPathComponent("second.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">gamma\nGGGGCCCCAAAATTTT\n".write(to: second, atomically: true, encoding: .utf8)
        let bundle = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        let snapshotURL = project.appendingPathComponent("snapshot")
        let snapshot = SequenceExportSourceResolver.Source(
            metadata: .init(
                kind: .nativeProjectSequence, url: snapshotURL, documentID: UUID(), nativeSequenceID: UUID(),
                projectURL: project
            ),
            document: .init(
                name: "snapshot", url: snapshotURL,
                sequences: [try LungfishCore.Sequence(name: "native", alphabet: .dna, bases: "ACGTTGCA")],
                annotations: []
            )
        )

        let cases: [(name: String, sources: [SequenceExportSourceResolver.Source], format: SequenceExportFormat)] = [
            ("file", [Self.fileSource(first)], .fasta),
            ("bundle", [Self.fileSource(bundle)], .genbank),
            ("two", [Self.fileSource(first), Self.fileSource(second)], .fasta),
            ("captured", [snapshot], .fasta),
        ]
        var actual: [String: String] = [:]
        for item in cases {
            actual[item.name] = try await export(item.sources, to: "\(item.name).gz", format: item.format, compression: .gzip)
        }
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_SEQUENCE_EXPORT"] == "1" {
            try Self.writeExpected(actual)
            return
        }
        XCTAssertEqual(Set(actual.keys), Set(SequenceExportPinExpected.cases.keys))
        for (name, text) in actual.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(text, SequenceExportPinExpected.cases[name], "\(name) with gzip")
        }

        // The same four exports with zstd. At the base the export launched only /usr/bin/zstd, which macOS does
        // not ship, so on a Mac without one it failed and published nothing. The route now runs the zstd that
        // Lungfish manages (lane 13.17), so with that tool installed the text is the same, and without it the
        // export still fails and publishes nothing.
        let zstdPath = (try? await NativeToolRunner.shared.toolPath(for: .zstd))?.path
        let hasZstd = zstdPath != nil
        for item in cases {
            if hasZstd {
                let text = try await export(item.sources, to: "\(item.name).zst", format: item.format, compression: .zstd)
                XCTAssertEqual(text, SequenceExportPinExpected.cases[item.name], "\(item.name) with zstd")
            } else {
                let output = root.appendingPathComponent("out/\(item.name).zst")
                do {
                    try await runExport(item.sources, to: output, format: item.format, compression: .zstd)
                    XCTFail("\(item.name) with zstd should fail without the managed zstd")
                } catch {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(item.name) publishes nothing")
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
                        "\(item.name) leaves no record"
                    )
                }
            }
        }
    }

    /// A49-PARITY (lane 12.13 M1) and A49-GAP (M2). A one-record GenBank file with a gene feature, a `.gz` wrapped
    /// FASTA, a FASTQ file and a mixed selection (the `Alpha` bundle and `first.fa`) each export twice with gzip,
    /// as captured documents built from the reader output of the same files, which are staged, and as the files.
    /// Both run `convert` (C) and must write A, the app writer's text frozen in M1. So must the three selections
    /// the app's writer took alone until M2, a GenBank snapshot whose features name no chromosome, a `.seq` file
    /// and a snapshot mixed with files, and the replay of each one's record writes the same text (C').
    func testEachInputKindWritesTheAppWritersTextThroughConvert() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let files = try Self.writeParityInputs(in: inputs)
        let bundle = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        let parity: [(name: String, files: [URL], format: SequenceExportFormat)] = [
            ("genbank-file", [files.genbank], .genbank),
            ("gz-wrapped", [files.wrapped], .fasta),
            ("fastq", [files.fastq], .fasta),
            ("mixed", [bundle, files.first], .fasta),
        ]
        var actual: [String: String] = [:]
        for item in parity {
            var captured: [SequenceExportSourceResolver.Source] = []
            for file in item.files { captured.append(try await capturedSource(readFrom: file)) }
            let staged = try await export(captured, to: "\(item.name)-staged.gz", format: item.format, compression: .gzip)
            let command = try await export(
                item.files.map(Self.fileSource), to: "\(item.name)-convert.gz", format: item.format, compression: .gzip
            )
            XCTAssertEqual(staged, command, "\(item.name), convert on the staged documents against convert on the files")
            XCTAssertEqual(try recordedArgv(of: "\(item.name)-staged.gz").dropFirst().first, "convert")
            XCTAssertEqual(try recordedArgv(of: "\(item.name)-convert.gz").dropFirst().first, "convert")
            actual[item.name] = command
        }
        let geneQualifier = "/gene=\"geneB\""
        XCTAssertTrue(actual["genbank-file"]?.contains(geneQualifier) == true, "the gene feature is kept")

        let snapshots = try Self.genBankSnapshots(project: project)
        let appOnly: [(name: String, sources: [SequenceExportSourceResolver.Source], format: SequenceExportFormat)] = [
            ("snapshot-genbank", snapshots, .genbank),
            ("seq-file", [Self.fileSource(files.seq)], .fasta),
            ("snapshot-mixed", [snapshots[0], Self.fileSource(files.seq), Self.fileSource(files.first)], .genbank),
        ]
        for item in appOnly {
            actual[item.name] = try await exportAndReplay(item.sources, to: "\(item.name).gz", format: item.format)
        }
        XCTAssertEqual(Set(actual.keys), Set(SequenceExportParityExpected.cases.keys))
        for (name, text) in actual.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(text, SequenceExportParityExpected.cases[name], "\(name) against the app's writer frozen in 12.13 M1 (A)")
        }
    }

    /// The row's recorded command, moved onto a copy of the folder and run there, writes the text the run wrote
    /// (C against C'). Each compressor available here runs once.
    func testTheRecordedCommandReproducesTheRun() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("first.fa")
        let second = inputs.appendingPathComponent("second.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">gamma\nGGGGCCCCAAAATTTT\n".write(to: second, atomically: true, encoding: .utf8)
        let replayRoot = try TestTempDirectory.make(prefix: "sequence-export-replay")
        defer { TestTempDirectory.cleanup(replayRoot) }
        try FileManager.default.copyItem(at: inputs, to: replayRoot.appendingPathComponent("inputs"))
        try FileManager.default.createDirectory(at: replayRoot.appendingPathComponent("out"), withIntermediateDirectories: true)

        let zstdPath = (try? await NativeToolRunner.shared.toolPath(for: .zstd))?.path
        var compressions: [SequenceExportCompression] = [.gzip]
        if zstdPath != nil { compressions.append(.zstd) }
        for compression in compressions {
            let name = compression == .gzip ? "run.fa.gz" : "run.fa.zst"
            let text = try await export(
                [Self.fileSource(first), Self.fileSource(second)], to: name, format: .fasta, compression: compression
            )
            let output = root.appendingPathComponent("out").appendingPathComponent(name)
            let recorded = try XCTUnwrap(AppDelegate.sequenceExportCLICommand(
                inputURLs: [first, second], outputURL: output, format: .fasta, compression: compression
            ))
            let rebased = try RecordedCLICommand.rebased(recorded, from: root, to: replayRoot)
            let replayOutput = replayRoot.appendingPathComponent("out").appendingPathComponent(name)
            let count = try await SequenceExportRoute.run(
                arguments: RecordedCLICommand.arguments(of: rebased), outputURL: replayOutput
            )
            XCTAssertEqual(count, 3, "\(name) replay count")
            let replayed = try Self.decompress(
                replayOutput, with: compression == .gzip ? "/usr/bin/gzip" : (zstdPath ?? "zstd")
            )
            XCTAssertEqual(replayed, text, "\(name) replay text")
            XCTAssertEqual(text, SequenceExportPinExpected.cases["two"], "\(name) against the pinned text")
        }
    }

    /// A task that is cancelled before it asks for the export stops the route, publishes nothing and leaves no
    /// stage file. The command does not start, so the cancel goes through the launcher as a row's Cancel does.
    func testACancelledTaskStopsTheRouteAndLeavesNoOutput() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = inputs.appendingPathComponent("first.fa")
        try ">alpha\nACGTACGTAC\n".write(to: input, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("cancelled.fa.gz")
        let arguments = SequenceExportRoute.arguments(
            inputs: [input], outputURL: output, format: .fasta, compression: .gzip
        )

        let task = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SequenceExportRoute.run(arguments: arguments, outputURL: output)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled task must not publish an export")
        } catch is CancellationError {
        } catch {
            XCTFail("expected a cancel, got \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "nothing is left in the folder")
    }

    /// A cancel that reaches the command while it holds its recovery folder and its stage entries stops the route,
    /// keeps the export the run was asked to overwrite and leaves nothing behind (review A49-M3, fix F3). The
    /// route's cancel sends SIGTERM to `lungfish-cli convert`, which rolls back and removes its stage entries
    /// before it exits. The recovery folder lands in the temporary folder, and the unique bytes of the earlier
    /// export tell this run's folder from the folders of other runs.
    func testACancelDuringTheCommandStopsTheRouteAndKeepsTheEarlierExport() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        for directory in [inputs, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let input = inputs.appendingPathComponent("records.fa")
        try Self.writeFASTA(to: input)
        let output = folder.appendingPathComponent("held.fa.gz")
        let earlier = Data("an earlier export \(UUID().uuidString)".utf8)
        try earlier.write(to: output)
        let before = Self.recoveryFolderNames()

        let arguments = SequenceExportRoute.arguments(
            inputs: [input], outputURL: output, format: .fasta, compression: .gzip
        )
        let task = Task { () -> Int in
            try await SequenceExportRoute.run(arguments: arguments, outputURL: output)
        }
        // The stage folder appears a moment before the command builds its publication transaction, so the cancel
        // reaches the command while it holds its recovery folder. The window is short in the debug build.
        let atWork = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(2)) {
            !Self.convertEntries(in: folder).isEmpty
        }
        XCTAssertTrue(atWork, "the command never made its stage")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not report a count")
        } catch is CancellationError {
        } catch {
            XCTFail("expected a cancel, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: output), earlier, "a cancel keeps the earlier export")
        XCTAssertEqual(Self.convertEntries(in: folder), [], "no stage file or folder is left beside the output")
        XCTAssertEqual(
            Self.recoveryFolders(holding: earlier, since: before), [], "no recovery folder is left in the temporary folder"
        )
    }

    /// The record `convert` writes holds the argv of the row's command, so the row, the run and the record are
    /// one (review A49-M3, fix F4).
    func testTheRecordsArgvIsTheRowsCommand() async throws {
        try requireTools()
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("first.fa")
        let second = inputs.appendingPathComponent("second.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        try ">gamma\nGGGGCCCCAAAATTTT\n".write(to: second, atomically: true, encoding: .utf8)
        _ = try await export(
            [Self.fileSource(first), Self.fileSource(second)], to: "record.fa.gz", format: .fasta, compression: .gzip
        )
        let output = root.appendingPathComponent("out").appendingPathComponent("record.fa.gz")
        let envelope = try XCTUnwrap(
            try ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        )
        let row = try XCTUnwrap(AppDelegate.sequenceExportCLICommand(
            inputURLs: [first, second], outputURL: output, format: .fasta, compression: .gzip
        ))
        XCTAssertEqual(Array(envelope.argv.dropFirst()), try RecordedCLICommand.arguments(of: row))
    }

    /// A failing `convert` surfaces its message, the text the Export Failed alert shows (review A49-M3, fix F5 e).
    func testAFailingConvertSurfacesItsMessage() async throws {
        try requireTools()
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("inputs/missing.fa")
        let output = folder.appendingPathComponent("failed.fa.gz")
        let arguments = SequenceExportRoute.arguments(
            inputs: [missing], outputURL: output, format: .fasta, compression: .gzip
        )
        do {
            _ = try await SequenceExportRoute.run(arguments: arguments, outputURL: output)
            XCTFail("a missing input must fail the export")
        } catch let error as SequenceExportRoute.RouteError {
            XCTAssertTrue(error.detail.contains("missing.fa"), "the message names the missing file. \(error.detail)")
            XCTAssertEqual(error.errorDescription, error.detail)
        } catch {
            XCTFail("expected a RouteError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a failed export publishes nothing")
    }

    /// A cancel of a staged snapshot export (lane 12.13 M2), sent through the route's transport while every core
    /// is busy, three times. Each stops `convert` inside the app's grace, keeps the export the run was asked to
    /// overwrite, leaves no stage beside it and discards the staging, since no record names it.
    func testACancelOfAStagedSnapshotStopsTheCommandWithEveryCoreBusy() async throws {
        try requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        for directory in [project, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let records = root.appendingPathComponent("records.fa")
        try Self.writeFASTA(to: records)
        let held = project.appendingPathComponent("held")
        let snapshot = SequenceExportSourceResolver.Source(
            metadata: .init(
                kind: .nativeProjectSequence, url: held, documentID: UUID(), nativeSequenceID: UUID(), projectURL: project
            ),
            document: .init(
                name: "held", url: held, sequences: try await FASTAReader(url: records).readAll(), annotations: []
            )
        )
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")
        XCTAssertEqual(load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core")
        let before = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        for attempt in 1...3 {
            let output = folder.appendingPathComponent("held-\(attempt).fa.gz")
            let earlier = Data("an earlier export \(UUID().uuidString)".utf8)
            try earlier.write(to: output)
            let task = Task { try await self.runExport([snapshot], to: output, format: .fasta, compression: .gzip) }
            let atWork = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(2)) {
                !Self.convertEntries(in: folder).isEmpty
            }
            XCTAssertTrue(atWork, "attempt \(attempt), the command never made its stage")
            let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !before.contains($0) }
            XCTAssertFalse(tree.isEmpty, "attempt \(attempt), the command's process runs when the cancel is sent")
            let clock = ContinuousClock()
            let cancelled = clock.now
            task.cancel()
            do {
                try await task.value
                XCTFail("attempt \(attempt), a cancelled export must not publish")
            } catch is CancellationError {
            } catch {
                XCTFail("attempt \(attempt), expected a cancel, got \(error)")
            }
            let elapsed = clock.now - cancelled
            XCTAssertLessThanOrEqual(elapsed, CLIProcessLauncher.operationGrace, "attempt \(attempt), the command ends inside the grace before SIGKILL, took \(elapsed)")
            XCTAssertEqual(try Data(contentsOf: output), earlier, "attempt \(attempt) keeps the earlier export")
            XCTAssertEqual(Self.convertEntries(in: folder), [], "attempt \(attempt) leaves no stage beside the output")
            await CLISIGTERMHarness.assertNoProcessLeft(tree)
        }
        let temporary = ProjectTempDirectory.tempRoot(for: project).path
        let staging = ((try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? [])
            .filter { $0.hasPrefix("sequence-export-") }
        XCTAssertEqual(staging, [], "a cancelled export discards its staging")
    }

    /// What the export does with a `.seq` file that holds no sequence (review 12.13 fix 5), measured through the
    /// command on a file of no bytes and on a file of white space. The app's writer refused an export of no
    /// sequences. Staging copies a file as it is, since only `convert` can tell, and `convert` has no such
    /// refusal, so the export completes with an empty output and reports 0 sequences. A `convert` that refuses
    /// an input with no sequence (row CONVERT-EMPTY-INPUT of 2.13) changes this pin. A captured snapshot of no
    /// sequences keeps the old message in `SequenceExportStagingDurabilityTests`.
    func testAnEmptySeqFileExportsAnEmptyFileAndReportsNoSequences() async throws {
        try requireTools()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        for directory in [project, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (name, text) in [("empty.seq", ""), ("blank.seq", " \n\t\n \n")] {
            let seq = project.appendingPathComponent(name)
            try text.write(to: seq, atomically: true, encoding: .utf8)
            let output = folder.appendingPathComponent("\(name).fa")
            let source = SequenceExportSourceResolver.Source(
                metadata: .init(kind: .filesystem, url: seq, documentID: nil, nativeSequenceID: nil, projectURL: nil),
                document: nil
            )
            let staged = try SequenceExportStaging.stage([source], format: .fasta, outputURL: output)
            if let stagedFolder = staged.folder { stagedFolders.append(stagedFolder) }
            let count = try await SequenceExportRoute.run(
                arguments: SequenceExportRoute.arguments(
                    inputs: staged.inputs, outputURL: output, format: .fasta, compression: .none
                ),
                outputURL: output
            )
            XCTAssertEqual(count, 0, "\(name) reports no sequence")
            XCTAssertEqual(try Data(contentsOf: output), Data(), "\(name) exports an empty file")
        }
    }

    // MARK: - Helpers

    /// The hidden stage entries of `convert` in `folder`, whose names start with a dot and hold `.convert.`.
    nonisolated private static func convertEntries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0.contains(".convert.") }
            .sorted()
    }

    /// The names of the recovery folders now in the temporary folder.
    nonisolated private static func recoveryFolderNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("lungfish-publication-recovery-") })
    }

    /// The recovery folders made since `before` that hold a copy of `earlier`. The temporary folder of `FileManager`
    /// does not follow a changed `TMPDIR` on macOS, so the command's folder lands beside the folders of other runs.
    /// The unique bytes of the earlier export tell it from them, and only a folder made since `before` is opened.
    nonisolated private static func recoveryFolders(holding earlier: Data, since before: Set<String>) -> [String] {
        let temporary = FileManager.default.temporaryDirectory
        return recoveryFolderNames().subtracting(before).filter { name in
            let folder = temporary.appendingPathComponent(name, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return entries.contains { entry in
                let url = folder.appendingPathComponent(entry)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.intValue == earlier.count && (try? Data(contentsOf: url)) == earlier
            }
        }.sorted()
    }

    /// A FASTA of 4 records of 64 KB of pseudo-random bases in 80-column lines. The debug build of lungfish-cli
    /// reads and writes a FASTA slowly (64 MB took over two minutes), so the file is small enough for the write
    /// to end well inside the 6 seconds the app gives a cancel, and large enough to hold the command at work for
    /// longer than a poll.
    private static func writeFASTA(to url: URL, records: Int = 4, bytesPerRecord: Int = 64 << 10) throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let letters = Array("ACGT".utf8)
        var text = ""
        for index in 0..<records {
            var bases: [UInt8] = []
            bases.reserveCapacity(bytesPerRecord)
            for _ in 0..<bytesPerRecord {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bases.append(letters[Int((state >> 33) & 3)])
            }
            text += ">record\(index)\n"
            var start = 0
            while start < bases.count {
                let end = min(start + 80, bases.count)
                text += String(decoding: bases[start..<end], as: UTF8.self) + "\n"
                start = end
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file name a gzip header records, or nil when it records none.
    private static func gzipHeaderName(_ bytes: Data) -> String? {
        guard bytes.count > 10, bytes[bytes.startIndex + 3] & 0x08 != 0 else { return nil }
        let start = bytes.startIndex + 10
        guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func fileSource(_ url: URL) -> SequenceExportSourceResolver.Source {
        .init(
            metadata: .init(kind: .filesystem, url: url, documentID: nil, nativeSequenceID: nil, projectURL: nil),
            document: nil
        )
    }

    /// Runs the export and returns its text after decompression, the date of a GenBank LOCUS line taken out.
    private func export(
        _ sources: [SequenceExportSourceResolver.Source],
        to name: String,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> String {
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(name)
        try await runExport(sources, to: output, format: format, compression: compression)
        let magic: [UInt8] = compression == .gzip ? [0x1f, 0x8b] : [0x28, 0xb5, 0x2f, 0xfd]
        XCTAssertEqual(Array(try Data(contentsOf: output).prefix(magic.count)), magic, "\(name) holds a \(compression) container")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "\(name) has its record beside it"
        )
        if compression == .gzip {
            // The base ran `gzip -c export.fa` (or export.gb) in the export's temp folder, so the header names that.
            XCTAssertEqual(
                Self.gzipHeaderName(try Data(contentsOf: output)),
                format == .genbank ? "export.gb" : "export.fa",
                "\(name) names the file the export gave gzip"
            )
        }
        let text = try Self.decompress(
            output, with: compression == .gzip ? "/usr/bin/gzip" : ((try? await NativeToolRunner.shared.toolPath(for: .zstd))?.path ?? "zstd")
        )
        return text.replacingOccurrences(of: "[0-9]{2}-[A-Z]{3}-[0-9]{4}", with: "<DATE>", options: .regularExpression)
    }

    /// Stages `sources` and runs the export as the app does, through `Staged.run`, which discards the staging
    /// when the run fails or is cancelled. The rule lives in production code, so the test has no copy of it.
    private func runExport(
        _ sources: [SequenceExportSourceResolver.Source],
        to output: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws {
        let staged = try SequenceExportStaging.stage(sources, format: format, outputURL: output)
        if let folder = staged.folder { stagedFolders.append(folder) }
        _ = try await staged.run { inputs in
            try await makeAppDelegateWithTemporaryState().performSequenceExport(
                inputs: inputs, outputURL: output, format: format, compression: compression
            )
        }
    }

    /// Exports `sources` to `name` with gzip, then runs the command its record holds on a copy of the test folder
    /// (C against C') and checks that the replay writes the same text, which it returns.
    private func exportAndReplay(
        _ sources: [SequenceExportSourceResolver.Source],
        to name: String,
        format: SequenceExportFormat
    ) async throws -> String {
        let text = try await export(sources, to: name, format: format, compression: .gzip)
        let argv = Array(try recordedArgv(of: name).dropFirst())
        XCTAssertEqual(argv.first, "convert", "\(name) runs convert")
        let stagingFolder = "/sequence-export-"
        let staging = argv.filter { $0.contains(stagingFolder) }
        XCTAssertFalse(staging.isEmpty, "\(name) reads a staged file")
        for path in staging {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the record names a staged file that exists, \(path)")
        }
        let replayRoot = try TestTempDirectory.make(prefix: "sequence-export-parity-replay")
        defer { TestTempDirectory.cleanup(replayRoot) }
        let copy = replayRoot.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: copy)
        let replayOutput = copy.appendingPathComponent("out").appendingPathComponent(name)
        try FileManager.default.removeItem(at: replayOutput)
        let prefix = root.path + "/"
        let rebased = argv.map { $0.hasPrefix(prefix) ? copy.path + "/" + $0.dropFirst(prefix.count) : $0 }
        let count = try await SequenceExportRoute.run(arguments: rebased, outputURL: replayOutput)
        XCTAssertGreaterThan(count, 0, "replay count")
        let replayed = try Self.decompress(replayOutput, with: "/usr/bin/gzip")
            .replacingOccurrences(of: "[0-9]{2}-[A-Z]{3}-[0-9]{4}", with: "<DATE>", options: .regularExpression)
        XCTAssertEqual(replayed, text, "\(name), the recorded command on a copy of the folder (C against C')")
        return text
    }

    private static func decompress(_ url: URL, with tool: String) throws -> String {
        String(decoding: try runTool(tool, ["-dc", url.path]), as: UTF8.self)
    }

    /// What `tool` prints on standard output for `arguments`, which must exit 0.
    private static func runTool(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
        return data
    }

    /// The argv of the record beside the export `name` in `out`.
    private func recordedArgv(of name: String) throws -> [String] {
        let output = root.appendingPathComponent("out").appendingPathComponent(name)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        return try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)).argv
    }

    /// The parity inputs. `one-gene.gb` is one record with a gene feature, `wrapped.fa.gz` a gzip wrapped FASTA with
    /// descriptions and soft-masked bases, `reads.fastq` two reads, `first.fa` two records and `reads.seq` a FASTA
    /// under a name `convert` does not read.
    private static func writeParityInputs(
        in inputs: URL
    ) throws -> (genbank: URL, wrapped: URL, fastq: URL, first: URL, seq: URL) {
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let genbank = inputs.appendingPathComponent("one-gene.gb")
        try [
            "LOCUS       geneB                     30 bp    DNA     linear   SYN 01-JAN-2026",
            "DEFINITION  Synthetic record with one gene.",
            "FEATURES             Location/Qualifiers",
            "     gene            4..21",
            "                     /gene=\"geneB\"",
            "ORIGIN",
            "        1 acgtacgtac ggttaaccgg ttaaccggtt",
            "//",
            "",
        ].joined(separator: "\n").write(to: genbank, atomically: true, encoding: .utf8)
        let plain = inputs.appendingPathComponent("wrapped.fa")
        try ">wrapped one\nacgtNNACGTacgt\n>wrapped-two second record\nCCGGTTAAGG\n"
            .write(to: plain, atomically: true, encoding: .utf8)
        let wrapped = inputs.appendingPathComponent("wrapped.fa.gz")
        try runTool("/usr/bin/gzip", ["-c", "-n", plain.path]).write(to: wrapped)
        try FileManager.default.removeItem(at: plain)
        let fastq = inputs.appendingPathComponent("reads.fastq")
        try "@read1 sample=one\nACGTACGTAC\n+\nIIIIIIIIII\n@read2\nTTGGCCAA\n+\nIIIIIIII\n"
            .write(to: fastq, atomically: true, encoding: .utf8)
        let first = inputs.appendingPathComponent("first.fa")
        try ">alpha first record\nACGTACGTAC\n>beta\nTTGGCCAATT\n".write(to: first, atomically: true, encoding: .utf8)
        let seq = inputs.appendingPathComponent("reads.seq")
        try ">one\nACGT\n>two described\nTTGGCC\n".write(to: seq, atomically: true, encoding: .utf8)
        return (genbank, wrapped, fastq, first, seq)
    }

    /// A captured document holding what the export's reader returns for `url`, so A and C start from the same
    /// sequences and features. A FASTQ file is mapped as `convert` maps it, since the app's loader reads every
    /// file that is not a bundle or GenBank as FASTA.
    private func capturedSource(readFrom url: URL) async throws -> SequenceExportSourceResolver.Source {
        let sequences: [LungfishCore.Sequence]
        let annotations: [SequenceAnnotation]
        if url.pathExtension.lowercased() == "fastq" {
            sequences = try await FASTQReader().readAll(from: url).map {
                try LungfishCore.Sequence(name: $0.identifier, description: $0.description, alphabet: .dna, bases: $0.sequence)
            }
            annotations = []
        } else {
            (sequences, annotations) = try await makeAppDelegateWithTemporaryState().loadSequencesForExport(from: url)
        }
        return .init(
            metadata: .init(kind: .openDocument, url: url, documentID: UUID(), nativeSequenceID: nil, projectURL: nil),
            document: .init(name: url.lastPathComponent, url: url, sequences: sequences, annotations: annotations)
        )
    }

    /// Two captured project sequences for a GenBank export. The first holds two sequences, a gene that names no
    /// chromosome, which the app's writer puts on both, and a split reverse CDS that names `segB`. The second holds
    /// one sequence and a feature that names no chromosome.
    private static func genBankSnapshots(project: URL) throws -> [SequenceExportSourceResolver.Source] {
        let documents: [(name: String, sequences: [LungfishCore.Sequence], annotations: [SequenceAnnotation])] = [
            ("first-native", [
                try LungfishCore.Sequence(
                    name: "segA", description: "segment A of first", alphabet: .dna, bases: "ACGTACGTAAACCCGGGTTTACGT"
                ),
                try LungfishCore.Sequence(name: "segB", alphabet: .dna, bases: "TTTTGGGGCCCCAAAA"),
            ], [
                SequenceAnnotation(type: .gene, name: "shared", start: 0, end: 9, strand: .forward, qualifiers: [
                    "gene": AnnotationQualifier("shared"), "note": AnnotationQualifier("names no chromosome"),
                ]),
                SequenceAnnotation(
                    type: .cds, name: "onlyB", chromosome: "segB",
                    intervals: [AnnotationInterval(start: 0, end: 6), AnnotationInterval(start: 9, end: 15)],
                    strand: .reverse,
                    qualifiers: ["gene": AnnotationQualifier("onlyB"), "product": AnnotationQualifier("a split protein")]
                ),
            ]),
            ("second-native", [try LungfishCore.Sequence(name: "solo", alphabet: .dna, bases: "GGGGAAAACCCCTTTT")], [
                SequenceAnnotation(type: .gene, name: "soloGene", start: 2, end: 8, qualifiers: [
                    "gene": AnnotationQualifier("soloGene"),
                ]),
            ]),
        ]
        return documents.map { document in
            let url = project.appendingPathComponent(document.name)
            return .init(
                metadata: .init(
                    kind: .nativeProjectSequence, url: url, documentID: UUID(), nativeSequenceID: UUID(), projectURL: project
                ),
                document: .init(name: document.name, url: url, sequences: document.sequences, annotations: document.annotations)
            )
        }
    }

    private static func writeExpected(
        _ cases: [String: String],
        typeName: String = "SequenceExportPinExpected",
        title: String = "The text of each pinned sequence export after decompression",
        variable: String = "LUNGFISH_RECAPTURE_SEQUENCE_EXPORT"
    ) throws {
        var lines = [
            "// \(typeName).swift - \(title)",
            "// Copyright (c) 2026 Lungfish Contributors",
            "// SPDX-License-Identifier: MIT",
            "//",
            "// Written by `SequenceExportPinConformanceTests` when `\(variable)=1`.",
            "",
            "enum \(typeName) {",
            "    static let cases: [String: String] = [",
        ]
        for (name, text) in cases.sorted(by: { $0.key < $1.key }) {
            lines.append("        \"\(name)\": #\"\"\"")
            lines.append(text)
            lines.append("\"\"\"#,")
        }
        lines.append(contentsOf: ["    ]", "}", ""])
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("\(typeName).swift")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/gzip") else {
            try ToolAvailability.skipOrFail("/usr/bin/gzip is required", file: file, line: line)
            return
        }
    }
}
