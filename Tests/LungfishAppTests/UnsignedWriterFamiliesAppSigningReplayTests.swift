// UnsignedWriterFamiliesAppSigningReplayTests.swift - App operation and import records are signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10), M3, family S3. The records that the app's operations and imports open a bundle with were
// built with `ProvenanceWriter(signingProvider: nil)` and never signed. This runs the sample metadata import in process
// with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the test's folder, then an Inspector edit of
// the imported metadata, which publishes the refreshed record through `SampleMetadataEditPersistenceService`. Both writes
// of the one record sign together (`SampleMetadataBundleImportService.swift:153` and `:235`), since a keyless rewrite of
// a signed record would leave a pair that fails. After each write the record at its final path must verify and name
// exactly one signature, made by the local provider.
//
// It sets a process variable, so its name ends in ReplayTests and it runs in the integration tier. With no key the writer
// takes the same path as before and writes the same bytes, which `GenotypeSampleMetadataImportTests` and the other pins of
// the S3 families hold.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class UnsignedWriterFamiliesAppSigningReplayTests: XCTestCase {
    func testSampleMetadataImportAndInspectorEditRecordsAreSigned() throws {
        let scratch = try TestTempDirectory.make(prefix: "sample-metadata-record-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        let bundleURL = scratch.appendingPathComponent("result.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
        let sourceURL = scratch.appendingPathComponent("metadata.tsv")
        let data = Data("sample\tsite\nS1\tHilo\n".utf8)
        try data.write(to: sourceURL)
        let scan = try SampleMetadataStore.scanForSampleColumn(csvData: data, knownSampleIds: ["S1"])

        let result = try SampleMetadataBundleImportService().importMetadata(
            data: data, sourceURL: sourceURL, scanResult: scan,
            sampleColumnIndex: try XCTUnwrap(scan.bestColumn).index,
            knownSampleIds: ["S1"], bundleURL: bundleURL
        )
        let record = try XCTUnwrap(result.provenanceURL, "the import returned no record")
        XCTAssertEqual(record.lastPathComponent, ProvenanceWriter.provenanceFilename)
        try assertSignedOnce(record, "the sample metadata import")

        try result.store.applyEdit(sampleId: "S1", column: "site", newValue: "Kona")
        XCTAssertEqual(result.store.records["S1"]?["site"], "Kona", "the edit did not reach the store")
        try assertSignedOnce(record, "the Inspector edit of the imported metadata")
    }

    /// The record must verify at the path it ends at and name exactly one signature, made by the local provider.
    private func assertSignedOnce(_ record: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: record.path), "\(what) left no record at \(record.path)", file: file, line: line)
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "no signature beside the record of \(what) though a key is set", file: file, line: line
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "no public key beside the record of \(what) though a key is set", file: file, line: line
        )
        XCTAssertTrue(
            try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid,
            "the record of \(what) does not verify", file: file, line: line
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: record))
        XCTAssertEqual(
            envelope.signatures.map(\.provider), [ProvenanceSigningConfiguration.localProviderID],
            "the record of \(what) must name exactly one signature, made by the local provider", file: file, line: line
        )
    }
}
