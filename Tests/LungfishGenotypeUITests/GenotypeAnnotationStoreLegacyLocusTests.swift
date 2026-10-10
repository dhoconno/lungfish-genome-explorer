import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// A review or comment saved at a full-length call's pre-N9 pseudo-locus is
/// reached by an edit at the call's current locus (N9 review finding 2), and
/// the recorded replay payload reproduces the published sidecar exactly. The
/// store shows the built-in smart cohorts from memory beside it, and a replayed
/// edit does not write them.
@MainActor
final class GenotypeAnnotationStoreLegacyLocusTests: XCTestCase {
    private typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    private let legacy = Target.cell(locus: "MHC-NHP01270", genotype: "NHP01270", sample: "CR1178")
    private let current = Target.cell(locus: "MHC-A", genotype: "NHP01270", sample: "CR1178")
    private let unrelated = Target.cell(locus: "MHC-B", genotype: "NHP05007", sample: "CR1178")
    private let alias = GenotypeMatrixTargetLocusAlias(calls: [
        GenotypeTestFixtures.makeCall(sample: "CR1178", genotype: "NHP01270", reads: 674).withSourceLocus("MHC-A"),
    ])

    private func makeStore() throws -> (GenotypeAnnotationStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-09T00:00:00Z")
        sidecar.matrixReviews = [
            .init(target: legacy, disposition: .falsePositive, author: "QA", timestamp: "2026-10-09T00:00:00Z"),
            .init(target: unrelated, disposition: .falsePositive, author: "QA", timestamp: "2026-10-09T00:00:00Z"),
        ]
        sidecar.matrixComments = [
            .init(target: legacy, body: "saved before N9", author: "QA", timestamp: "2026-10-09T00:00:00Z"),
        ]
        let annotationURL = url.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try sidecar.encoded().write(to: annotationURL, options: .atomic)
        return (try GenotypeAnnotationStore(bundleURL: url, author: "editor"), url)
    }

    /// The last recorded replay payload, applied to its recorded prior
    /// sidecar.
    private func replayedSidecar(bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        let prior = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(
            envelope.options.explicit["replayPriorSidecarBase64"]?.stringValue)))
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(
            envelope.options.explicit["replayPayloadBase64"]?.stringValue)))
        return try GenotypeMatrixAnnotationReplayPayload.decode(payload)
            .applying(to: GenotypeAnnotationSidecar.decode(prior))
    }

    /// The sidecar the last edit published, as the bundle's file holds it.
    private func publishedSidecar(bundleURL: URL) throws -> GenotypeAnnotationSidecar {
        try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
    }

    func testTheAliasNamesTheSavedTargetOfACurrentTarget() {
        XCTAssertEqual(alias.savedTargets(for: current), [legacy])
        XCTAssertEqual(alias.savedTargets(for: .row(locus: "MHC-A", genotype: "NHP01270")),
                       [.row(locus: "MHC-NHP01270", genotype: "NHP01270")])
        XCTAssertEqual(alias.savedTargets(for: legacy), [], "a legacy target has no older target")
        XCTAssertEqual(alias.savedTargets(for: unrelated), [])
        XCTAssertEqual(alias.savedTargets(for: .column(sample: "CR1178")), [])
        XCTAssertEqual(GenotypeMatrixTargetLocusAlias.empty.savedTargets(for: current), [])
    }

    func testClearingAtTheCurrentLocusClearsTheLegacyReview() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.clearMatrixReviewSynchronously(targets: [current], author: "editor", locusAlias: alias)

        XCTAssertEqual(store.sidecar.matrixReviews.map(\.target), [unrelated])
        XCTAssertEqual(try replayedSidecar(bundleURL: url), try publishedSidecar(bundleURL: url))
        XCTAssertTrue(try publishedSidecar(bundleURL: url).smartCohorts.isEmpty)
        XCTAssertEqual(store.sidecar.smartCohorts.count, 4)
    }

    func testSettingAtTheCurrentLocusReplacesTheLegacyReview() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.setMatrixReviewSynchronously(
            .falsePositive, targets: [current],
            evidence: GenotypeMatrixEvidenceIndex([current: 674]),
            author: "editor", locusAlias: alias
        )

        XCTAssertEqual(store.sidecar.matrixReviews.map(\.target), [unrelated, current])
        let set = try XCTUnwrap(store.sidecar.auditLog.last)
        XCTAssertEqual(set.action, "setMatrixReview")
        XCTAssertEqual(set.before, "falsePositive", "the matrix showed the legacy review")
        XCTAssertEqual(try replayedSidecar(bundleURL: url), try publishedSidecar(bundleURL: url))
    }

    func testRemovingAtTheCurrentLocusRemovesTheLegacyComment() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.removeMatrixCommentsSynchronously(targets: [current], author: "editor", locusAlias: alias)

        XCTAssertEqual(store.sidecar.matrixComments, [])
        XCTAssertEqual(try replayedSidecar(bundleURL: url), try publishedSidecar(bundleURL: url))
    }

    func testWithoutAnAliasTheLegacyEntriesStay() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.clearMatrixReviewSynchronously(targets: [current], author: "editor")

        XCTAssertEqual(store.sidecar.matrixReviews.map(\.target), [legacy, unrelated])
    }
}
