// GenotypeProvenancePayloadPinTests.swift - Pins of the genotype annotation records (Phase 2.13 lane 13.13, rows 12 and 13)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// Rows 12 and 13 of `BIO-13.12.md` F2 at the base. Each record is built from a fresh envelope with a new id and new
/// dates, so a pin cannot hold fixed bytes. It holds the relation between the published bytes and the encode of the
/// envelope they decode to, which stays true when the encode moves onto `ProvenanceWriter.package`.
@MainActor
final class GenotypeProvenancePayloadPinTests: XCTestCase {
    /// Row 13, `GenotypeCandidateDisplayPersistence.swift:105`. The record is `ProvenanceJSON.encoder`'s bytes.
    func testCandidateDisplayRecordIsTheProvenanceEncodingOfItsEnvelope() async throws {
        let bundle = try makeBundleURL()
        _ = try await GenotypeCandidateDisplayPersistence.persist(
            display: ONTMHCCandidateDisplaySettings(showKnown: false),
            expectedDisplay: .default,
            bundleURL: bundle,
            author: "analyst"
        )
        let bytes = try Data(contentsOf: provenanceURL(bundle))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(bytes)
        XCTAssertTrue(envelope.signatures.isEmpty)
        XCTAssertEqual(envelope.options.explicit["action"], .string("updateMHCCandidateDisplaySettings"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\\/"))
        XCTAssertEqual(bytes, try ProvenanceJSON.encoder.encode(envelope))
    }

    /// Row 12, `GenotypeAnnotationStore+PublicationPayload.swift:71`. The record is the sorted JSON object of
    /// `ProvenanceJSON.encoder`'s bytes, which the payload read back as a dictionary and wrote again.
    func testStoreRecordIsTheSortedJSONObjectOfTheProvenanceEncoding() async throws {
        let bundle = try makeBundleURL()
        let store = try GenotypeAnnotationStore(bundleURL: bundle, author: "analyst")
        try await store.setSampleStatus(.reviewed, sample: "Animal-1")
        let bytes = try Data(contentsOf: provenanceURL(bundle))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(bytes)
        XCTAssertTrue(envelope.signatures.isEmpty)
        XCTAssertEqual(envelope.options.explicit["action"], .string("setSampleStatus"))
        let object = try JSONSerialization.jsonObject(with: ProvenanceJSON.encoder.encode(envelope))
        XCTAssertEqual(bytes, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    // MARK: - Helpers

    private func makeBundleURL() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "genotype-provenance-pin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("Fixture.lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return url
    }

    private func provenanceURL(_ bundle: URL) -> URL {
        ProvenanceRecorder.fileSidecarURL(for: bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename))
    }
}
