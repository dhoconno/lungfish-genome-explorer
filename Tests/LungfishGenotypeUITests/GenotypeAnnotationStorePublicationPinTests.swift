import XCTest
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os
@testable import LungfishGenotypeUI

/// Pins of the annotation pair that the move off the main actor keeps (2.11 S35, R4 and BIO 4).
///
/// Two edits in a row both reach `annotations.json`, each with its record. An edit made from a
/// stale revision is refused before anything is written, the other writer's bytes stay, the store
/// shows the latest file, and the refused edit made again publishes beside the other one, so the
/// refusal drops no edit.
@MainActor
final class GenotypeAnnotationStorePublicationPinTests: XCTestCase {
    private static let staleMessage =
        "The genotype annotations changed in another process. Reload the bundle before saving this edit."

    func testTwoEditsInARowPublishBoth() throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let publications = PublicationCount()
        let store = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "analyst",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: publications.inject
        )

        try store.setSampleStatus(.reviewed, sample: "Animal-1")
        let firstBytes = try Data(contentsOf: annotationURL(bundle))
        try store.addSampleNote(sample: "Animal-2", body: "second edit")

        XCTAssertEqual(publications.count, 2)
        let fileBytes = try Data(contentsOf: annotationURL(bundle))
        XCTAssertNotEqual(fileBytes, firstBytes)
        let file = try GenotypeAnnotationSidecar.decode(fileBytes)
        XCTAssertEqual(file.sampleStatusFlags.map(\.sample), ["Animal-1"])
        XCTAssertEqual(file.sampleStatusFlags.map(\.value), [.reviewed])
        XCTAssertEqual(file.sampleNotes.map(\.body), ["second edit"])
        XCTAssertEqual(
            Array(file.auditLog.map(\.action).suffix(2)),
            ["setSampleStatus", "addSampleNote"]
        )
        XCTAssertEqual(store.sidecar, file)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL(bundle)))
        XCTAssertEqual(record.options.explicit["action"], .string("addSampleNote"))
        XCTAssertEqual(record.outputs.first?.checksumSHA256, sha256Hex(fileBytes))
    }

    func testStaleRevisionRefusesTheEditAndDropsNone() throws {
        let bundle = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try GenotypeAnnotationStore(bundleURL: bundle, author: "seed").publishUnsavedBuiltInSmartCohorts()
        let other = try GenotypeAnnotationStore(bundleURL: bundle, author: "other")
        let publications = PublicationCount()
        let stale = try GenotypeAnnotationStore(
            bundleURL: bundle,
            author: "stale",
            seedBuiltInSmartCohorts: true,
            publicationFaultInjector: publications.inject
        )
        try other.setSampleStatus(.reviewed, sample: "Animal-1")
        let otherAnnotation = try Data(contentsOf: annotationURL(bundle))
        let otherRecord = try Data(contentsOf: provenanceURL(bundle))

        XCTAssertThrowsError(try stale.addSampleNote(sample: "Animal-2", body: "stale edit")) { error in
            XCTAssertEqual(error.localizedDescription, Self.staleMessage)
        }

        XCTAssertEqual(publications.count, 0)
        XCTAssertEqual(try Data(contentsOf: annotationURL(bundle)), otherAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL(bundle)), otherRecord)
        XCTAssertEqual(stale.sidecar, try GenotypeAnnotationSidecar.decode(otherAnnotation))
        XCTAssertEqual(stale.sidecar.sampleStatusFlags.map(\.sample), ["Animal-1"])
        XCTAssertTrue(stale.sidecar.sampleNotes.isEmpty)

        try stale.addSampleNote(sample: "Animal-2", body: "stale edit")

        XCTAssertEqual(publications.count, 1)
        let file = try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL(bundle)))
        XCTAssertEqual(file.sampleStatusFlags.map(\.sample), ["Animal-1"])
        XCTAssertEqual(file.sampleNotes.map(\.body), ["stale edit"])
        XCTAssertEqual(
            Array(file.auditLog.map(\.action).suffix(2)),
            ["setSampleStatus", "addSampleNote"]
        )
        XCTAssertEqual(stale.sidecar, file)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL(bundle)))
        XCTAssertEqual(record.options.explicit["action"], .string("addSampleNote"))
        XCTAssertEqual(record.options.resolvedDefaults["author"], .string("stale"))
    }

    // MARK: - Helpers

    /// Counts the publications that reached the write of `annotations.json`. The coordinator calls
    /// the fault point once per publication, right after that write.
    private final class PublicationCount: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: 0)

        var count: Int { storage.withLock { $0 } }

        func inject(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            if point == .beforeProvenancePublication {
                storage.withLock { $0 += 1 }
            }
            return nil
        }
    }

    private func makeBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        return url
    }

    private func annotationURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename)
    }

    private func provenanceURL(_ bundle: URL) -> URL {
        ProvenanceRecorder.fileSidecarURL(for: annotationURL(bundle))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
