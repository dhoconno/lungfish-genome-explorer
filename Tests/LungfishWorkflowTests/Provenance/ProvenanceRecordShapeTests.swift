// ProvenanceRecordShapeTests.swift - The reader says which shape decoded and what it filled in itself
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// `ProvenanceEnvelopeReader.read` reports which decoder accepted a record and whether the reader
/// invented its date or derived its status (plan decision V6). The Older record format label,
/// for the bare run and primitive shapes only, is lane P7b's. `load` and `decode` keep their
/// behaviour.
final class ProvenanceRecordShapeTests: XCTestCase {
    func testEveryCorpusCaseReadsAsTheShapeItsManifestNames() throws {
        let shapes: [String: ProvenanceEnvelopeReader.RecordShape] = [
            "S1": .envelope, "S2": .envelope, "S3": .workflowRun, "S4": .primitive,
        ]
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: materialized.sidecar))
            XCTAssertEqual(reading.shape, shapes[item.shape], "shape of \(item.id)")
        }
    }

    /// `read` returns what `load` returns. Ids a record lacks are generated on each decode, so the
    /// two are compared by their facts.
    func testReadReturnsTheEnvelopeLoadReturns() throws {
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: materialized.sidecar))
            let viaRead = try ProvenanceCompatFacts.project(
                envelope: reading.envelope,
                sidecar: materialized.sidecar,
                projectRoot: materialized.projectRoot
            )
            let viaLoad = try ProvenanceCompatFacts.project(sidecar: materialized.sidecar, projectRoot: materialized.projectRoot)
            XCTAssertEqual(viaRead.differences(from: viaLoad), [], item.id)
            XCTAssertEqual(reading.envelope.createdAt, try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar)).createdAt)
        }
    }

    func testOnlyAPrimitiveRecordWithoutADateHasItsDateInvented() throws {
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: materialized.sidecar))
            XCTAssertFalse(reading.createdAtWasInvented, "\(item.id) records its date")
        }

        let directory = try TestTempDirectory.make(prefix: "provenance-record-shape")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let dateless = Data(#"{"operation": "tree", "toolName": "iqtree2", "exitStatus": 0}"#.utf8)
        try dateless.write(to: sidecar)
        let fileDate = Date(timeIntervalSince1970: 1_777_777_776)
        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: sidecar.path)

        let fromFile = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: sidecar))
        XCTAssertEqual(fromFile.shape, .primitive)
        XCTAssertTrue(fromFile.createdAtWasInvented)
        XCTAssertEqual(fromFile.envelope.createdAt, fileDate, "the file's date, as before")

        let fromBytes = try ProvenanceEnvelopeReader.read(dateless)
        XCTAssertTrue(fromBytes.createdAtWasInvented)
        XCTAssertEqual(fromBytes.envelope.createdAt, Date(timeIntervalSince1970: 0), "1970 when there is no file, as before")

        let dated = try ProvenanceEnvelopeReader.read(Data(#"{"assembler": "SPAdes", "assembly_date": "2026-05-12T18:41:18Z"}"#.utf8))
        XCTAssertEqual(dated.shape, .primitive)
        XCTAssertFalse(dated.createdAtWasInvented)
    }

    /// A typed mapping record keeps its own schema and is never the Older record format, so the
    /// shape a consumer gets for the record the finder returns must not be a legacy shape.
    func testTheShapeOfAFoundMappingRecordIsNotALegacyShape() throws {
        let mapping = try ProvenanceHonestRuntimeTests.saveMappingRecord()
        defer { mapping.cleanup() }
        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceReading(for: mapping.folder))
        XCTAssertEqual(found.sidecarURL.lastPathComponent, MappingProvenance.filename)
        let shape = found.reading.shape
        XCTAssertNotEqual(shape, .primitive, "a typed mapping record never reads Older record format")
        XCTAssertNotEqual(shape, .workflowRun, "a typed mapping record never reads Older record format")
        XCTAssertEqual(shape, .typedRecord)
        XCTAssertFalse(found.reading.statusWasRecorded, "the status is derived from the exit status")
        XCTAssertFalse(found.reading.createdAtWasInvented)
        XCTAssertNil(found.reading.envelope.runtimeIdentity.appVersion)
    }

    /// The finder returns each corpus case for the item a user selects, with the shape its manifest
    /// names and the envelope `findProvenanceEnvelope(for:)` returns.
    func testTheFinderReturnsEachCorpusSelectionWithItsShape() throws {
        let shapes: [String: ProvenanceEnvelopeReader.RecordShape] = [
            "S1": .envelope, "S2": .envelope, "S3": .workflowRun, "S4": .primitive,
        ]
        var checked = 0
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            guard let selection = materialized.selection else { continue }
            let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceReading(for: selection), item.id)
            XCTAssertEqual(found.sidecarURL.standardizedFileURL, materialized.sidecar.standardizedFileURL, item.id)
            XCTAssertEqual(found.reading.shape, shapes[item.shape], "shape of \(item.id)")
            let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: selection), item.id)
            XCTAssertEqual(envelope.sidecarURL.standardizedFileURL, found.sidecarURL.standardizedFileURL, item.id)
            let readFacts = try ProvenanceCompatFacts.project(
                envelope: found.reading.envelope, sidecar: found.sidecarURL, projectRoot: materialized.projectRoot
            )
            let envelopeFacts = try ProvenanceCompatFacts.project(
                envelope: envelope.envelope, sidecar: envelope.sidecarURL, projectRoot: materialized.projectRoot
            )
            XCTAssertEqual(readFacts.differences(from: envelopeFacts), [], item.id)
            checked += 1
        }
        XCTAssertEqual(checked, try ProvenanceCompatCorpus.cases().count, "every corpus case has a selection")
    }

    /// A record that states no status has one derived from its exit status.
    func testTheReaderSaysWhetherTheRecordStatesItsStatus() throws {
        let stated: [String: Bool] = [
            "s1-db-receipt-kraken2-viral": true,
            "s1-cancelled-single-step": true,
            "s1-recorder-readsetplan": true,
            "s1-canonical-envelope-run": true,
            "s2-analysis-kraken2-fixture": false,
            "s3-ncbi-fetch-alpha11": true,
            "s3-write-sidecar-bare-run": true,
            "s3-gatk-container-bare-run": true,
            "s4-mcm-mhcref-shipped": false,
            "s4-msa-mafft-2026-05": false,
        ]
        XCTAssertEqual(Set(stated.keys), Set(try ProvenanceCompatCorpus.cases().map(\.id)))
        for (id, expected) in stated {
            let materialized = try ProvenanceCompatCorpus.materialize(id)
            defer { materialized.cleanup() }
            let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: materialized.sidecar))
            XCTAssertEqual(reading.statusWasRecorded, expected, "stated status of \(id)")
        }

        let unknownWord = Data(#"{"createdAt": "2026-10-10T00:00:00Z", "runtimeIdentity": {}, "status": "succeeded", "exitStatus": 0}"#.utf8)
        let reading = try ProvenanceEnvelopeReader.read(unknownWord)
        XCTAssertEqual(reading.shape, .envelope)
        XCTAssertFalse(reading.statusWasRecorded, "a word that names no status reads as absent")
        XCTAssertEqual(reading.envelope.status, .completed)
    }
}
