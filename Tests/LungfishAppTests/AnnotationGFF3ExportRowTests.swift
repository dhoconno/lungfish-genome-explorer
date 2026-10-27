// AnnotationGFF3ExportRowTests.swift - The Operations row of the GFF3 annotation export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling 1.5 rule 3 and the ARCH ruling on 12.39 R2. `AppDelegate.beginAnnotationGFF3ExportOperation`
// begins an export row with no lock and a cancel callback, records the `bundle export-gff3` command the runner runs,
// and launches nothing when the row is refused. An open document's annotations reach the leaf in a selection file
// written before the row begins.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishWorkflow

@MainActor
private final class GFF3FailureCalls {
    var messages: [String] = []
}

@MainActor
final class AnnotationGFF3ExportRowTests: XCTestCase {
    private let bundleInvocation = AnnotationGFF3Export.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.39/Reference, one.lungfishref", isDirectory: true),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/annotations, all.gff3"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Annotations as GFF3")
        XCTAssertEqual(item.initialDetail, "Writing annotations, all.gff3 from Reference, one")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: BundleExportGFF3Subcommand.self)
        XCTAssertEqual(command.invocation(), bundleInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.39/Reference, one.lungfishref")
        XCTAssertNil(command.selectionPath)
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    /// ARCH ruling 1.3. An open document's annotations, frozen at the click, go to a selection file in a new inputs
    /// folder beside the output before `begin`, and the invocation names that file and no bundle.
    func testAnOpenDocumentWritesItsSelectionBeforeTheRow() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationGFF3ExportRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let annotations = [SequenceAnnotation(type: .gene, name: "unsaved", chromosome: "chr1", start: 1, end: 9)]
        let invocation = try AppDelegate.annotationGFF3ExportInvocation(
            annotations: annotations,
            source: .init(kind: .openDocument, urls: [folder.appendingPathComponent("doc.gb")], name: "Doc"),
            outputURL: folder.appendingPathComponent("doc.gff3")
        )
        XCTAssertNil(invocation.bundle)
        let selection = try ViewerExportSelection.read(from: URL(fileURLWithPath: try XCTUnwrap(invocation.selection)))
        XCTAssertEqual(selection.documentAnnotations?.sourceName, "Doc")
        XCTAssertEqual(selection.documentAnnotations?.annotations.map(\.name), ["unsaved"])
        XCTAssertEqual(selection.schemaVersion, 2)
        XCTAssertTrue(invocation.selection?.contains("/.lungfish-export-inputs/") == true)
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: BundleExportGFF3Subcommand.self)
        XCTAssertEqual(command.invocation(), bundleInvocation)
    }

    /// A leaf that fails fails the run, and `onFailure` gets its message once, which the app shows under the base's
    /// "Annotation export failed" (UX 1).
    func testAFailedLeafReachesTheFailureHandlerWithItsMessage() async throws {
        let calls = GFF3FailureCalls()
        let begun = try XCTUnwrap(AppDelegate.beginAnnotationGFF3ExportOperation(
            invocation: bundleInvocation,
            sourceName: "Reference, one",
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { failure in calls.messages.append(failure.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertEqual(calls.messages, [failure.message])
    }

    // MARK: - Stored IDs (lane 13.20 M2, BIO ruling on the ID source of a GFF3 export)

    /// Every load of a database gave its records new UUIDs and the writer printed them as `ID=`, so two exports of one
    /// bundle differed on every line. A database row now exports its stored ID, or `lungfish-row-<rowID>` with none.
    func testTwoExportsOfOneBundleWriteTheSameBytes() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try AnnotationExportCLIGUIParityReplayTests.makeFixture(folder)
        let bundle = AnnotationExportCLIGUIParityReplayTests.bundleURL(in: folder)
        let first = folder.appendingPathComponent("first.gff3")
        let second = folder.appendingPathComponent("second.gff3")
        for output in [first, second] {
            let loaded = try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: bundle)
            try await GFF3Writer.write(loaded.annotations, to: output, source: AnnotationGFF3Export.featureSource)
        }
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "two exports of one bundle are one file")
    }

    func testABundleExportKeepsStoredIDsAndEveryParentResolves() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try makeBundle(in: folder, tracks: [("genes", [
            BEDRow("gene-a", "gene", 100, 900, "ID=gene-a"),
            BEDRow("tx-a", "mRNA", 100, 900, "ID=tx-a;Parent=gene-a"),
            BEDRow("cds-a", "CDS", 200, 800, "ID=cds-a;Parent=tx-a;lungfish_gff_phase=1"),
            BEDRow("orphan", "gene", 1000, 1100, "gene_id=orphan"),
        ])])
        let column9 = try await exportedColumnNine(of: bundle, in: folder)
        let attributes = column9.map { AnnotationDatabase.parseAttributes($0) }
        XCTAssertTrue(column9.contains { $0.hasPrefix("ID=gene-a;") }, "the gene keeps its stored ID\n\(column9)")
        let defined = Set(attributes.compactMap { $0["ID"] })
        for (index, pairs) in attributes.enumerated() {
            for part in (pairs["Parent"] ?? "").split(separator: ",") {
                XCTAssertTrue(defined.contains(String(part)), "Parent \(part) of line \(index) names no ID of the file\n\(column9)")
            }
        }
        for key in ["lungfish_gff_phase", "annotation_db_row_id", "annotation_db_track_id"] {
            XCTAssertFalse(column9.contains { $0.contains(key) }, "column 9 holds \(key)\n\(column9)")
        }
        let orphan = try rowID(of: "orphan", track: "genes", in: bundle)
        XCTAssertTrue(column9.contains { $0.hasPrefix("ID=lungfish-row-\(orphan);Name=orphan") }, "the row with no ID takes its row key\n\(column9)")
    }

    func testTwoTracksThatShareAnIDKeepOneIDPerFeature() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func track(_ id: String) -> (id: String, rows: [BEDRow]) {
            (id, [
                BEDRow("gene-S", "gene", 100, 900, "ID=gene-S"),
                BEDRow("cds-S", "CDS", 200, 800, "ID=cds-S;Parent=gene-S"),
                BEDRow("orphan-S", "gene", 1000, 1100, "gene_id=S"),
            ])
        }
        let bundle = try makeBundle(in: folder, tracks: [track("a"), track("b")])
        let column9 = try await exportedColumnNine(of: bundle, in: folder)
        XCTAssertEqual(column9.count, 6, "three single-block rows a track\n\(column9)")
        // The loader writes track a's rows, then track b's.
        func features(_ range: Range<Int>) -> [String: (id: String, parent: String?)] {
            Dictionary(uniqueKeysWithValues: range.map { index in
                let pairs = AnnotationDatabase.parseAttributes(column9[index])
                // A row whose name is only its ID exports no Name (lane GFF3-FIDELITY), so its ID less the `b:` track prefix names it.
                let id = pairs["ID"] ?? ""
                let name = pairs["Name"] ?? String(id.split(separator: ":").last ?? "")
                return (name, (id, pairs["Parent"]))
            })
        }
        let a = features(0..<3)
        let b = features(3..<6)
        let keyA = try rowID(of: "orphan-S", track: "a", in: bundle)
        let keyB = try rowID(of: "orphan-S", track: "b", in: bundle)
        XCTAssertEqual(a["gene-S"]?.id, "gene-S")
        XCTAssertEqual(a["cds-S"]?.id, "cds-S")
        XCTAssertEqual(a["cds-S"]?.parent, "gene-S")
        XCTAssertEqual(a["orphan-S"]?.id, "lungfish-row-\(keyA)")
        XCTAssertEqual(b["gene-S"]?.id, "b:gene-S")
        XCTAssertEqual(b["cds-S"]?.id, "b:cds-S")
        XCTAssertEqual(b["cds-S"]?.parent, "b:gene-S")
        XCTAssertEqual(b["orphan-S"]?.id, "b:lungfish-row-\(keyB)")
        let ids = column9.compactMap { AnnotationDatabase.parseAttributes($0)["ID"] }
        XCTAssertEqual(Set(ids).count, ids.count, "no ID belongs to two features\n\(ids)")
    }

    // MARK: - Fixtures for the stored-ID tests

    /// One BED row of 14 columns, built the way the parity fixture builds its rows, so the row's stored attributes are `attributes`.
    private struct BEDRow {
        let name: String
        let type: String
        let start: Int
        let end: Int
        let attributes: String

        init(_ name: String, _ type: String, _ start: Int, _ end: Int, _ attributes: String) {
            self.name = name
            self.type = type
            self.start = start
            self.end = end
            self.attributes = attributes
        }

        var line: String {
            "chr1\t\(start)\t\(end)\t\(name)\t0\t+\t\(start)\t\(end)\t0,0,0\t1\t\(end - start)\t0\t\(type)\t\(attributes)\n"
        }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationGFF3ExportID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A reference bundle with one annotation database a track, in the given order.
    private func makeBundle(in folder: URL, tracks: [(id: String, rows: [BEDRow])]) throws -> URL {
        let bundle = folder.appendingPathComponent("tracks.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("annotations"), withIntermediateDirectories: true)
        var infos: [AnnotationTrackInfo] = []
        for track in tracks {
            let bed = folder.appendingPathComponent("\(track.id).bed")
            try track.rows.map(\.line).joined().write(to: bed, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/\(track.id).db"))
            infos.append(AnnotationTrackInfo(
                id: track.id, name: track.id, path: "annotations/\(track.id).bb", databasePath: "annotations/\(track.id).db"
            ))
        }
        try BundleManifest(
            name: "Stored ID fixture",
            identifier: "org.lungfish.gff3-stored-id-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: nil,
            annotations: infos,
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    /// Column 9 of each feature line of the bundle's export through the loader and `GFF3Writer`, in file order.
    private func exportedColumnNine(of bundle: URL, in folder: URL) async throws -> [String] {
        let output = folder.appendingPathComponent("export.gff3")
        let loaded = try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: bundle)
        try await GFF3Writer.write(loaded.annotations, to: output, source: AnnotationGFF3Export.featureSource)
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false)[8] }
            .map(String.init)
    }

    private func rowID(of name: String, track: String, in bundle: URL) throws -> Int64 {
        let database = try AnnotationDatabase(url: bundle.appendingPathComponent("annotations/\(track).db"))
        return try XCTUnwrap(database.query(limit: Int.max).first { $0.name == name }?.rowID)
    }
}
