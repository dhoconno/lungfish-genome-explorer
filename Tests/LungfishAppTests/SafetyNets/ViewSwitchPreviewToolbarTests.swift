// ViewSwitchPreviewToolbarTests.swift - A previewed file shows an Inspector and toolbar that suit a preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Walk 114 row 23 (W6-PREVIEW-KEEPS-RESULT-BLOCK). A file the viewer previews, as a PDF or as text, sets no content
// mode of its own, so the Inspector and the toolbar keep the words and the items of the kind shown before it. The
// view-switch matrix compares a switch with the target kind read alone, and it cannot tell a toolbar that suits a
// preview from one that suits an empty window, because both are read alone in the same mode. So this class reads
// the switches a person meets, a Kraken 2 result and a FASTA document to a PDF and to a text preview, and asks for
// what a preview needs: no Translate button, no Chromosomes button, no drawer button, and an Inspector that lists a
// document tab and a selection tab and draws the document block.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class ViewSwitchPreviewToolbarTests: XCTestCase {
    /// The kinds a person previews a file after, then the preview kind, by their names in ``ViewSwitchKinds``.
    private static let pairs: [(from: String, to: String)] = [
        ("Kraken2", "PDF"),
        ("FASTA document", "PDF"),
        ("Kraken2", "Quick Look"),
        ("FASTA document", "Quick Look"),
    ]

    /// How long one look may take to match. The Kraken 2 viewer opens a SQLite database on the main actor, which a
    /// loaded unit tier stalls (ViewSwitchMatrixTests.settleBudget).
    private static let settleBudget = WaitBudget.lookup

    /// What a look may wait once an earlier look of the same test ran out of time, so a changed toolbar costs one
    /// full budget and not one for each pair.
    private static let settleAfterTimeout = WaitBudget(name: "preview toolbar after a timeout", duration: .seconds(10))

    private static let settlePoll: Duration = .milliseconds(25)

    private struct Fixture {
        let kind: ViewSwitchKind
        let root: URL
        let item: SidebarItem
        let alone: ViewSwitchReading
    }

    func testAPreviewShowsAnInspectorAndToolbarThatSuitAPreview() async throws {
        let root = try TestTempDirectory.make(prefix: "ViewSwitchPreviewToolbar")
        defer { TestTempDirectory.cleanup(root) }
        // The result views save their column layouts to `UserDefaults.standard` under each kind's folder. The restore
        // runs when the test ends, after the windows close and before the folder goes.
        let hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        defer { hostDefaults.restore() }

        var fixtures: [String: Fixture] = [:]
        for name in ["Kraken2", "FASTA document", "PDF", "Quick Look"] {
            fixtures[name] = try await fixture(named: name, in: root)
        }

        var budget = Self.settleBudget
        var differing: [String] = []
        for pair in Self.pairs {
            let source = try XCTUnwrap(fixtures[pair.from])
            let preview = try XCTUnwrap(fixtures[pair.to])
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }

            // The first kind shows as it does alone, so the switch starts from a settled window.
            harness.select(source.item)
            let declared = ViewSwitchDeclaredLeaks.faults(from: DeclaredViewSwitchLeak.freshWindow, to: pair.from)
            let sourceShown = await waitUntil(budget: budget, pollInterval: Self.settlePoll) {
                harness.read(kindRoot: source.root, matrixRoot: root).faults(against: source.alone) == declared
            }
            XCTAssertTrue(sourceShown, "\(pair.from) alone did not settle before the switch to \(pair.to)")

            harness.select(preview.item)
            let previewShown = await waitUntil(budget: budget, pollInterval: Self.settlePoll) {
                harness.read(kindRoot: preview.root, matrixRoot: root).observation.quickLook != nil
            }
            XCTAssertTrue(previewShown, "\(pair.to) did not open after \(pair.from)")

            await waitUntil(budget: budget, pollInterval: Self.settlePoll) {
                Self.faults(of: harness.read(kindRoot: preview.root, matrixRoot: root).observation).isEmpty
            }
            let faults = Self.faults(of: harness.read(kindRoot: preview.root, matrixRoot: root).observation)
            if !faults.isEmpty {
                differing.append("\(pair.from) -> \(pair.to): " + faults.joined(separator: "; "))
                budget = Self.settleAfterTimeout
            }
        }
        XCTAssertTrue(
            differing.isEmpty,
            "A preview after another kind shows an Inspector or a toolbar that does not suit a preview:\n"
                + differing.joined(separator: "\n")
        )
    }

    // MARK: - Support

    /// What a preview's Inspector and toolbar show that a preview has no use for, or lack.
    private static func faults(of observation: RoutingObservation) -> [String] {
        var faults: [String] = []
        let unwanted = [
            (ViewSwitchToolbar.translate, "Translate"),
            (ViewSwitchToolbar.chromosomes, "Chromosomes"),
            (ViewSwitchToolbar.drawer, "the drawer button"),
        ]
        for (item, name) in unwanted where observation.toolbar.contains(item) {
            faults.append("the toolbar shows \(name) (\(item))")
        }
        if !observation.inspectorTab.hasSuffix(" document of [document, selection]") {
            faults.append("the Inspector reads \(observation.inspectorTab)")
        }
        if observation.inspectorBlocks != ["document"] {
            faults.append("the Inspector draws \(observation.inspectorBlocks.joined(separator: ", "))")
        }
        return faults
    }

    /// Builds the representative row of a kind under its own folder, as ViewSwitchMatrixTests does.
    private func fixture(named name: String, in root: URL) async throws -> Fixture {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name }, "no kind named \(name)")
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind), "\(name) names no routing row \(kind.row)")
        let kindRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent(kind.folder, isDirectory: true))
        let built = try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot)))
        return Fixture(kind: kind, root: kindRoot, item: built.item, alone: .alone(built.expected, kind: kind))
    }
}
