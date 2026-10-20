// ProvenanceAdoptedTrackMappingRecordTests.swift - An older bundle's shared mapping record reads only for the track whose digest matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.16, item 3 of the BIO ruling on REC-RUN. Before 2.13 every `bam adopt-mapping` saved its
/// mapping record as the shared `alignments/mapped/mapping-provenance.json`, so the file holds the last adopt's
/// record, and each adopt record gave the file the digest it had when that adopt wrote it.
final class ProvenanceAdoptedTrackMappingRecordTests: XCTestCase {
    private var temporaryRoot: URL!
    private var bundle: URL!
    private var mapped: URL!

    override func setUpWithError() throws {
        temporaryRoot = try TestTempDirectory.make(prefix: "provenance-adopted-track")
        bundle = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Older.lungfish/Sample.lungfishref", isDirectory: true)
        mapped = bundle.appendingPathComponent("alignments/mapped", isDirectory: true)
        try FileManager.default.createDirectory(at: mapped, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testAnOlderBundlesSharedMappingRecordReadsOnlyForTheTrackWhoseDigestMatches() throws {
        let shared = mapped.appendingPathComponent(MappingProvenance.filename)
        let firstBAM = try adoptAsBefore213(trackID: "first", sample: "first-sample", shared: shared)
        let secondBAM = try adoptAsBefore213(trackID: "second", sample: "second-sample", shared: shared)
        let sharedBytes = try Data(contentsOf: shared)

        XCTAssertNil(
            ProvenanceRecorder.adoptedTrackMappingRecord(forAlignmentAt: firstBAM),
            "the shared file holds the second adopt's record, which is never shown as the first track's"
        )
        let found = try XCTUnwrap(ProvenanceRecorder.adoptedTrackMappingRecord(forAlignmentAt: secondBAM))
        XCTAssertEqual(found.sidecarURL.standardizedFileURL.path, shared.standardizedFileURL.path)
        XCTAssertEqual(found.reading.shape, .typedRecord)
        XCTAssertEqual(MappingProvenance.load(fromFile: shared)?.sampleName, "second-sample")
        XCTAssertEqual(try Data(contentsOf: shared), sharedBytes, "a read never rewrites an older bundle")
    }

    func testATracksOwnMappingRecordReadsFirst() throws {
        let bam = mapped.appendingPathComponent("own.bam")
        try Data("bam".utf8).write(to: bam)
        let recordURL = MappingProvenance.trackRecordURL(forAlignmentAt: bam)
        try TrackRecordFixtures.mappingRecord(sample: "own-sample", in: temporaryRoot, bundle: bundle).save(toFile: recordURL)
        try writeAdoptRecord(trackID: "own", naming: "alignments/mapped/own.mapping-provenance.json", output: ProvenanceRecorder.fileRecord(url: recordURL, format: .json, role: .output))
        // A shared file of an older adopt in the same folder never stands in for a track that has its own record.
        try TrackRecordFixtures.mappingRecord(sample: "older-sample", in: temporaryRoot, bundle: bundle).save(to: mapped)

        let found = try XCTUnwrap(ProvenanceRecorder.adoptedTrackMappingRecord(forAlignmentAt: bam))
        XCTAssertEqual(found.sidecarURL.standardizedFileURL.path, recordURL.standardizedFileURL.path)
        XCTAssertEqual(found.reading.shape, .typedRecord)
    }

    /// Review Optional item 2 (SWIFT 6). An adopt record may name a path that leaves the bundle, through `..` or as an
    /// absolute path. The reader loads a named record only when its path stays inside the bundle.
    func testAMappingRecordNamedOutsideTheBundleIsNeverRead() throws {
        let outside = temporaryRoot.appendingPathComponent("outside.mapping-provenance.json")
        try TrackRecordFixtures.mappingRecord(sample: "outside-sample", in: temporaryRoot, bundle: bundle).save(toFile: outside)
        let output = ProvenanceRecorder.fileRecord(url: outside, format: .json, role: .output)
        for (trackID, path) in [("dotted", "../../../outside.mapping-provenance.json"), ("absolute", outside.path)] {
            let bam = mapped.appendingPathComponent("\(trackID).bam")
            try Data("bam".utf8).write(to: bam)
            try writeAdoptRecord(trackID: trackID, naming: path, output: output)
            XCTAssertNil(
                ProvenanceRecorder.adoptedTrackMappingRecord(forAlignmentAt: bam),
                "\(trackID): a record named outside the bundle is never read as the track's"
            )
        }
    }

    // MARK: Helpers

    /// Adopts a track as builds before 2.13 did: the BAM, the shared mapping record rewritten with this track's
    /// record, and an adopt record that names the shared file and gives it the digest it has now.
    private func adoptAsBefore213(trackID: String, sample: String, shared: URL) throws -> URL {
        let bam = mapped.appendingPathComponent("\(trackID).bam")
        try Data("bam-\(trackID)".utf8).write(to: bam)
        try TrackRecordFixtures.mappingRecord(sample: sample, in: temporaryRoot, bundle: bundle).save(to: mapped)
        try writeAdoptRecord(
            trackID: trackID,
            naming: "alignments/mapped/\(MappingProvenance.filename)",
            output: ProvenanceRecorder.fileRecord(url: shared, format: .json, role: .output)
        )
        return bam
    }

    private func writeAdoptRecord(trackID: String, naming mappingRecordPath: String, output: FileRecord) throws {
        let adoptPath = "alignments/mapped/\(trackID).\(ProvenanceRecorder.adoptRecordExtension)"
        let run = TrackRecordFixtures.run(
            named: "lungfish bam adopt-mapping",
            tool: "lungfish-cli",
            outputs: [
                ProvenanceRecorder.fileRecord(url: mapped.appendingPathComponent("\(trackID).bam"), format: .bam, role: .output),
                output,
            ],
            parameters: [
                "sourceMappingProvenancePath": .string(mappingRecordPath),
                "adoptMappingProvenancePath": .string(adoptPath),
            ]
        )
        try ProvenanceJSON.encoder.encode(run.canonicalEnvelope()).write(to: bundle.appendingPathComponent(adoptPath))
    }
}
