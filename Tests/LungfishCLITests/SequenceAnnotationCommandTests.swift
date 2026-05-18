// SequenceAnnotationCommandTests.swift - CLI-backed sequence annotation workflow tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class SequenceAnnotationCommandTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-sequence-annotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testAnnotateORFsCreatesManifestTrackDatabaseAndProvenance() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "CCCATGAAATAAGGG")
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let preRunManifestSHA = try ProvenanceFileHasher.sha256(of: manifestURL)

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "3",
            "--end", "12",
            "--frames", "+1",
            "--min-length", "9",
            "--track-id", "orfs_chr1",
            "--track-name", "ORFs chr1",
            "--quiet"
        ])
        try await command.run()

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.count, 1)
        let track = try XCTUnwrap(manifest.annotations.first)
        XCTAssertEqual(track.id, "orfs_chr1")
        XCTAssertEqual(track.name, "ORFs chr1")
        XCTAssertEqual(track.annotationType, .orf)
        XCTAssertEqual(track.path, "annotations/orfs_chr1.bed")
        XCTAssertEqual(track.databasePath, "annotations/orfs_chr1.db")
        XCTAssertEqual(track.featureCount, 1)

        let dbURL = bundleURL.appendingPathComponent("annotations/orfs_chr1.db")
        let database = try AnnotationDatabase(url: dbURL)
        let records = database.query(types: ["ORF"], limit: 10)
        XCTAssertEqual(records.count, 1)
        let row = try XCTUnwrap(records.first)
        XCTAssertEqual(row.type, "ORF")
        XCTAssertEqual(row.chromosome, "chr1")
        XCTAssertEqual(row.start, 3)
        XCTAssertEqual(row.end, 12)
        XCTAssertEqual(row.strand, "+")
        let attributes = AnnotationDatabase.parseAttributes(try XCTUnwrap(row.attributes))
        XCTAssertEqual(attributes["frame"], "+1")
        XCTAssertEqual(attributes["length_nt"], "9")
        XCTAssertEqual(attributes["length_aa"], "3")
        XCTAssertEqual(attributes["genetic_code_table"], "1")
        XCTAssertEqual(attributes["sequence"], "chr1")
        XCTAssertEqual(attributes["range_start"], "3")
        XCTAssertEqual(attributes["range_end"], "12")

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/bundle.lungfish-provenance.json").path))

        let dbSidecarURL = bundleURL.appendingPathComponent("provenance/annotations/orfs_chr1.db.lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbSidecarURL.path))
        let dbEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: dbSidecarURL))
        XCTAssertEqual(dbEnvelope.output?.path, dbURL.path)
        XCTAssertEqual(dbEnvelope.argv.first, "lungfish-cli")
        XCTAssertEqual(dbEnvelope.steps.first?.argv.first, "lungfish-cli")
        XCTAssertEqual(dbEnvelope.steps.first?.argv, dbEnvelope.argv)
        let provenanceInputs = try XCTUnwrap(dbEnvelope.steps.first?.inputs)
        let inputPaths = Set(provenanceInputs.map(\.path))
        let fastaURL = bundleURL.appendingPathComponent("genome/sequence.fa")
        let faiURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        XCTAssertTrue(inputPaths.contains(manifestURL.path))
        XCTAssertTrue(inputPaths.contains(fastaURL.path))
        XCTAssertTrue(inputPaths.contains(faiURL.path))
        XCTAssertEqual(provenanceInputs.first { $0.path == manifestURL.path }?.format, .json)
        XCTAssertEqual(provenanceInputs.first { $0.path == manifestURL.path }?.role, .input)
        XCTAssertEqual(provenanceInputs.first { $0.path == manifestURL.path }?.checksumSHA256, preRunManifestSHA)
        XCTAssertEqual(
            dbEnvelope.steps.first?.outputs.first { $0.path == manifestURL.path }?.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: manifestURL)
        )
        XCTAssertEqual(provenanceInputs.first { $0.path == faiURL.path }?.format, .text)
        XCTAssertEqual(provenanceInputs.first { $0.path == faiURL.path }?.role, .index)
    }

    func testAnnotateORFsAcceptsVersionedSequenceAlias() async throws {
        let bundleURL = try makeReferenceBundle(
            chromosomeName: "MN908947",
            sequence: "CCCATGAAATAAGGG"
        )

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "MN908947.3",
            "--start", "3",
            "--end", "12",
            "--frames", "+1",
            "--min-length", "9",
            "--track-id", "orfs_mn908947",
            "--track-name", "ORFs MN908947",
            "--quiet"
        ])
        try await command.run()

        let dbURL = bundleURL.appendingPathComponent("annotations/orfs_mn908947.db")
        let database = try AnnotationDatabase(url: dbURL)
        let row = try XCTUnwrap(database.query(types: ["ORF"], limit: 10).first)
        XCTAssertEqual(row.chromosome, "MN908947")
        XCTAssertEqual(row.start, 3)
        XCTAssertEqual(row.end, 12)
    }

    func testDeleteAnnotationTrackRemovesManifestArtifactsAndWritesProvenance() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "CCCATGAAATAAGGG")
        let create = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "3",
            "--end", "12",
            "--frames", "+1",
            "--min-length", "9",
            "--track-id", "orfs_chr1",
            "--track-name", "ORFs chr1",
            "--quiet"
        ])
        try await create.run()

        let delete = try SequenceCommand.DeleteAnnotationTrack.parse([
            bundleURL.path,
            "--track-id", "orfs_chr1",
            "--quiet"
        ])
        try await delete.run()

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_chr1.bed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_chr1.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/annotations/orfs_chr1.db.lungfish-provenance.json").path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: bundleURL.appendingPathComponent(".lungfish-provenance.json")))
        XCTAssertEqual(envelope.workflowName, "lungfish sequence delete-annotation-track")
        XCTAssertTrue(envelope.argv.contains("delete-annotation-track"))
        XCTAssertEqual(envelope.options.resolvedDefaults["track_id"]?.stringValue, "orfs_chr1")
        XCTAssertEqual(envelope.options.resolvedDefaults["track_name"]?.stringValue, "ORFs chr1")
        XCTAssertEqual(envelope.steps.first?.exitStatus, 0)
        XCTAssertEqual(
            envelope.steps.first?.outputs.first { $0.path == bundleURL.appendingPathComponent(BundleManifest.filename).path }?.role,
            .output
        )
    }

    func testDeleteAnnotationTrackRejectsEscapingManifestPayloadPathWithoutMutation() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "CCCATGAAATAAGGG")
        let escapedURL = tempDirectory.appendingPathComponent("escaped.bed")
        try "outside\n".write(to: escapedURL, atomically: true, encoding: .utf8)

        let manifest = try BundleManifest.load(from: bundleURL)
        let malicious = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "evil",
            name: "Evil",
            path: "../escaped.bed",
            databasePath: nil,
            annotationType: .orf,
            featureCount: 1,
            source: "test"
        ))
        try malicious.save(to: bundleURL)

        let delete = try SequenceCommand.DeleteAnnotationTrack.parse([
            bundleURL.path,
            "--track-id", "evil",
            "--quiet"
        ])

        do {
            try await delete.run()
            XCTFail("Expected escaped manifest payload path to be rejected.")
        } catch let error as SequenceAnnotationWorkflowError {
            XCTAssertEqual(error, .invalidTrackPath("../escaped.bed"))
        } catch {
            XCTFail("Expected invalidTrackPath, got \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: escapedURL.path))
        XCTAssertEqual(try String(contentsOf: escapedURL, encoding: .utf8), "outside\n")
        XCTAssertEqual(try BundleManifest.load(from: bundleURL).annotations.map(\.id), ["evil"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
    }

    func testDeleteAnnotationTrackRejectsMissingTrackWithoutMutation() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "CCCATGAAATAAGGG")
        let delete = try SequenceCommand.DeleteAnnotationTrack.parse([
            bundleURL.path,
            "--track-id", "missing",
            "--quiet"
        ])

        do {
            try await delete.run()
            XCTFail("Expected missing track deletion to fail.")
        } catch let error as SequenceAnnotationWorkflowError {
            XCTAssertEqual(error, .trackNotFound("missing"))
        } catch {
            XCTFail("Expected trackNotFound, got \(error)")
        }

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
    }

    func testSequenceCommandOmitsStandaloneAnnotateTranslationsSubcommand() {
        let subcommands = SequenceCommand.configuration.subcommands.map { String(describing: $0) }

        XCTAssertTrue(subcommands.contains("AnnotateORFs"))
        XCTAssertFalse(subcommands.contains("AnnotateTranslations"))
        XCTAssertThrowsError(try SequenceCommand.parse([
            "annotate-translations",
            "/tmp/reference.lungfishref"
        ]))
    }

    func testAnnotateORFsRollsBackBundleMutationWhenProvenanceWriteFails() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "AATGAAATAA")
        let provenanceBlockerURL = bundleURL.appendingPathComponent("provenance")
        try "not a directory".write(to: provenanceBlockerURL, atomically: true, encoding: .utf8)

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "1",
            "--end", "10",
            "--frames", "+1",
            "--track-id", "orfs_fail",
            "--track-name", "ORFs fail",
            "--min-length", "3",
            "--quiet"
        ])

        do {
            try await command.run()
            XCTFail("Expected provenance failure to abort the ORF operation.")
        } catch {
            let manifest = try BundleManifest.load(from: bundleURL)
            XCTAssertTrue(manifest.annotations.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_fail.bed").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_fail.db").path))
        }
    }

    func testAnnotateORFsRestoresProvenanceArtifactsWhenSidecarWriteFailsMidLayout() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "AATGAAATAA")
        let provenanceURL = bundleURL.appendingPathComponent("provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: true)
        let annotationsBlockerURL = provenanceURL.appendingPathComponent("annotations")
        try "not a directory".write(to: annotationsBlockerURL, atomically: true, encoding: .utf8)

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "1",
            "--end", "10",
            "--frames", "+1",
            "--track-id", "orfs_fail",
            "--track-name", "ORFs fail",
            "--min-length", "3",
            "--quiet"
        ])

        do {
            try await command.run()
            XCTFail("Expected sidecar layout failure to abort the ORF operation.")
        } catch {
            let manifest = try BundleManifest.load(from: bundleURL)
            XCTAssertTrue(manifest.annotations.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_fail.bed").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_fail.db").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/bundle.lungfish-provenance.json").path))
            XCTAssertEqual(try String(contentsOf: annotationsBlockerURL, encoding: .utf8), "not a directory")
        }
    }

    func testDeleteAnnotationsRewritesTrackThenRemovesTrackWhenEmpty() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "ATGTAAATGTAA")
        let create = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "0",
            "--end", "12",
            "--frames", "+1",
            "--min-length", "6",
            "--track-id", "orfs_chr1",
            "--track-name", "ORFs chr1",
            "--quiet"
        ])
        try await create.run()

        let dbURL = bundleURL.appendingPathComponent("annotations/orfs_chr1.db")
        var rows = try AnnotationDatabase(url: dbURL).query(types: ["ORF"], limit: 10)
        XCTAssertEqual(rows.count, 2)

        let deleteOne = try SequenceCommand.DeleteAnnotations.parse([
            bundleURL.path,
            "--track-id", "orfs_chr1",
            "--row-id", String(try XCTUnwrap(rows[0].rowID)),
            "--quiet"
        ])
        try await deleteOne.run()

        var manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.first?.featureCount, 1)
        rows = try AnnotationDatabase(url: dbURL).query(types: ["ORF"], limit: 10)
        XCTAssertEqual(rows.count, 1)
        let bedRows = try String(contentsOf: bundleURL.appendingPathComponent("annotations/orfs_chr1.bed"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(bedRows.count, 1)

        let deleteLast = try SequenceCommand.DeleteAnnotations.parse([
            bundleURL.path,
            "--track-id", "orfs_chr1",
            "--row-id", String(try XCTUnwrap(try XCTUnwrap(rows.first).rowID)),
            "--quiet"
        ])
        try await deleteLast.run()

        manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_chr1.bed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("provenance/annotations/orfs_chr1.db.lungfish-provenance.json").path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: bundleURL.appendingPathComponent(".lungfish-provenance.json")))
        XCTAssertEqual(envelope.workflowName, "lungfish sequence delete-annotations")
        XCTAssertEqual(envelope.options.resolvedDefaults["track_id"]?.stringValue, "orfs_chr1")
        XCTAssertEqual(envelope.options.resolvedDefaults["deleted_count"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["removed_track"]?.booleanValue, true)
    }

    func testDeleteAnnotationsPreservesDBOnlyTrackWhenRowsRemain() async throws {
        let bundleURL = try makeReferenceBundle(sequence: String(repeating: "A", count: 200))
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        let sourceBEDURL = tempDirectory.appendingPathComponent("imported.bed")
        try [
            "chr1\t10\t30\tkeep\t0\t+\t10\t30\t0,0,0\t1\t20,\t0,\tgene\tgene=keep",
            "chr1\t40\t60\tdelete\t0\t+\t40\t60\t0,0,0\t1\t20,\t0,\tgene\tgene=delete",
        ].joined(separator: "\n").appending("\n").write(to: sourceBEDURL, atomically: true, encoding: .utf8)
        let dbURL = annotationsDir.appendingPathComponent("imported.db")
        try AnnotationDatabase.createFromBED(bedURL: sourceBEDURL, outputURL: dbURL)

        var manifest = try BundleManifest.load(from: bundleURL)
        manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "imported",
            name: "Imported",
            path: "annotations/imported.db",
            databasePath: "annotations/imported.db",
            annotationType: .custom,
            featureCount: 2,
            source: "test"
        ))
        try manifest.save(to: bundleURL)

        let deleteRowID = try XCTUnwrap(AnnotationDatabase(url: dbURL).query(nameFilter: "delete", limit: 10).first?.rowID)
        let delete = try SequenceCommand.DeleteAnnotations.parse([
            bundleURL.path,
            "--track-id", "imported",
            "--row-id", String(deleteRowID),
            "--quiet"
        ])
        try await delete.run()

        manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.first?.featureCount, 1)
        let rows = try AnnotationDatabase(url: dbURL).queryForTable(limit: 10)
        XCTAssertEqual(rows.map(\.name), ["keep"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: annotationsDir.appendingPathComponent("imported.bed").path))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: bundleURL.appendingPathComponent(".lungfish-provenance.json")
        ))
        XCTAssertEqual(envelope.workflowName, "lungfish sequence delete-annotations")
    }

    func testDeleteAnnotationsPreservesBED12BlockStructure() async throws {
        let bundleURL = try makeReferenceBundle(sequence: String(repeating: "A", count: 400))
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let bedURL = annotationsDir.appendingPathComponent("blocks.bed")
        try [
            "chr1\t10\t120\tmulti\t0\t+\t10\t120\t0,0,0\t2\t10,20,\t0,90,\tCDS\tgene=multi",
            "chr1\t150\t180\tdelete\t0\t+\t150\t180\t0,0,0\t1\t30,\t0,\tgene\tgene=delete",
        ].joined(separator: "\n").appending("\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = annotationsDir.appendingPathComponent("blocks.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)

        var manifest = try BundleManifest.load(from: bundleURL)
        manifest = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "blocks",
            name: "Blocks",
            path: "annotations/blocks.bed",
            databasePath: "annotations/blocks.db",
            annotationType: .custom,
            featureCount: 2,
            source: "test"
        ))
        try manifest.save(to: bundleURL)

        let deleteRowID = try XCTUnwrap(AnnotationDatabase(url: dbURL).query(nameFilter: "delete", limit: 10).first?.rowID)
        let delete = try SequenceCommand.DeleteAnnotations.parse([
            bundleURL.path,
            "--track-id", "blocks",
            "--row-id", String(deleteRowID),
            "--quiet"
        ])
        try await delete.run()

        let remaining = try XCTUnwrap(AnnotationDatabase(url: dbURL).queryForTable(limit: 10).first)
        XCTAssertEqual(remaining.name, "multi")
        XCTAssertEqual(remaining.blockCount, 2)
        XCTAssertEqual(remaining.blockSizes, "10,20,")
        XCTAssertEqual(remaining.blockStarts, "0,90,")
        let rewrittenBED = try String(contentsOf: bedURL, encoding: .utf8)
        XCTAssertTrue(rewrittenBED.contains("\t2\t10,20,\t0,90,\tCDS\tgene=multi"))
    }

    func testAnnotateORFsRejectsStalePayloadPathWithoutMutation() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "AATGAAATAA")
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let staleDBURL = annotationsDir.appendingPathComponent("orfs_stale.db")
        try "stale".write(to: staleDBURL, atomically: true, encoding: .utf8)

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "0",
            "--end", "10",
            "--frames", "+1",
            "--track-id", "orfs_stale",
            "--track-name", "ORFs stale",
            "--min-length", "3",
            "--quiet"
        ])

        do {
            try await command.run()
            XCTFail("Expected stale payload collision to fail.")
        } catch let error as SequenceAnnotationWorkflowError {
            XCTAssertEqual(error, .trackPayloadAlreadyExists("annotations/orfs_stale.db"))
        } catch {
            XCTFail("Expected trackPayloadAlreadyExists, got \(error)")
        }

        XCTAssertEqual(try String(contentsOf: staleDBURL, encoding: .utf8), "stale")
        XCTAssertTrue(try BundleManifest.load(from: bundleURL).annotations.isEmpty)
    }

    func testUnsafeTrackIDIsRejectedBeforeWritingOutsideBundle() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "AATGAAATAA")
        let escapedStemURL = tempDirectory.appendingPathComponent("escaped_orf")

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "1",
            "--end", "10",
            "--frames", "+1",
            "--track-id", "../../escaped_orf",
            "--track-name", "Escaped ORF",
            "--quiet"
        ])

        do {
            try await command.run()
            XCTFail("Unsafe track IDs must be rejected before any output paths are written.")
        } catch let error as SequenceAnnotationWorkflowError {
            XCTAssertEqual(error, .invalidTrackID("../../escaped_orf"))
        } catch {
            XCTFail("Expected invalid track ID error, got \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedStemURL.appendingPathExtension("bed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedStemURL.appendingPathExtension("db").path))
        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertTrue(manifest.annotations.isEmpty)
    }

    func testTrackIDAllowsOnlyPortableBundleLocalNames() async throws {
        let bundleURL = try makeReferenceBundle(sequence: "AATGAAATAA")

        let command = try SequenceCommand.AnnotateORFs.parse([
            bundleURL.path,
            "--sequence", "chr1",
            "--start", "1",
            "--end", "10",
            "--frames", "+1",
            "--track-id", "orfs_chr1-1",
            "--track-name", "ORFs chr1",
            "--min-length", "3",
            "--quiet"
        ])
        try await command.run()

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.annotations.first?.id, "orfs_chr1-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("annotations/orfs_chr1-1.db").path))
    }

    func testAnnotateORFsParseDefaultsAndOptions() throws {
        let orf = try SequenceCommand.AnnotateORFs.parse([
            "/tmp/reference.lungfishref",
            "--sequence", "chr2",
            "--start", "5",
            "--end", "77",
            "--track-id", "custom_orfs",
            "--track-name", "Custom ORFs"
        ])

        XCTAssertEqual(orf.bundle, "/tmp/reference.lungfishref")
        XCTAssertEqual(orf.sequence, "chr2")
        XCTAssertEqual(orf.start, 5)
        XCTAssertEqual(orf.end, 77)
        XCTAssertEqual(orf.frames, "+1,+2,+3,-1,-2,-3")
        XCTAssertEqual(orf.table, 1)
        XCTAssertEqual(orf.minLength, 100)
        XCTAssertFalse(orf.includePartial)
        XCTAssertFalse(orf.allowAlternativeStarts)
        XCTAssertEqual(orf.trackID, "custom_orfs")
        XCTAssertEqual(orf.trackName, "Custom ORFs")

        XCTAssertThrowsError(try SequenceCommand.parse([
            "annotate-translations",
            "/tmp/reference.lungfishref"
        ]))
    }

    private func makeReferenceBundle(
        chromosomeName: String = "chr1",
        sequence: String
    ) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let fastaContent = ">\(chromosomeName)\n\(sequence)\n"
        let fastaURL = genomeDir.appendingPathComponent("sequence.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let offset = ">\(chromosomeName)\n".utf8.count
        let faiContent = "\(chromosomeName)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
        try faiContent.write(
            to: genomeDir.appendingPathComponent("sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.tiny",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosomeName,
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
