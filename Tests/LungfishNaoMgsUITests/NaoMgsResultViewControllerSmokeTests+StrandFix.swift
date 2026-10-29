// NaoMgsResultViewControllerSmokeTests+StrandFix.swift - The miniBAM note of a result made before the strand fix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE, section 4b, test T8). The viewer reads the header of the
// displayed sample's BAM once for each load of the read panels, off the main actor. When the BAM was made before the
// strand fix, the note under the miniBAM header says so and says what to do. For a fixed BAM, an unreadable header and
// a check of a superseded selection, the note keeps its words. The check only reads, so no file of the result changes.
// A DEBUG seam stands in for samtools, as `testMaterializationHook` does for the fallback.

import AppKit
import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishNaoMgsUI

/// Holds a hook until the test lets it go, so a superseded check ends after the newer one without a sleep.
private actor StrandFixGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

extension NaoMgsResultViewControllerSmokeTests {

    /// Today's note, which the viewer keeps for a fixed BAM and while the check runs.
    private static let referenceNote =
        "Top references by unique read count. Drag a panel handle downward to make it taller."

    /// The note for a BAM made before the strand fix (ruling 4b), spelled out so a change of wording fails.
    private static let staleNote =
        "These read panels come from an earlier NAO-MGS import, which stored reads that map to the reverse strand the "
        + "wrong way round, so many reads show false mismatches. To see them correctly, import the same NAO-MGS "
        + "results file again in the Import Center (NAO-MGS Results). The counts and read IDs are right."

    /// The note for a BAM that is missing and that the fallback could not rebuild (lane NAO-BAM-MISSING, ruling
    /// UX-NAO-BAM-STALE R4). It names the file, says what follows for the panels and says what to try, and it is spelled
    /// out so a change of wording fails.
    private static let missingNote =
        "The alignment file bams/sample-A.bam is missing from this result, so the read panels are empty. "
        + "Lungfish could not rebuild it. To see the reads, import the same NAO-MGS results file again in the "
        + "Import Center (NAO-MGS Results)."

    /// A check ends within milliseconds, and the wait returns as soon as it has. The budget leaves room for a loaded Mac.
    private static let checkBudget = WaitBudget.standard.raised(to: .seconds(15))

    @MainActor func testStaleBAMShowsTheReimportNote() throws {
        let rig = try openStrandFixResult { _ in .beforeStrandFix }
        defer { closeStrandFixResult(rig) }
        let before = try strandFixDigests(rig.folder)

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)

        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { Self.miniBAMNote(in: rig.controller.view)?.stringValue == Self.staleNote },
            "the note names the earlier import and the next step, found: \(Self.miniBAMNote(in: rig.controller.view)?.stringValue ?? "no note")"
        )
        XCTAssertEqual(Self.miniBAMNote(in: rig.controller.view)?.textColor, .labelColor, "the note is drawn to be seen")
        XCTAssertEqual(try strandFixDigests(rig.folder), before, "the check rewrites no file of the result")
    }

    @MainActor func testFixedBAMKeepsTheReferenceNote() throws {
        let rig = try openStrandFixResult { _ in .referenceStrand }
        defer { closeStrandFixResult(rig) }
        let before = try strandFixDigests(rig.folder)

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)

        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { rig.controller.testStrandFixOutcomes.contains { $0.generation == 1 } },
            "the check of a fixed BAM ended"
        )
        XCTAssertEqual(Self.miniBAMNote(in: rig.controller.view)?.stringValue, Self.referenceNote)
        XCTAssertEqual(rig.controller.testStrandFixOutcomes.map(\.applied), [false], "a fixed BAM changes no note")
        XCTAssertEqual(try strandFixDigests(rig.folder), before)
    }

    /// A header the check cannot read says nothing, since the note makes no claim the check did not make.
    @MainActor func testUnreadableHeaderKeepsTheReferenceNote() throws {
        let rig = try openStrandFixResult { _ in nil }
        defer { closeStrandFixResult(rig) }

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)

        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { rig.controller.testStrandFixOutcomes.contains { $0.generation == 1 } },
            "the check ended"
        )
        XCTAssertEqual(Self.miniBAMNote(in: rig.controller.view)?.stringValue, Self.referenceNote)
        XCTAssertEqual(rig.controller.testStrandFixOutcomes.map(\.applied), [false])
    }

    /// Taxon A's check is held until taxon B's check has ended. A's late answer then names the older selection's
    /// generation, so it must leave the note of the newer selection alone.
    @MainActor func testSupersededStrandFixCheckLeavesTheNoteAlone() throws {
        let gate = StrandFixGate()
        let rig = try openStrandFixResult { generation in
            if generation == 1 {
                await gate.wait()
                return .beforeStrandFix
            }
            return .referenceStrand
        }
        defer { closeStrandFixResult(rig) }

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)
        XCTAssertEqual(rig.controller.testMiniBAMLoadGeneration, 1)
        try selectStrandFixTaxon("sample-A:222", in: rig.controller)
        XCTAssertEqual(rig.controller.testMiniBAMLoadGeneration, 2)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { rig.controller.testStrandFixOutcomes.contains { $0.generation == 2 } },
            "the check of the newer selection ended"
        )

        Task { await gate.open() }
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { rig.controller.testStrandFixOutcomes.contains { $0.generation == 1 } },
            "the check of the older selection ended after the newer one"
        )
        XCTAssertEqual(rig.controller.testStrandFixOutcomes.first { $0.generation == 1 }?.applied, false)
        XCTAssertEqual(
            Self.miniBAMNote(in: rig.controller.view)?.stringValue, Self.referenceNote,
            "a superseded check leaves the newer selection's note alone"
        )
    }

    /// The sample's BAM is gone (removed by hand, or never written) and the fallback cannot make it again, so the card is
    /// blank. The note then says which file is missing and what to try, and the words write nothing into the result, a
    /// header-only BAM included. The fallback is a seam that makes no file, like a database that holds no reads.
    @MainActor func testMissingBAMShowsItsWordsAndWritesNothing() throws {
        let rig = try openStrandFixResult(withBAM: false)
        defer { closeStrandFixResult(rig) }
        rig.controller.testMaterializationHook = { _ in }
        let before = try resultFileDigests(rig.folder)
        XCTAssertNil(before["bams/sample-A.bam"], "the fixture has no BAM for the sample")

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)

        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { Self.miniBAMNote(in: rig.controller.view)?.stringValue == Self.missingNote },
            "the note names the missing file and the next step, found: \(Self.miniBAMNote(in: rig.controller.view)?.stringValue ?? "no note")"
        )
        XCTAssertEqual(Self.miniBAMNote(in: rig.controller.view)?.textColor, .labelColor, "the note is drawn to be seen")
        XCTAssertEqual(try resultFileDigests(rig.folder), before, "the words write no file into the result")
        XCTAssertTrue(rig.controller.testAppliedFallbackWrites.isEmpty, "no card was drawn from a written file")
    }

    /// The BAM is missing at load, which the check reports at once, but the fallback then makes it and the card draws.
    /// Words that say the panels are empty must not show while they fill, so the note keeps today's words, and no check
    /// of the load changes it. The real file check runs here, with no strand hook, so the load-time answer is `.missing`.
    @MainActor func testBAMTheFallbackMakesKeepsTheReferenceNote() throws {
        let rig = try openStrandFixResult(withBAM: false)
        defer { closeStrandFixResult(rig) }
        let bamURL = rig.folder.appendingPathComponent("bams/sample-A.bam")
        rig.controller.testMaterializationHook = { _ in _ = FileManager.default.createFile(atPath: bamURL.path, contents: Data()) }

        try selectStrandFixTaxon("sample-A:111", in: rig.controller)

        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) {
                rig.controller.testAppliedFallbackWrites.contains { $0.generation == 1 }
                    && rig.controller.testStrandFixOutcomes.contains { $0.generation == 1 }
            },
            "the fallback made the file, the card was drawn from it and the load-time check ended"
        )
        XCTAssertEqual(Self.miniBAMNote(in: rig.controller.view)?.stringValue, Self.referenceNote)
        XCTAssertFalse(rig.controller.testStrandFixOutcomes.contains { $0.applied }, "no check changed the note")
    }

    // MARK: - Fixture

    private struct StrandFixRig {
        let controller: NaoMgsResultViewController
        let folder: URL
        let window: NSWindow
    }

    /// A one-sample result with two taxa, whose sample BAM exists (so the fallback never materializes) and holds no
    /// bytes, since `hook` answers in place of samtools. With `withBAM` false the `bams` folder is empty, as after a
    /// removal by hand, and with no `hook` the check reads the real file system. The result is open in a window.
    @MainActor private func openStrandFixResult(
        withBAM: Bool = true,
        hook: (@Sendable (Int) async -> NaoMgsBamOrientation?)? = nil
    ) throws -> StrandFixRig {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsStrandFix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bams"), withIntermediateDirectories: true)
        let hits = [
            Self.makeNaoMgsHit(sample: "sample-A", seqId: "read-one", taxId: 111, subjectSeqId: "NC_ONE00001.1", subjectTitle: "First virus"),
            Self.makeNaoMgsHit(sample: "sample-A", seqId: "read-two", taxId: 222, subjectSeqId: "NC_TWO00002.1", subjectTitle: "Second virus"),
        ]
        let database = try NaoMgsDatabase.create(at: folder.appendingPathComponent("hits.sqlite"), hits: hits)
        if withBAM {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("bams/sample-A.bam").path, contents: Data())
        }
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 2, taxonCount: 2,
            topTaxon: "First virus", topTaxonId: 111
        )

        let controller = NaoMgsResultViewController()
        isolateLayouts(controller)
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.testStrandFixOrientationHook = hook
        controller.configure(database: database, manifest: manifest, bundleURL: folder)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { controller.testTaxonomyTableView.numberOfRows >= 2 },
            "the taxonomy table lists the two taxa"
        )
        return StrandFixRig(controller: controller, folder: folder, window: window)
    }

    @MainActor private func closeStrandFixResult(_ rig: StrandFixRig) {
        rig.window.orderOut(nil)
        rig.window.contentView = nil
        try? FileManager.default.removeItem(at: rig.folder)
    }

    @MainActor private func selectStrandFixTaxon(_ key: String, in controller: NaoMgsResultViewController) throws {
        let table = controller.testTaxonomyTableView
        let row = try XCTUnwrap((0..<table.numberOfRows).first { controller.testDisplayedTaxonOrder[$0] == key })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The label under the miniBAM header, found by any of its three sentences.
    @MainActor private static func miniBAMNote(in root: NSView) -> NSTextField? {
        var found: NSTextField?
        let sentences = [referenceNote, staleNote, missingNote]
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, sentences.contains(field.stringValue) {
                found = field
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// The SHA-256 of the database and of the sample's BAM.
    private func strandFixDigests(_ folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in ["hits.sqlite", "bams/sample-A.bam"] {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            digests[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }

    /// The SHA-256 of every file in the result, keyed by its path inside the result, so a new file is a new key.
    private func resultFileDigests(_ folder: URL) throws -> [String: String] {
        let root = folder.resolvingSymlinksInPath()
        var digests: [String: String] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(root.pathComponents.count)
            digests[relative.joined(separator: "/")] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }
}
