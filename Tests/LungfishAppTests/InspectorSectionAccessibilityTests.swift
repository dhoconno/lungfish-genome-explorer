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
/// the variant selection list is capped; the MSA pairwise rows are table
/// rows; and a Run Inputs path reads project-relative with the recorded path
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
        // SwiftUI serves the actions in its own order; VoiceOver lists them
        // as a set, so the order is not asserted.
        XCTAssertEqual(Set(AccessibilityTreeProbe.customActionNames(row)), ["Reveal in Finder", "Quick Look", "Remove Attachment"])
        XCTAssertEqual(AccessibilityTreeProbe.customActionNames(row).count, 3, "each command once")
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

    func testDerivedAlignmentRowOffersRemoveAsACustomAction() throws {
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
        // The row's track button carries the command (the visible Remove
        // button beside it does too, which is harmless); the raw track's
        // button does not.
        let offering = AccessibilityTreeProbe.all(in: window).filter { AccessibilityTreeProbe.customActionNames($0).contains(title) }
        let row = try XCTUnwrap(
            offering.first { AccessibilityTreeProbe.label($0)?.contains("reads.q30.bam") == true },
            "the derived track's button must offer it; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertFalse(
            offering.contains { AccessibilityTreeProbe.label($0)?.hasPrefix("reads.bam") == true },
            "the raw track must not; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: title, on: row))
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
            (AccessibilityTreeProbe.label(cap) ?? AccessibilityTreeProbe.value(cap) ?? "").contains("Showing 100 of 150 selected rows"),
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

    // MARK: - MSA pairwise identity

    func testPairwiseIdentityRowsAreTableRowsReachableThroughAX() async throws {
        let records = [
            MSAAlignedRecord(name: "seq1", sequence: "ACGTACGTAC"),
            MSAAlignedRecord(name: "seq2", sequence: "ACGTACGAAC"),
            MSAAlignedRecord(name: "seq3", sequence: "ACGTTCGAAC"),
        ]
        let model = MSAPairwiseIdentityInspectorModel(
            bundleURL: tempRoot.appendingPathComponent("panel.lungfishmsa"),
            recordLoader: { _ in records }
        )
        model.onExportRequested = { _ in }
        await model.compute()
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.pairs.count, 3)

        let window = host(MSAPairwiseIdentitySection(model: model, isExpanded: .constant(true)))
        AccessibilityTreeProbe.waitUntil { tableView(in: window) != nil }
        let table = try XCTUnwrap(tableView(in: window), "no NSTableView hosts the pairs; tree:\n" + AccessibilityTreeProbe.dump(window))
        AccessibilityTreeProbe.waitUntil { table.numberOfRows == 3 }
        XCTAssertEqual(table.numberOfRows, 3)
        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 3, "one AX row per pair")
        XCTAssertEqual(table.tableColumns.map(\.title), ["Sequence A", "Sequence B", model.model.displayName, "Sites"])

        // Sorting still goes through the model's comparator list.
        model.sortOrder = [KeyPathComparator(\.sortableValue, order: .forward)]
        XCTAssertEqual(model.sortedPairs.first.map { "\($0.rowName)/\($0.columnName)" }, "seq1/seq3", "the least identical pair first")
    }

    private func tableView(in window: NSWindow) -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
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
        XCTAssertEqual(AccessibilityTreeProbe.help(caption), readsURL.path)
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
