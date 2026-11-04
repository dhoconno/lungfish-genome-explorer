// BeepKeeperCountTests.swift - The beeps that may stay in LungfishApp, counted so that the number only falls (Phase 3.2, BEEPS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The owner works by VNC and hears no audio, so a beep that answers a refused command is no answer at all (O116). Phase
/// 3.2 lane BEEPS gave words to the refusals that had a person to talk to and left the beeps below. This test counts
/// `NSSound.beep()` under `Sources/LungfishApp` and fails on any file that gains one and on any file that loses one
/// without lowering its number here, so the total can only fall.
final class BeepKeeperCountTests: XCTestCase {
    /// The path below `Sources/LungfishApp`, the number of beeps kept there, and why each stays.
    static let keepers: [String: Int] = [
        // Add and Edit Annotation: the drawer has no window. The menu belongs to the drawer's own window.
        "Views/Viewer/AnnotationTableDrawerView.swift": 2,
        // Query Builder on a very large variant database. The button is already disabled then, with a tooltip.
        "Views/Viewer/AnnotationTableDrawerView+Filtering.swift": 1,
        // Remove partial output and the operation log: the panel has no window.
        "Views/Operations/OperationsPanelViewController.swift": 2,
        // UX-3E-LABELS R17: AppKit allows one sheet a window and the open sheet is in view.
        "Views/Metagenomics/TaxonomyReadExtractionAction.swift": 1,
        // Removing a derived alignment with no window and no key window.
        "Views/Inspector/InspectorViewController+MetadataImport.swift": 1,
        // Build Tree with no alignment: the menu item is disabled then, with a tooltip.
        "App/AppDelegate+TreeInference.swift": 1,
        // Copy Selection as FASTA and Extract Selection: both menu items are disabled with no sequence viewer.
        "App/AppDelegate+SequenceMenu.swift": 2,
    ]

    func testOnlyTheNamedKeepersStillBeep() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: appRoot.path).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(paths.count, 400, "the scan found the App sources")
        var found: [String: Int] = [:]
        for path in paths {
            let text = try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
            let count = text.components(separatedBy: "NSSound.beep()").count + text.components(separatedBy: "NSBeep()").count - 2
            if count > 0 { found[path] = count }
        }
        var problems: [String] = []
        for path in Set(found.keys).union(Self.keepers.keys).sorted() {
            let now = found[path] ?? 0
            let allowed = Self.keepers[path] ?? 0
            if now > allowed {
                problems.append("\(path) has \(now) NSSound.beep() and may keep \(allowed). A refused command must show words (a FailureReport through ViewerRefusalSeam, or the label of its own sheet), because the owner hears no audio (O116).")
            } else if now < allowed {
                problems.append("\(path) has \(now) NSSound.beep() and this table keeps \(allowed). Lower its number in BeepKeeperCountTests.keepers, or delete its entry.")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func testTheKeeperTableCountsTen() {
        XCTAssertEqual(Self.keepers.values.reduce(0, +), 10, "34 beeps stood at the base of lane BEEPS and 10 are kept")
    }
}
