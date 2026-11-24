// ReadTimeWriteTests+Alignment.swift - A person's change in the alignment or the tree writes nothing into the project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

extension ReadTimeWriteTests {
    /// With a person's change in the alignment and in the tree, switches between them and the quit's capture and flush,
    /// every file of the project keeps its bytes and its date, every checksum that verified before the view still
    /// verifies, the creation `.viewstate.json` of each bundle among them, and the views sit in the store outside the project
    /// (VS A4, A5, UX 6).
    @MainActor
    func testAnAlignmentAndATreeViewChangeWriteNothingIntoTheProjectAndTheirChecksumsHold() async throws {
        let root = try TestTempDirectory.make(prefix: "ReadTimeWriteAlignment")
        defer { TestTempDirectory.cleanup(root) }
        isolateAlignmentPaneDefaults()
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Views.lungfish", isDirectory: true))
        let alignment = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "MSA"), in: project)
        let tree = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Tree"), in: project)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        // A checksum the built fixture already fails is the fixture's, not the view's (Continuation 1, Finding 4).
        let failingBefore = try [alignment, tree].map { try Self.checksumFailures(inBundle: XCTUnwrap($0.item.url)) }
        // The digest comes before the store reads the project, so a write by that read shows too.
        let before = try ProjectDigest(of: project)
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)

        let alignmentDriver = AlignmentViewStateDriver()
        let treeDriver = TreeViewStateDriver()
        let harness = try ViewSwitchWindowHarness()
        harness.keepViews(in: store)
        harness.select(alignment.item)
        var shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { alignmentDriver.isShown(in: harness) }
        XCTAssertTrue(shown, "the alignment did not show")
        try alignmentDriver.change(in: harness)
        harness.select(tree.item)
        shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { treeDriver.isShown(in: harness) }
        XCTAssertTrue(shown, "the tree did not show")
        try treeDriver.change(in: harness)
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !treeDriver.isShown(in: harness) }
        XCTAssertTrue(left, "the tree stayed after the switch")
        harness.select(alignment.item)
        shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { alignmentDriver.isShown(in: harness) }
        XCTAssertTrue(shown, "the alignment did not show again")
        harness.split.viewerController.surfaceHost.captureActive()
        store.flushSynchronously()
        harness.close()

        let after = try ProjectDigest(of: project)
        XCTAssertEqual(after.entries, before.entries, "viewing and switching write nothing into the project (UX 6)")
        for (bundle, failedBefore) in zip([alignment, tree], failingBefore) {
            let url = try XCTUnwrap(bundle.item.url)
            let failures = try Self.checksumFailures(inBundle: url)
            XCTAssertEqual(failures, failedBefore, "\(url.lastPathComponent): every checksum that verified still verifies")
            XCTAssertFalse(failures.contains(".viewstate.json"), "\(url.lastPathComponent): its creation view state verifies")
        }
        let kept = try FileManager.default.subpathsOfDirectory(atPath: storeRoot.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(kept.count, 2, "both views sit in the store: \(kept)")
    }

    /// The paths whose SHA-256 differs from the one the bundle's manifest records, `.viewstate.json` among them.
    private static func checksumFailures(inBundle bundle: URL) throws -> [String] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let checksums = try XCTUnwrap(manifest["checksums"] as? [String: String])
        XCTAssertNotNil(checksums[".viewstate.json"], "\(bundle.lastPathComponent) records its creation view state")
        return try checksums.keys.sorted().filter { path in
            let file = try Data(contentsOf: bundle.appendingPathComponent(path))
            let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            return digest != checksums[path]
        }
    }
}
