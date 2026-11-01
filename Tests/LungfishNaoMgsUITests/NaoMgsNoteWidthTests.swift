// NaoMgsNoteWidthTests.swift - The long miniBAM note takes the width its column has and wraps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NOTE-WIDTH (walk finding NAO-NOTE-WIDENS-WINDOW). The note under the `miniBAM Panels` header is a
// wrapping label, but its intrinsic width was the whole text on one line. With the long note showing (the strand-fix
// note or the missing-BAM note) the panel asked its column, the split view and the window for the width of that line,
// so selecting a taxon grew the window past the screen. The note must ask for no width, take the width its column has
// and wrap to as many lines as it needs. Both notes reach the label through the checks the viewer runs, so the words
// are the real words, and a change of wording leaves these tests alone.

import AppKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishNaoMgsUI

final class NaoMgsNoteWidthTests: XCTestCase {

    /// The two long notes, each with the way the viewer comes to show it.
    private enum LongNote: CaseIterable {
        case strandFix
        case missingBAM

        @MainActor var words: String {
            switch self {
            case .strandFix:
                NaoMgsResultViewController.miniBAMStrandFixNoteWords
            case .missingBAM:
                NaoMgsResultViewController.miniBAMMissingBAMNoteWords(file: "bams/sample-A.bam")
            }
        }
    }

    /// A check ends within milliseconds, and the wait returns as soon as it has. The budget leaves room for a loaded Mac.
    private static let checkBudget = WaitBudget.standard.raised(to: .seconds(15))

    // MARK: - The note asks for no width

    @MainActor func testStrandFixNoteAsksForNoWidth() throws {
        try assertNoteAsksForNoWidth(.strandFix)
    }

    @MainActor func testMissingBAMNoteAsksForNoWidth() throws {
        try assertNoteAsksForNoWidth(.missingBAM)
    }

    /// With the long note showing, the panel asks for the same width as with no words in the note, the detail pane asks
    /// for the same width, and the window keeps the width it was opened with.
    @MainActor private func assertNoteAsksForNoWidth(
        _ note: LongNote, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try openResult(showing: note)
        defer { closeResult(rig) }
        let label = try XCTUnwrap(rig.controller.miniBAMNoteLabel, file: file, line: line)
        let container = try XCTUnwrap(label.superview, file: file, line: line)
        let detail = rig.controller.testDetailContentView

        XCTAssertEqual(
            rig.window.frame.width, rig.openedWidth, accuracy: 1,
            "the window keeps the width it was opened with while the note shows", file: file, line: line
        )
        container.layoutSubtreeIfNeeded()
        let panelWithNote = container.fittingSize.width
        let detailWithNote = detail.fittingSize.width

        label.stringValue = ""
        container.layoutSubtreeIfNeeded()
        let panelWithoutNote = container.fittingSize.width
        let detailWithoutNote = detail.fittingSize.width

        XCTAssertEqual(
            panelWithNote, panelWithoutNote, accuracy: 1,
            "the panel asks for the same width with the note showing as with no note", file: file, line: line
        )
        XCTAssertEqual(
            detailWithNote, detailWithoutNote, accuracy: 1,
            "the detail pane asks for the same width with the note showing as with no note", file: file, line: line
        )
    }

    // MARK: - The note wraps in a narrow column

    @MainActor func testStrandFixNoteWrapsInANarrowColumn() throws {
        try assertNoteWrapsInANarrowColumn(.strandFix)
    }

    @MainActor func testMissingBAMNoteWrapsInANarrowColumn() throws {
        try assertNoteWrapsInANarrowColumn(.missingBAM)
    }

    /// The panel sits in a column 300 pt wide, with the margins the detail pane gives it. The note stays inside the
    /// column, takes more than one line and is tall enough for every line, so no word is cut.
    @MainActor private func assertNoteWrapsInANarrowColumn(
        _ note: LongNote, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try openResult(showing: note)
        defer { closeResult(rig) }
        let label = try XCTUnwrap(rig.controller.miniBAMNoteLabel, file: file, line: line)
        let container = try XCTUnwrap(label.superview, file: file, line: line)
        let cell = try XCTUnwrap(label.cell, file: file, line: line)

        let column = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        column.translatesAutoresizingMaskIntoConstraints = false
        container.removeFromSuperview()
        container.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(container)
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: 300),
            container.topAnchor.constraint(equalTo: column.topAnchor),
            container.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -8),
        ])
        column.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            container.frame.width, 284, accuracy: 0.5,
            "the panel takes the width its column has", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(label.frame.minX, -0.5, "the note starts inside the panel", file: file, line: line)
        XCTAssertLessThanOrEqual(
            label.frame.maxX, container.bounds.width + 0.5, "the note ends inside the panel", file: file, line: line
        )
        XCTAssertEqual(label.stringValue, note.words, "the note keeps its words in full", file: file, line: line)

        let anyWidth = CGFloat(100_000)
        let oneLine = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: anyWidth, height: .greatestFiniteMagnitude)
        ).height
        let needed = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)
        ).height
        XCTAssertGreaterThan(needed, oneLine * 1.5, "the words need more than one line in this column", file: file, line: line)
        XCTAssertGreaterThan(
            label.frame.height, oneLine * 1.5,
            "the note grows past one line, found \(label.frame.height) pt for a line of \(oneLine) pt", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            label.frame.height, needed - 1,
            "the note is tall enough for every line, found \(label.frame.height) pt for \(needed) pt", file: file, line: line
        )
    }

    // MARK: - Fixture

    private struct Rig {
        let controller: NaoMgsResultViewController
        let folder: URL
        let window: NSWindow
        let openedWidth: CGFloat
    }

    /// Opens a one-sample result with two taxa, selects the first and returns once the note shows `note`'s words,
    /// which the viewer sets after its own check of the sample's BAM. The strand-fix note follows a BAM that the check
    /// finds made before the fix. The missing-BAM note follows a result with no BAM that the fallback cannot make.
    @MainActor private func openResult(showing note: LongNote) throws -> Rig {
        let rig: Rig
        switch note {
        case .strandFix:
            rig = try openResult(withBAM: true) { _ in .beforeStrandFix }
        case .missingBAM:
            rig = try openResult(withBAM: false, hook: nil)
            rig.controller.testMaterializationHook = { _ in }
        }
        let table = rig.controller.testTaxonomyTableView
        let row = try XCTUnwrap((0..<table.numberOfRows).first { rig.controller.testDisplayedTaxonOrder[$0] == "sample-A:111" })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: Self.checkBudget) { rig.controller.miniBAMNoteLabel?.stringValue == note.words },
            "the note shows its words, found: \(rig.controller.miniBAMNoteLabel?.stringValue ?? "no note")"
        )
        return rig
    }

    @MainActor private func openResult(
        withBAM: Bool,
        hook: (@Sendable (Int) async -> NaoMgsBamOrientation?)? = nil
    ) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsNoteWidth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bams"), withIntermediateDirectories: true)
        let hits = [
            NaoMgsResultViewControllerSmokeTests.makeNaoMgsHit(
                sample: "sample-A", seqId: "read-one", taxId: 111, subjectSeqId: "NC_ONE00001.1", subjectTitle: "First virus"
            ),
            NaoMgsResultViewControllerSmokeTests.makeNaoMgsHit(
                sample: "sample-A", seqId: "read-two", taxId: 222, subjectSeqId: "NC_TWO00002.1", subjectTitle: "Second virus"
            ),
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
        return Rig(controller: controller, folder: folder, window: window, openedWidth: window.frame.width)
    }

    @MainActor private func closeResult(_ rig: Rig) {
        rig.window.orderOut(nil)
        rig.window.contentView = nil
        try? FileManager.default.removeItem(at: rig.folder)
    }
}
