// SequenceAnnotationEditCommandTests.swift - The two sequence edit leaves against what the app writes today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `sequence add-annotation` and `sequence attach-track` call the Workflow function the app calls
// (2.10 A42 M2, BIO 4). Each test runs the app's call on one copy of a reference bundle and the leaf
// on an identical copy, then compares the annotation rows, the manifest's track entries and the
// record entry. The argv is the one fact that differs by design: the leaf records the command that
// reproduces the edit, and the app records its own form until M3 hands it the leaf's argv. The
// feature's random ID, the times and the digests of the outputs that hold that ID vary from run to
// run, so they are left out, and each record must still hold a digest for every output it names.

import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class SequenceAnnotationEditCommandTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/SequenceAnnotationEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAddAnnotationWritesTheRowTrackAndRecordTheMenuItemWrites() async throws {
        let app = try SequenceEditFixture.referenceBundle(in: scratch.appendingPathComponent("app"))
        let cli = try SequenceEditFixture.referenceBundle(in: scratch.appendingPathComponent("cli"))
        _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).addAnnotation(
            SequenceAnnotation(
                type: .gene,
                name: "selection-feature",
                chromosome: "chr1",
                intervals: [AnnotationInterval(start: 2, end: 9)],
                strand: .forward
            ),
            toBundleAt: app
        )
        try await SequenceCommand.AddAnnotation.parse([
            cli.path, "--chromosome", "chr1", "--start", "2", "--end", "9",
            "--name", "selection-feature", "--type", "gene", "--strand", "+", "--quiet",
        ]).execute(emit: { _ in })

        let database = "annotations/manual_annotations.db"
        XCTAssertEqual(try rows(app, database), ["selection-feature|gene|chr1|2|9|+|source=Lungfish%20manual%20annotation"])
        XCTAssertEqual(try rows(cli, database), try rows(app, database))
        XCTAssertEqual(try trackEntries(cli), try trackEntries(app))

        let log = "annotations/manual-annotation-provenance.json"
        let appEntry = try entry(app, log)
        let cliEntry = try entry(cli, log)
        XCTAssertEqual(try comparable(cliEntry, bundle: cli), try comparable(appEntry, bundle: app))
        XCTAssertEqual(appEntry["argv"] as? [String], [
            LungfishAppIdentity.recordedToolName, "manual-annotation", "--bundle", app.path, "--chromosome", "chr1",
            "--start", "2", "--end", "9", "--name", "selection-feature", "--type", "gene", "--strand", "+",
        ])
        let cliArgv = try XCTUnwrap(cliEntry["argv"] as? [String])
        XCTAssertEqual(cliArgv, [CLICommandIdentity.executableName] + ReferenceBundleManualAnnotationService.annotationAddArguments(
            chromosome: "chr1", start: 2, end: 9, name: "selection-feature", type: "gene", strand: "+", bundleURL: cli
        ))
        let replay = try SequenceCommand.AddAnnotation.parse(Array(cliArgv.dropFirst(3)))
        XCTAssertEqual([replay.bundle, replay.chromosome, replay.name, replay.type, replay.strand], [cli.path, "chr1", "selection-feature", "gene", "+"])
        XCTAssertEqual([replay.start, replay.end], [2, 9])
    }

    func testAttachTrackWritesTheTrackAndRecordTheImportCenterWrites() async throws {
        let app = try SequenceEditFixture.referenceBundle(in: scratch.appendingPathComponent("app"))
        let cli = try SequenceEditFixture.referenceBundle(in: scratch.appendingPathComponent("cli"))
        let bed = try SequenceEditFixture.bedFile(in: scratch)
        _ = try await ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).attachAnnotationTrack(
            sourceURL: bed, bundleURL: app, trackID: "primers", trackName: nil
        )
        try await SequenceCommand.AttachTrack.parse([cli.path, bed.path, "--track-id", "primers", "--quiet"])
            .execute(emit: { _ in })

        let database = "annotations/primers.db"
        XCTAssertEqual(try rows(app, database).count, 2)
        XCTAssertEqual(try rows(cli, database), try rows(app, database))
        XCTAssertEqual(try trackEntries(cli), try trackEntries(app))

        let log = "annotations/primers-import-provenance.json"
        let appEntry = try entry(app, log)
        let cliEntry = try entry(cli, log)
        XCTAssertEqual(try comparable(cliEntry, bundle: cli), try comparable(appEntry, bundle: app))
        XCTAssertEqual(appEntry["argv"] as? [String], [
            LungfishAppIdentity.recordedToolName, "annotation-import", "--bundle", app.path, "--source", bed.path,
            "--track-id", "primers", "--track-name", "primers", "--format", "bed",
        ])
        XCTAssertEqual(cliEntry["argv"] as? [String], [
            CLICommandIdentity.executableName, "sequence", "attach-track", cli.path, bed.path, "--track-id=primers",
        ])
    }

    func testAttachTrackRefusesAMissingFileBeforeItWritesAnything() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        let manifestBefore = try Data(contentsOf: bundle.appendingPathComponent(BundleManifest.filename))
        let command = try SequenceCommand.AttachTrack.parse([
            bundle.path, scratch.appendingPathComponent("missing.gff3").path, "--quiet",
        ])
        var lines: [String] = []
        do {
            try await command.execute(emit: { lines.append($0) })
            XCTFail("a missing annotation file must refuse the attach")
        } catch {
            XCTAssertTrue("\(error)".contains("No annotation file"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(BundleManifest.filename)), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("annotations").path))
        XCTAssertEqual(lines, [], "events are off without --format json")
    }

    /// A refusal is an ArgumentParser `ValidationError`, which has no localized text, so the `failed`
    /// event used to say "The operation couldn't be completed. (ArgumentParser.ValidationError error
    /// 1.)". The app alerts with the event's message, so the event has to hold the refusal itself
    /// (2.10 A43 review, fix F2).
    func testAttachTrackFailedEventCarriesTheRefusal() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        let command = try SequenceCommand.AttachTrack.parse([
            bundle.path, scratch.appendingPathComponent("missing.gff3").path, "--format", "json",
        ])
        let lines = try await CLIEventTranscriptCoverageTests.eventLines(expectingFailure: true) {
            try await command.execute(emit: $0)
        }
        let message = try Self.failedMessage(in: lines)
        XCTAssertTrue(message.hasPrefix("No annotation file at"), message)
    }

    func testAddAnnotationFailedEventCarriesTheRefusal() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        let command = try SequenceCommand.AddAnnotation.parse([
            bundle.path, "--chromosome", "nope", "--start", "2", "--end", "9",
            "--name", "refused", "--type", "gene", "--strand", "+", "--format", "json",
        ])
        let lines = try await CLIEventTranscriptCoverageTests.eventLines(expectingFailure: true) {
            try await command.execute(emit: $0)
        }
        let message = try Self.failedMessage(in: lines)
        XCTAssertTrue(message.hasPrefix("The bundle holds no sequence named 'nope'"), message)
    }

    // MARK: - R2 of BIO-Q-A2 (lane 13.27). The caller gives the identity that its record names.

    /// The leaf is the CLI's caller of the writer, so the log it writes names `lungfish-cli` in `runtime.app` and argv[0].
    func testAddAnnotationLeafRecordNamesTheCLI() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        try await SequenceCommand.AddAnnotation.parse([
            bundle.path, "--chromosome", "chr1", "--start", "2", "--end", "9",
            "--name", "selection-feature", "--type", "gene", "--strand", "+", "--quiet",
        ]).execute(emit: { _ in })
        let recorded = try entry(bundle, "annotations/manual-annotation-provenance.json")
        XCTAssertEqual((recorded["runtime"] as? [String: Any])?["app"] as? String, "lungfish-cli")
        XCTAssertEqual((recorded["argv"] as? [String])?.first, "lungfish-cli")
    }

    /// The app builds the service with the recorded name, so a write with no argv from its caller starts with that name.
    func testAddAnnotationAppRecordNamesTheApp() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        _ = try await ReferenceBundleManualAnnotationService(toolName: LungfishAppIdentity.recordedToolName).addAnnotation(
            SequenceAnnotation(
                type: .gene, name: "selection-feature", chromosome: "chr1",
                intervals: [AnnotationInterval(start: 2, end: 9)], strand: .forward
            ),
            toBundleAt: bundle
        )
        let recorded = try entry(bundle, "annotations/manual-annotation-provenance.json")
        XCTAssertEqual((recorded["runtime"] as? [String: Any])?["app"] as? String, "Lungfish Genome Explorer")
        XCTAssertEqual((recorded["argv"] as? [String])?.first, "Lungfish Genome Explorer")
    }

    func testAttachTrackLeafRecordsNameTheCLIAndItsKind() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        let bed = try SequenceEditFixture.bedFile(in: scratch)
        try await SequenceCommand.AttachTrack.parse([bundle.path, bed.path, "--track-id", "primers", "--quiet"])
            .execute(emit: { _ in })
        try assertAttachRecordsName("lungfish-cli", kind: "cli", in: bundle)
    }

    func testAttachTrackAppRecordsNameTheAppAndItsKind() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch)
        let bed = try SequenceEditFixture.bedFile(in: scratch)
        _ = try await ReferenceBundleAnnotationImportService(
            toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind
        ).attachAnnotationTrack(sourceURL: bed, bundleURL: bundle, trackID: "primers", trackName: nil)
        try assertAttachRecordsName("Lungfish Genome Explorer", kind: "gui", in: bundle)
    }

    /// The import log's `toolName`, `runtime.app` and argv[0], and the bundle record's argv[0] and `tool.kind`, name the caller.
    private func assertAttachRecordsName(_ name: String, kind: String, in bundle: URL, line: UInt = #line) throws {
        let recorded = try entry(bundle, "annotations/primers-import-provenance.json")
        XCTAssertEqual(recorded["toolName"] as? String, name, line: line)
        XCTAssertEqual((recorded["runtime"] as? [String: Any])?["app"] as? String, name, line: line)
        XCTAssertEqual((recorded["argv"] as? [String])?.first, name, line: line)
        let canonical = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        ), line: line)
        XCTAssertEqual(canonical.argv.first, name, line: line)
        XCTAssertEqual(canonical.tool.kind, kind, line: line)
    }

    // MARK: Helpers

    /// The `error` text of the last `failed` event among the event lines.
    private static func failedMessage(in lines: [String]) throws -> String {
        let events = try lines.map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], $0)
        }
        let failed = try XCTUnwrap(events.last { $0["event"] as? String == "failed" }, "no failed event in \(lines)")
        return try XCTUnwrap(failed["error"] as? String, "\(failed)")
    }

    /// Each row as `name|type|chromosome|start|end|strand|attributes`, with the feature's random
    /// `ID=` attribute left out.
    private func rows(_ bundle: URL, _ path: String) throws -> [String] {
        let database = try AnnotationDatabase(url: bundle.appendingPathComponent(path))
        return database.queryByRegion(chromosome: "chr1", start: 0, end: 16).map { record in
            let attributes = (record.attributes ?? "").split(separator: ";").filter { !$0.hasPrefix("ID=") }
            return [record.name, record.type, record.chromosome, String(record.start), String(record.end), record.strand,
                    attributes.joined(separator: ";")].joined(separator: "|")
        }.sorted()
    }

    private func trackEntries(_ bundle: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(BundleManifest.load(from: bundle).annotations), as: UTF8.self)
    }

    private func entry(_ bundle: URL, _ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appendingPathComponent(path))
        let log = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        return try XCTUnwrap(entries.first)
    }

    /// The entry without its argv, times and random feature ID, with the output digests checked for
    /// presence and then left out, and with the bundle's path written as `<BUNDLE>`.
    private func comparable(_ entry: [String: Any], bundle: URL) throws -> String {
        var entry = entry
        // The caller names itself in `toolName` and `runtime.app` (R2 of BIO-Q-A2), so the two routes differ there by design.
        for key in ["argv", "recordedAt", "wallTimeSeconds", "toolName"] { entry[key] = nil }
        if var runtime = entry["runtime"] as? [String: Any] {
            runtime["app"] = nil
            entry["runtime"] = runtime
        }
        if var annotation = entry["annotation"] as? [String: Any] {
            annotation["id"] = nil
            entry["annotation"] = annotation
        }
        let outputs = try XCTUnwrap(entry["outputFileInfo"] as? [[String: Any]])
        XCTAssertFalse(outputs.isEmpty)
        entry["outputFileInfo"] = outputs.map { output -> [String: Any] in
            XCTAssertNotNil(output["sha256"] as? String, "\(output)")
            XCTAssertNotNil(output["sizeBytes"] as? Int, "\(output)")
            return ["path": output["path"] ?? ""]
        }
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: bundle.path, with: "<BUNDLE>")
    }
}
