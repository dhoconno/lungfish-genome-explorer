// AppDelegateAnnotationEditOperationTests.swift - Annotation edits record the sequence command that reproduces them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// AppDelegate persists two annotation edits to a reference bundle, a rename or
// note edit and a delete, through ReferenceBundleManualAnnotationService. The
// rows used to record no command (R3). The service runs the
// SequenceAnnotationTrackWorkflow function `lungfish-cli sequence
// update-annotation` and `sequence delete-annotations` run, so the rows now
// record those commands. These tests parse each recorded command with the real
// CLI parser, check it carries every value the service passes, and run it on a
// copy of the bundle to show it writes what the service writes. The service's
// provenance used to record `Lungfish.app manual-annotation-update` and
// `manual-annotation-delete` (R8), and the provenance tests show it now records
// the row's command, built by the same service builder. The update's explicit
// options used to name only the track and the row, and now name every option
// that command passes.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class AppDelegateAnnotationEditOperationTests: XCTestCase {
    private var root: URL!
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1k2/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "annotation-edit-operation").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A `.lungfishref` bundle with one SQLite-backed annotation track
    /// ("imported") holding one gene, the shape
    /// ReferenceBundleAnnotationPersistenceTests builds.
    private func makeBundle(named name: String) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        try ">chr1\nACGTACGTACGTACGTACGTACGTACGTACGT\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t33\t6\t33\t34\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        let bedURL = root.appendingPathComponent("\(name)-import.bed")
        try "chr1\t2\t9\tgeneA\t0\t+\t2\t9\t0,0,0\t1\t7,\t0,\tgene\tID=geneA;gene=geneA\n".write(
            to: bedURL, atomically: true, encoding: .utf8
        )
        let featureCount = try AnnotationDatabase.createFromBED(
            bedURL: bedURL, outputURL: annotationsDir.appendingPathComponent("imported.db")
        )
        var manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 33,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 33, offset: 6, lineBases: 33, lineWidth: 34)]
            )
        )
        manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "imported",
            name: "Imported",
            path: "annotations/imported.db",
            databasePath: "annotations/imported.db",
            annotationType: .custom,
            featureCount: featureCount,
            source: "test"
        ))
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func storedRecords(in bundleURL: URL) throws -> [AnnotationDatabaseRecord] {
        let dbURL = bundleURL.appendingPathComponent("annotations/imported.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        return try AnnotationDatabase(url: dbURL).queryForTable(limit: 10)
    }

    /// The bundle's gene as the viewer hands it to AppDelegate, with the row
    /// location qualifiers, and with the edits the Inspector exposes applied.
    private func editedGene(in bundleURL: URL) throws -> (SequenceAnnotation, ReferenceBundleAnnotationRowLocation) {
        let record = try XCTUnwrap(try storedRecords(in: bundleURL).first)
        var annotation = record.toAnnotation()
        annotation.qualifiers["annotation_db_track_id"] = AnnotationQualifier("imported")
        let location = try XCTUnwrap(ReferenceBundleAnnotationRowLocation(annotation: annotation))
        annotation.name = "-geneA renamed"
        annotation.type = .exon
        annotation.strand = .reverse
        annotation.note = "Edited in the Inspector"
        return (annotation, location)
    }

    // MARK: - Update

    func testUpdateRowRecordsTheUpdateAnnotationCommandWithEveryValueTheServicePasses() throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (annotation, location) = try editedGene(in: bundleURL)
        let reporter = RecordingOperationReporter()

        let result = AppDelegate.beginAnnotationUpdateOperation(
            annotation: annotation, location: location, bundleURL: bundleURL, routeContext: routeContext, reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.title, "Update Annotation")
        XCTAssertEqual(item.initialDetail, "Updating -geneA renamed...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // The values ReferenceBundleManualAnnotationService.updateAnnotation
        // hands SequenceAnnotationTrackWorkflow.updateAnnotation.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.UpdateAnnotation.self)
        XCTAssertEqual(
            URL(fileURLWithPath: command.bundle, isDirectory: true).standardizedFileURL,
            bundleURL.standardizedFileURL
        )
        XCTAssertEqual(command.trackID, location.trackID)
        XCTAssertEqual(command.rowID, location.rowID)
        XCTAssertEqual(command.name, annotation.name, "a hyphen-leading name stays a value")
        XCTAssertEqual(command.type, annotation.type.rawValue)
        XCTAssertEqual(command.strand, annotation.strand.rawValue, "the reverse strand `-` stays a value")
        XCTAssertEqual(command.note, annotation.note)
    }

    func testUpdateRowWithNoNoteRecordsNoNoteOption() throws {
        let bundleURL = try makeBundle(named: "Sample")
        var (annotation, location) = try editedGene(in: bundleURL)
        annotation.note = nil
        let reporter = RecordingOperationReporter()

        AppDelegate.beginAnnotationUpdateOperation(
            annotation: annotation, location: location, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        )

        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(recorded.contains("--note"), recorded)
        XCTAssertNil(try RecordedCLICommand.parse(recorded, as: SequenceCommand.UpdateAnnotation.self).note)
    }

    func testRecordedUpdateCommandWritesTheEditTheAppServiceWrites() async throws {
        let appBundle = try makeBundle(named: "App")
        let cliBundle = try makeBundle(named: "CLI")
        let (appAnnotation, appLocation) = try editedGene(in: appBundle)
        let (cliAnnotation, cliLocation) = try editedGene(in: cliBundle)

        _ = try await ReferenceBundleManualAnnotationService().updateAnnotation(
            appLocation,
            name: appAnnotation.name,
            type: appAnnotation.type.rawValue,
            strand: appAnnotation.strand.rawValue,
            note: appAnnotation.note,
            bundleURL: appBundle
        )
        let reporter = RecordingOperationReporter()
        AppDelegate.beginAnnotationUpdateOperation(
            annotation: cliAnnotation, location: cliLocation, bundleURL: cliBundle, routeContext: nil, reporter: reporter
        )
        var command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: SequenceCommand.UpdateAnnotation.self)
        try await command.run()

        let app = try XCTUnwrap(try storedRecords(in: appBundle).first)
        let cli = try XCTUnwrap(try storedRecords(in: cliBundle).first)
        XCTAssertEqual(cli.name, "-geneA renamed")
        XCTAssertEqual(cli.name, app.name)
        XCTAssertEqual(cli.type, app.type)
        XCTAssertEqual(cli.strand, app.strand)
        XCTAssertEqual(cli.attributes, app.attributes)
        XCTAssertEqual(cli.chromosome, app.chromosome)
        XCTAssertEqual(cli.start, app.start)
        XCTAssertEqual(cli.end, app.end)
    }

    // MARK: - Delete

    func testDeletionRowRecordsTheDeleteAnnotationsCommandForTheRow() throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (_, location) = try editedGene(in: bundleURL)
        let reporter = RecordingOperationReporter()

        let result = AppDelegate.beginAnnotationDeletionOperation(
            location: location, bundleURL: bundleURL, routeContext: routeContext, reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.title, "Delete Annotation")
        XCTAssertEqual(item.initialDetail, "Deleting annotation...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // The values ReferenceBundleManualAnnotationService.deleteAnnotation
        // hands SequenceAnnotationTrackWorkflow.deleteAnnotations, as the
        // annotation drawer records them for the same row.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.DeleteAnnotations.self)
        XCTAssertEqual(
            URL(fileURLWithPath: command.bundle, isDirectory: true).standardizedFileURL,
            bundleURL.standardizedFileURL
        )
        XCTAssertEqual(command.trackID, location.trackID)
        XCTAssertEqual(command.rowIDs, [location.rowID])
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(
                subcommand: "sequence delete-annotations",
                args: Array(ReferenceBundleManualAnnotationService.annotationRowDeletionArguments(
                    bundleURL: bundleURL, trackID: location.trackID, rowIDs: [location.rowID]
                ).dropFirst(2))
            ),
            "the drawer's builder"
        )
    }

    func testRecordedDeleteCommandRemovesWhatTheAppServiceRemoves() async throws {
        let appBundle = try makeBundle(named: "App")
        let cliBundle = try makeBundle(named: "CLI")
        let (_, appLocation) = try editedGene(in: appBundle)
        let (_, cliLocation) = try editedGene(in: cliBundle)

        _ = try await ReferenceBundleManualAnnotationService().deleteAnnotation(appLocation, bundleURL: appBundle)
        let reporter = RecordingOperationReporter()
        AppDelegate.beginAnnotationDeletionOperation(
            location: cliLocation, bundleURL: cliBundle, routeContext: nil, reporter: reporter
        )
        var command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: SequenceCommand.DeleteAnnotations.self)
        try await command.run()

        XCTAssertEqual(try storedRecords(in: cliBundle).count, try storedRecords(in: appBundle).count)
        XCTAssertEqual(
            try BundleManifest.load(from: cliBundle).annotations.map(\.id),
            try BundleManifest.load(from: appBundle).annotations.map(\.id),
            "both remove the emptied track or neither does"
        )
    }

    // MARK: - Provenance (R8)

    func testUpdateProvenanceRecordsTheCommandTheRowRecords() async throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (annotation, location) = try editedGene(in: bundleURL)
        let reporter = RecordingOperationReporter()
        AppDelegate.beginAnnotationUpdateOperation(
            annotation: annotation, location: location, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        )
        let row = try XCTUnwrap(reporter.items.first?.cliCommand)

        let result = try await ReferenceBundleManualAnnotationService().updateAnnotation(
            location,
            name: annotation.name,
            type: annotation.type.rawValue,
            strand: annotation.strand.rawValue,
            note: annotation.note,
            bundleURL: bundleURL
        )

        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let rowArgv = [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: row))
        XCTAssertEqual(envelope.argv, rowArgv, "the provenance used to record Lungfish.app manual-annotation-update")
        XCTAssertEqual(envelope.steps.map(\.argv), [rowArgv])
    }

    func testDeleteProvenanceRecordsTheCommandTheRowRecords() async throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (_, location) = try editedGene(in: bundleURL)
        let reporter = RecordingOperationReporter()
        AppDelegate.beginAnnotationDeletionOperation(
            location: location, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        )
        let row = try XCTUnwrap(reporter.items.first?.cliCommand)

        let result = try await ReferenceBundleManualAnnotationService().deleteAnnotation(location, bundleURL: bundleURL)

        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let rowArgv = [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: row))
        XCTAssertEqual(envelope.argv, rowArgv, "the provenance used to record Lungfish.app manual-annotation-delete")
        XCTAssertEqual(envelope.steps.map(\.argv), [rowArgv])
    }

    func testUpdateProvenanceExplicitOptionsNameEveryOptionTheRecordedCommandPasses() async throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (annotation, location) = try editedGene(in: bundleURL)

        let result = try await ReferenceBundleManualAnnotationService().updateAnnotation(
            location,
            name: annotation.name,
            type: annotation.type.rawValue,
            strand: annotation.strand.rawValue,
            note: annotation.note,
            bundleURL: bundleURL
        )

        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let command = try RecordedCLICommand.parse(
            envelope.argv.map(shellEscape).joined(separator: " "),
            as: SequenceCommand.UpdateAnnotation.self
        )
        XCTAssertEqual(
            envelope.options.explicit,
            [
                "operation": .string("update-annotation"),
                "track_id": .string(command.trackID),
                "row_id": .integer(Int(command.rowID)),
                "name": .string(command.name),
                "type": .string(command.type),
                "strand": .string(command.strand),
                "note": .string(try XCTUnwrap(command.note)),
            ],
            "the explicit options used to name only the track and the row"
        )
    }

    func testUpdateProvenanceExplicitOptionsMatchTheEnvelopeTheRecordedCommandWrites() async throws {
        // The app's envelope and the one `lungfish-cli` writes when it runs
        // the row's command hold the same explicit options, with a note and
        // for an edit that clears it. The CLI used to leave the note out.
        for note in ["Edited in the Inspector", nil] {
            let label = note ?? "no note"
            let appBundle = try makeBundle(named: "App \(label)")
            let cliBundle = try makeBundle(named: "CLI \(label)")
            let (appAnnotation, appLocation) = try editedGene(in: appBundle)
            let (editedCLIGene, cliLocation) = try editedGene(in: cliBundle)
            var cliAnnotation = editedCLIGene
            cliAnnotation.note = note

            let appResult = try await ReferenceBundleManualAnnotationService().updateAnnotation(
                appLocation,
                name: appAnnotation.name,
                type: appAnnotation.type.rawValue,
                strand: appAnnotation.strand.rawValue,
                note: note,
                bundleURL: appBundle
            )
            let reporter = RecordingOperationReporter()
            AppDelegate.beginAnnotationUpdateOperation(
                annotation: cliAnnotation, location: cliLocation, bundleURL: cliBundle, routeContext: nil, reporter: reporter
            )
            let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: SequenceCommand.UpdateAnnotation.self)
            try await command.run()

            let appEnvelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: appResult.provenanceURL), label)
            let cliEnvelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: cliBundle), label)
            XCTAssertEqual(cliEnvelope.workflowName, "lungfish sequence update-annotation", label)
            XCTAssertEqual(appEnvelope.options.explicit, cliEnvelope.options.explicit, label)
            XCTAssertEqual(cliEnvelope.options.explicit["note"], note.map(ParameterValue.string), label)
        }
    }

    // MARK: - Refusal

    func testRefusedEditsReturnTheRefusalSoTheSiteRunsNoEdit() throws {
        let bundleURL = try makeBundle(named: "Sample")
        let (annotation, location) = try editedGene(in: bundleURL)
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let update = AppDelegate.beginAnnotationUpdateOperation(
            annotation: annotation, location: location, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        )
        let deletion = AppDelegate.beginAnnotationDeletionOperation(
            location: location, bundleURL: bundleURL, routeContext: nil, reporter: reporter
        )

        XCTAssertNil(update.startedID)
        XCTAssertNil(deletion.startedID)
        XCTAssertEqual(reporter.items.map(\.state), [.refused, .refused])
    }
}
