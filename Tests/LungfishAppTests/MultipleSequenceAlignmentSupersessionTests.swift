import Foundation
import XCTest
@testable import LungfishApp

/// Regression coverage for the stale-display race in the off-main MSA
/// conversion (Batch A, Phase 2). `displayMultipleSequenceAlignmentBundle`
/// reads the primary alignment FASTA off the main actor; that read is a
/// suspension point. If a newer sidebar selection supersedes the request while
/// the read is in flight, the older (stale) task must NOT install its viewport
/// and clobber the newer selection.
///
/// These tests prove the invariant "the generation/`canCommit` guard dominates
/// the viewport install": when `canCommit` reports the request has been
/// superseded, `displayMultipleSequenceAlignmentBundle` installs nothing
/// (`multipleSequenceAlignmentViewController` stays nil).
@MainActor
final class MultipleSequenceAlignmentSupersessionTests: XCTestCase {
    private func msaBundleURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("Tests/Fixtures/alignment")
            .appendingPathComponent("sarscov2-mafft-e2e.lungfish")
            .appendingPathComponent("Multiple Sequence Alignments")
            .appendingPathComponent("sars-cov-2-genomes-mafft.lungfishmsa")
    }

    /// Baseline: a normal (non-raced) selection displays identically to before —
    /// the viewport is installed and the controller is set.
    func testNonRacedSelectionInstallsViewport() async throws {
        let bundleURL = msaBundleURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "MSA fixture missing")

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)

        try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL, canCommit: { true })

        XCTAssertNotNil(vc.multipleSequenceAlignmentViewController)
        XCTAssertEqual(vc.contentMode, .genomics)
    }

    /// Guard-dominates-install: when `canCommit` reports the request has been
    /// superseded (mirrors a newer selection bumping the display generation
    /// while the FASTA read was in flight), NOTHING is installed.
    func testSupersededSelectionInstallsNothing() async throws {
        let bundleURL = msaBundleURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "MSA fixture missing")

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)

        try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL, canCommit: { false })

        XCTAssertNil(
            vc.multipleSequenceAlignmentViewController,
            "A superseded MSA request must not install its viewport"
        )
    }

    /// A superseded completion must not restore the generic genomics stack: by
    /// definition a newer selection owns the viewport by the time the stale read
    /// resolves, so stale cleanup must be limited to its own transient controller.
    func testSupersededSelectionDoesNotRestoreGenomicsStack() async throws {
        let bundleURL = msaBundleURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "MSA fixture missing")

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.enhancedRulerView.isHidden = true
        vc.viewerView.isHidden = true
        vc.headerView.isHidden = true
        vc.statusBar.isHidden = true
        vc.geneTabBarView.isHidden = true

        try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL, canCommit: { false })

        XCTAssertTrue(vc.enhancedRulerView.isHidden)
        XCTAssertTrue(vc.viewerView.isHidden)
        XCTAssertTrue(vc.headerView.isHidden)
        XCTAssertTrue(vc.statusBar.isHidden)
        XCTAssertTrue(vc.geneTabBarView.isHidden)
    }

    /// End-to-end supersession driven through the real display generation gate
    /// (`AsyncRequestGate`), reproducing "selection A, then quickly selection B"
    /// where A's off-main read resolves LAST.
    ///
    /// Selection A begins (token A), then selection B supersedes it before A's
    /// read commits (token B, gate advanced). A's guarded commit — wired to the
    /// real gate exactly as `displayMultipleSequenceAlignmentBundleFromSidebar`
    /// wires it — therefore reports stale, so when A's read resolves it must
    /// commit NOTHING (no controller, no `.genomics` content mode). This proves
    /// the guard dominates the install for a late-resolving stale selection.
    func testLaterResolvingStaleSelectionCommitsNothing() async throws {
        let bundleURL = msaBundleURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "MSA fixture missing")

        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)

        var gate = AsyncRequestGate<String>()
        let tokenA = gate.begin(identity: "bundle-A")
        // Selection B supersedes A before A's read commits.
        _ = gate.begin(identity: "bundle-B")
        let gateSnapshot = gate

        // A's read resolves last; its guard consults the (now-advanced) gate and
        // reports stale, so A must install nothing.
        try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL, canCommit: {
            gateSnapshot.isCurrent(tokenA, expectedIdentity: "bundle-A")
        })

        XCTAssertNil(
            vc.multipleSequenceAlignmentViewController,
            "A late-resolving stale selection must commit no MSA viewport"
        )
    }

    /// Focused invariant on the seam itself: a display commit is rejected once
    /// the gate has advanced past the request's token.
    func testGateRejectsCommitAfterAdvancingPastToken() {
        var gate = AsyncRequestGate<String>()
        let requestA = gate.begin(identity: "bundle-A")
        _ = gate.begin(identity: "bundle-B")

        XCTAssertFalse(
            gate.isCurrent(requestA, expectedIdentity: "bundle-A"),
            "Once the gate advances, the older request's commit must be rejected"
        )
    }

    /// The lower-level controller loader also has a suspension point. Refresh
    /// paths that reuse an existing controller must be able to reject a stale
    /// post-read commit before controller state or selection callbacks change.
    func testControllerDisplayBundleRejectedCommitLeavesStateUnchanged() async throws {
        let bundleURL = msaBundleURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundleURL.path), "MSA fixture missing")

        let controller = MultipleSequenceAlignmentViewController()
        var selectionNotificationCount = 0
        controller.onSelectionStateChanged = { _ in
            selectionNotificationCount += 1
        }

        let didCommit = try await controller.displayBundle(at: bundleURL, canCommit: { false })

        XCTAssertFalse(didCommit)
        XCTAssertNil(controller.bundleURL)
        XCTAssertEqual(selectionNotificationCount, 0)
    }
}
