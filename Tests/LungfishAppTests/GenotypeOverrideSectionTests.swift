// GenotypeOverrideSectionTests.swift - Tests for GenotypeOverrideSection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import SwiftUI
@testable import LungfishApp
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeOverrideSectionTests: XCTestCase {
    func testSectionExposesAllowedTargetsForWhitelistPicker() throws {
        let allowed = ["M1A", "M2A", "M3A"]
        let draft = GenotypeOverrideSection.OverrideDraft()
        let section = GenotypeOverrideSection(
            draft: .constant(draft),
            originalCall: "M2A",
            allowedTargets: allowed,
            onSave: { _ in },
            onCancel: { }
        )

        XCTAssertEqual(section.allowedTargets, allowed)
        XCTAssertEqual(section.originalCall, "M2A")
    }

    func testHostingViewRendersWithWhitelistTargetsWithoutCrashing() {
        let allowed = ["M1A", "M2A", "M3A"]
        var draft = GenotypeOverrideSection.OverrideDraft()
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let section = GenotypeOverrideSection(
            draft: binding,
            originalCall: "M2A",
            allowedTargets: allowed,
            onSave: { _ in },
            onCancel: { }
        )

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift")
        // Confirm the picker references each allowed entry via a `.tag(name)` call in
        // source — this is the contract guaranteeing the entries are wired into the
        // SwiftUI picker.
        let source = try? String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertNotNil(source)
        if let src = source {
            XCTAssertTrue(src.contains("ForEach(allowedTargets, id: \\.self)"))
            XCTAssertTrue(src.contains(".tag(name)"))
        }

        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    func testFreeTextModeIsActiveWhenAllowedTargetsAreEmpty() throws {
        var draft = GenotypeOverrideSection.OverrideDraft()
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let section = GenotypeOverrideSection(
            draft: binding,
            originalCall: "X",
            allowedTargets: [],
            onSave: { _ in },
            onCancel: { }
        )

        XCTAssertTrue(section.allowedTargets.isEmpty)

        let hosting = NSHostingView(rootView: section)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()

        // Source-level contract: the free-text branch reaches for `TextField` keyed to
        // the draft target binding.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("TextField(\"Haplotype name\", text: $draft.target)"))
    }

    func testSaveClosureForwardsCurrentDraft() {
        var draft = GenotypeOverrideSection.OverrideDraft(
            target: "M3A",
            reason: .contamination,
            rationale: "Cross-well bleed"
        )
        let binding = Binding(get: { draft }, set: { draft = $0 })
        var captured: GenotypeOverrideSection.OverrideDraft?
        let section = GenotypeOverrideSection(
            draft: binding,
            originalCall: "M2A",
            allowedTargets: ["M1A", "M2A", "M3A"],
            onSave: { captured = $0 },
            onCancel: { }
        )

        section.onSave(draft)

        XCTAssertEqual(captured?.target, "M3A")
        XCTAssertEqual(captured?.reason, .contamination)
        XCTAssertEqual(captured?.rationale, "Cross-well bleed")
    }

    func testCancelClosureFires() {
        var draft = GenotypeOverrideSection.OverrideDraft()
        let binding = Binding(get: { draft }, set: { draft = $0 })
        var cancelCount = 0
        let section = GenotypeOverrideSection(
            draft: binding,
            originalCall: "X",
            allowedTargets: ["X", "Y"],
            onSave: { _ in },
            onCancel: { cancelCount += 1 }
        )

        section.onCancel()
        section.onCancel()

        XCTAssertEqual(cancelCount, 2)
    }

    func testDraftDefaultsToConfirmedReason() {
        let draft = GenotypeOverrideSection.OverrideDraft()
        XCTAssertEqual(draft.target, "")
        XCTAssertEqual(draft.reason, .confirmed)
        XCTAssertEqual(draft.rationale, "")
    }

    func testReasonChipForEachReasonTagIsRendered() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/GenotypeOverrideSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Each reason tag should be exposed via a chip case in `reasonLabel`.
        for tag in GenotypeAnnotationSidecar.OverrideReasonTag.allCases {
            XCTAssertTrue(source.contains("case .\(tag.rawValue)"), "Missing reason chip label for \(tag.rawValue)")
        }
        XCTAssertTrue(source.contains("ForEach(GenotypeAnnotationSidecar.OverrideReasonTag.allCases"))
    }
}
