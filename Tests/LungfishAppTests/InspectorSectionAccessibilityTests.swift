// InspectorSectionAccessibilityTests.swift - Inspector rows publish their commands through the AX bridge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp

/// Hosts the real Inspector sections in a window and reads what an AX client
/// reads. A `.contextActions` command must arrive as a custom action on a
/// reachable element, not just exist as a SwiftUI modifier; the lazy
/// containers that used to hide rows behind an opaque provider are gone;
/// the variant selection list is capped; the MSA Pairwise Distance section
/// reads its focused pair; and a Run Inputs path reads project-relative with the recorded path
/// as its value.
@MainActor
final class InspectorSectionAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectorSectionAccessibilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func host<Content: View>(_ content: Content) -> NSWindow {
        let window = AccessibilityTreeProbe.host(content)
        windows.append(window)
        return window
    }

    private func assertNoOpaqueProviderGroup(in root: NSObject, file: StaticString = #filePath, line: UInt = #line) {
        let opaque = AccessibilityTreeProbe.all(in: root).filter {
            (AccessibilityTreeProbe.role($0) ?? "").contains("OpaqueProvider")
                || (AccessibilityTreeProbe.subrole($0) ?? "").contains("OpaqueProvider")
        }
        XCTAssertTrue(
            opaque.isEmpty,
            "a lazy container hides rows behind an opaque provider; tree:\n" + AccessibilityTreeProbe.dump(root),
            file: file, line: line
        )
    }

    // MARK: - Attachments

    func testAttachmentRowOffersItsContextCommandsAsCustomActions() throws {
        let bundleURL = tempRoot.appendingPathComponent("Ref.lungfishref", isDirectory: true)
        let attachmentsURL = bundleURL.appendingPathComponent(BundleAttachmentStore.attachmentsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        let notesURL = attachmentsURL.appendingPathComponent("notes.txt")
        try "hello".write(to: notesURL, atomically: true, encoding: .utf8)
        try "{}".write(
            to: BundleAttachmentFilenamePolicy.provenanceSidecarURL(forAttachmentURL: notesURL),
            atomically: true, encoding: .utf8
        )
        let store = BundleAttachmentStore(bundleURL: bundleURL)
        store.reload()
        XCTAssertEqual(store.attachments.map(\.filename), ["notes.txt"])

        let window = host(AttachmentsSection(store: store))
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, offering: "Remove Attachment") != nil }
        let row = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, offering: "Remove Attachment"),
            "no element offers the attachment commands; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        // VoiceOver's Actions menu lists the actions as the bridge serves
        // them, so the order must equal the context menu's.
        XCTAssertEqual(
            AccessibilityTreeProbe.customActionNames(row),
            ["Reveal in Finder", "Quick Look", "Remove Attachment"],
            "the Actions menu must list the commands in context-menu order, each once"
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(row), "notes.txt")
        assertNoOpaqueProviderGroup(in: window)

        // Performing through the bridge runs the same handler the menu item
        // runs. Trashing from a test process depends on the volume, so the
        // outcome is checked only when the Trash accepted the file.
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Remove Attachment", on: row))
        if store.attachments.isEmpty {
            XCTAssertFalse(FileManager.default.fileExists(atPath: notesURL.path))
        }
    }

    // MARK: - Document section

    func testDerivedAlignmentRemoveIsOneVisibleButtonAndNotRepeatedAsAnAction() throws {
        let viewModel = DocumentSectionViewModel()
        viewModel.alignmentTrackRows = [
            AlignmentTrackInventoryRow(id: "raw", name: "reads.bam", summary: "all reads", isDerived: false),
            AlignmentTrackInventoryRow(id: "filtered", name: "reads.q30.bam", summary: "MAPQ 30", isDerived: true, isRemovable: true),
        ]
        var removed: [String] = []
        viewModel.removeDerivedAlignmentTrack = { removed.append($0) }

        let window = host(ScrollView {
            AlignmentTrackInventorySection(viewModel: viewModel, isExpanded: .constant(true))
        })
        let title = "Remove Derived Alignment\u{2026}"
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, offering: title) != nil }
        // The command is reachable exactly once, through the visible Remove
        // button, and is not spread onto the row's other children.
        let buttons = AccessibilityTreeProbe.all(in: window).filter {
            AccessibilityTreeProbe.label($0) == title || AccessibilityTreeProbe.label($0) == "Remove Derived Alignment\u{2026}"
        }
        XCTAssertEqual(buttons.count, 1, "one visible Remove button; tree:\n" + AccessibilityTreeProbe.dump(window))
        let offering = AccessibilityTreeProbe.all(in: window).filter { AccessibilityTreeProbe.customActionNames($0).contains(title) }
        XCTAssertTrue(offering.isEmpty, "no element repeats the command as a custom action; tree:\n" + AccessibilityTreeProbe.dump(window))
        let button = try XCTUnwrap(buttons.first)
        XCTAssertTrue(AccessibilityTreeProbe.press(button))
        XCTAssertEqual(removed, ["filtered"])
        assertNoOpaqueProviderGroup(in: window)
    }

    // MARK: - Analyses

    func testAnalysisRowCarriesTheAbsoluteTimestampAsItsValue() throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = AnalysisManifestEntry(
            tool: "kraken2", timestamp: timestamp, analysisDirectoryName: "k2", displayName: "Kraken run", summary: "12 taxa"
        )
        let window = host(AnalysesSection(analyses: [entry]))
        let identifier = "analysis-entry-\(entry.id.uuidString)"
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        let row = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: identifier), AccessibilityTreeProbe.dump(window))
        XCTAssertEqual(AccessibilityTreeProbe.label(row), "Kraken run")
        XCTAssertEqual(AccessibilityTreeProbe.value(row), AnalysesSection.absoluteTimestamp(timestamp))
        XCTAssertFalse(AnalysesSection.absoluteTimestamp(timestamp).isEmpty)
    }

    // MARK: - Variant selection

    func testVariantSelectionListsAtMostOneHundredEntriesEagerly() throws {
        let viewModel = VariantSectionViewModel()
        let entries = (1...150).map { index in
            VariantSelectionEntry(
                result: AnnotationSearchIndex.SearchResult(
                    name: "variant-\(index)", chromosome: "chr1", start: index * 10, end: index * 10 + 1,
                    trackId: "t", type: "SNV", ref: "A", alt: "G", variantRowId: Int64(index)
                ),
                fields: [VariantInspectorField(key: "qual", label: "Quality", value: "50")]
            )
        }
        viewModel.select(entries: entries)
        XCTAssertEqual(viewModel.selectionEntries.count, 150)

        let window = host(ScrollView { VariantSection(viewModel: viewModel) })
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: "variant-selection-cap") != nil }
        let cap = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "variant-selection-cap"),
            "tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertTrue(
            (AccessibilityTreeProbe.label(cap) ?? AccessibilityTreeProbe.value(cap) ?? "").contains("Showing 100 of 150 selected variants"),
            "label: \(AccessibilityTreeProbe.label(cap) ?? "nil") value: \(AccessibilityTreeProbe.value(cap) ?? "nil")"
        )

        // Every listed entry is in the tree at once (no lazy container), and
        // the 101st is not.
        let listed = AccessibilityTreeProbe.all(in: window).filter {
            (AccessibilityTreeProbe.label($0) ?? "").hasPrefix("variant-")
                || (AccessibilityTreeProbe.value($0) ?? "").hasPrefix("variant-")
        }
        let names = Set(listed.compactMap { element -> String? in
            let text = AccessibilityTreeProbe.label(element) ?? AccessibilityTreeProbe.value(element) ?? ""
            return text.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
        XCTAssertTrue(names.contains("variant-1"), "names: \(names.sorted().prefix(5))")
        XCTAssertTrue(names.contains("variant-100"), "names: \(names.sorted().suffix(5))")
        XCTAssertFalse(names.contains("variant-101"))
        XCTAssertFalse(names.contains("variant-150"))
        assertNoOpaqueProviderGroup(in: window)
    }

    // MARK: - MSA pairwise distance

    func testPairwiseDistanceSectionExposesShowButtonAndFocusedPairBreakdown() throws {
        let model = MSAPairwiseDistanceInspectorModel(bundleURL: tempRoot.appendingPathComponent("panel.lungfishmsa"))
        model.isExpanded = true
        var showCount = 0
        model.onShowDistanceMatrix = { showCount += 1 }
        model.focusedPair = MSAFocusedDistancePair(
            rowName: "seq1",
            columnName: "seq2",
            model: .k2p,
            detail: MSAPairDetail(
                value: 0.105361, comparableSites: 29_734, differences: 44, identicalSites: 29_690,
                transitions: 30, transversions: 14, gapSkipped: 12, ambiguitySkipped: 3
            )
        )
        let window = host(MSAPairwiseDistanceSection(model: model))
        func texts() -> [String] {
            AccessibilityTreeProbe.all(in: window).compactMap {
                AccessibilityTreeProbe.label($0) ?? AccessibilityTreeProbe.value($0)
            }
        }
        AccessibilityTreeProbe.waitUntil { texts().contains { $0.contains("Transversions") } }
        let all = texts().joined(separator: " | ")
        for expected in ["seq1 vs seq2", "0.105361", "29,734", "Gap-skipped", "Ambiguity-skipped", "Transitions", "Transversions"] {
            XCTAssertTrue(all.contains(expected), "missing \(expected) in AX text: \(all)")
        }
        let button = try XCTUnwrap(
            AccessibilityTreeProbe.all(in: window).first {
                AccessibilityTreeProbe.role($0) == "AXButton" && AccessibilityTreeProbe.label($0) == "Show Distance Matrix"
            },
            "no Show Distance Matrix button; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        button.accessibilityPerformAction(.press)
        AccessibilityTreeProbe.waitUntil { showCount == 1 }
        XCTAssertEqual(showCount, 1)
    }

    func testPairwiseDistanceValueTextSpellsOutUndefinedAndSaturated() {
        func detail(_ value: Double) -> MSAPairDetail {
            MSAPairDetail(value: value, comparableSites: 0, differences: 0, identicalSites: 0,
                          transitions: 0, transversions: 0, gapSkipped: 0, ambiguitySkipped: 0)
        }
        XCTAssertTrue(MSAPairwiseDistanceInspectorModel.valueText(detail: detail(.nan), model: .jc69).contains("no comparable sites"))
        XCTAssertTrue(MSAPairwiseDistanceInspectorModel.valueText(detail: detail(.infinity), model: .jc69).hasPrefix("Saturated."))
        XCTAssertEqual(MSAPairwiseDistanceInspectorModel.valueText(detail: detail(0.5), model: .identity), "0.500000")
    }

    // MARK: - Filter chips and the option picker

    func testAnnotationFilterChipsExposeShownAndHiddenAsStateNotJustColour() throws {
        let viewModel = AnnotationSectionViewModel()
        viewModel.visibleTypes = [.gene]
        viewModel.availableVariantTypes = ["SNV", "DEL"]
        viewModel.visibleVariantTypes = ["SNV"]
        let window = host(ScrollView { AnnotationSection(viewModel: viewModel) })
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.label($0)?.hasPrefix("Type Visibility") == true }
        }
        let disclosure = try XCTUnwrap(
            AccessibilityTreeProbe.all(in: window).first { AccessibilityTreeProbe.label($0)?.hasPrefix("Type Visibility") == true },
            AccessibilityTreeProbe.dump(window)
        )
        XCTAssertTrue(AccessibilityTreeProbe.press(disclosure))
        AccessibilityTreeProbe.waitUntil {
            !AccessibilityTreeProbe.elements(in: window, labelled: "Gene").isEmpty
                && !AccessibilityTreeProbe.elements(in: window, labelled: "SNV").isEmpty
        }
        func chip(_ name: String) throws -> NSObject {
            try XCTUnwrap(
                AccessibilityTreeProbe.elements(in: window, labelled: name)
                    .first { AccessibilityTreeProbe.value($0) == "Shown" || AccessibilityTreeProbe.value($0) == "Hidden" },
                "no chip named \(name); tree:\n" + AccessibilityTreeProbe.dump(window)
            )
        }
        for (name, shown) in [("Gene", true), ("Exon", false), ("SNV", true), ("DEL", false)] {
            let element = try chip(name)
            XCTAssertEqual(AccessibilityTreeProbe.value(element), shown ? "Shown" : "Hidden", name)
            XCTAssertEqual(AccessibilityTreeProbe.isSelected(element), shown, "\(name) selected state")
        }
        // Pressing through the bridge toggles it and the state follows.
        XCTAssertTrue(AccessibilityTreeProbe.press(try chip("Exon")))
        AccessibilityTreeProbe.waitUntil { viewModel.visibleTypes.contains(.exon) }
        XCTAssertTrue(viewModel.visibleTypes.contains(.exon))
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.value((try? chip("Exon")) ?? window) == "Shown" }
        XCTAssertEqual(AccessibilityTreeProbe.value(try chip("Exon")), "Shown")
    }

    func testOptionPickerKeepsEachOptionsOwnNameAndExposesSelection() throws {
        let window = host(OptionPickerHarness())
        AccessibilityTreeProbe.waitUntil { !AccessibilityTreeProbe.elements(in: window, labelled: "Beta").isEmpty }
        for name in ["Alpha", "Beta", "Gamma"] {
            let matches = AccessibilityTreeProbe.elements(in: window, labelled: name)
            XCTAssertEqual(matches.count, 1, "option \(name) keeps its own name; tree:\n" + AccessibilityTreeProbe.dump(window))
        }
        let beta = try XCTUnwrap(AccessibilityTreeProbe.elements(in: window, labelled: "Beta").first)
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(beta))
        let alpha = try XCTUnwrap(AccessibilityTreeProbe.elements(in: window, labelled: "Alpha").first)
        XCTAssertFalse(AccessibilityTreeProbe.isSelected(alpha))
        XCTAssertTrue(
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.label($0) == "Mode" },
            "the group carries the picker label; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertFalse(
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.label($0) == "Mode, Alpha" },
            "the picker label must not be prepended to an option"
        )
    }

    private struct OptionPickerHarness: View {
        @State private var selection = "Beta"
        var body: some View {
            LungfishInspectorSegmentedButtonGrid(
                options: ["Alpha", "Beta", "Gamma"],
                selection: $selection,
                accessibilityLabel: "Mode",
                label: { $0 }
            )
        }
    }

    // MARK: - Run Inputs

    func testRunInputsShowProjectRelativePathsWithTheRecordedPathAsValue() throws {
        let projectURL = tempRoot.appendingPathComponent("HG002 chr20.lungfish", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Analyses/map.lungfishmapping", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let outsideURL = tempRoot.appendingPathComponent("elsewhere/ref.fa")
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">r\nACGT\n".write(to: outsideURL, atomically: true, encoding: .utf8)

        let viewModel = DocumentSectionViewModel()
        viewModel.bundleURL = bundleURL
        viewModel.mappingDocument = MappingDocumentState(
            title: "Mapping", subtitle: nil, summary: nil,
            sourceData: [
                .projectLink(name: "reads", targetURL: readsURL),
                .filesystemLink(name: "ref", fileURL: outsideURL),
            ],
            contextRows: [], artifactRows: []
        )
        let window = host(ScrollView { MappingDocumentSection(viewModel: viewModel) })
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.value($0) == readsURL.path }
        }
        let caption = try XCTUnwrap(
            AccessibilityTreeProbe.all(in: window).first { AccessibilityTreeProbe.value($0) == readsURL.path },
            "no caption carries the recorded path as its value; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(caption), "Imports/reads.lungfishfastq", "the caption reads project-relative")
        XCTAssertNil(AccessibilityTreeProbe.help(caption), "the path is the value; the tooltip would repeat it")
        XCTAssertFalse(
            AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.label($0) == readsURL.path },
            "the absolute path is no longer the visible text"
        )

        let outside = try XCTUnwrap(
            AccessibilityTreeProbe.all(in: window).first { AccessibilityTreeProbe.value($0)?.hasSuffix(outsideURL.path) == true }
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(outside), "ref.fa (outside the project)")
    }
}
