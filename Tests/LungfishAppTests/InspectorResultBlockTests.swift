// InspectorResultBlockTests.swift - A result kind's Summary block leaves with its result (Phase 3.0 lane W6)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Walk OBS-W6 of 2026-10-24. After a NAO-MGS result, the Summary of the next Kraken2 single result, Kraken2 batch
// and TaxTriage result kept the "NAO-MGS Result" block (that sample, its virus hits, Top Taxon Rotavirus A) above
// the next result's own Operation Details. It is row 100 (obs-14, `InspectorBatchDetailsStaleTests`) in reverse.
//
// Each test opens a NAO-MGS or NVD result as the sidebar does (`displayContent(for:)`) and waits until the Summary
// draws its block. Then it opens another result kind and reads both the state that feeds the block and the drawn
// Summary. It opens the NAO-MGS or NVD result again before each next kind, so every kind meets a live block. The
// Summary is hosted on its own and read through the accessibility tree, as VoiceOver reads it. The result bundles
// come from the committed virus hits and BLAST tables through the production parser and database writers
// (RoutingSafetyNetFixtures).
//
// The test methods are synchronous and wait by turning the main run loop, which runs the routes' main-actor loads
// and SwiftUI's updates. A run-loop wait inside an async test runs other tasks' jobs inside the test's own task,
// which aborted the process ("freed pointer was not the last allocation"), so only `setUp` is async.

import AppKit
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class InspectorResultBlockTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!
    private var summaryWindow: NSWindow?
    private var naoMgs: URL!
    private var nvd: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "inspector-result-block")
        naoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-result", in: root).bundle
        nvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-result", in: root).bundle
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        summaryWindow?.close()
        summaryWindow = nil
        window.contentViewController = nil
        window = nil
        controller = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A Kraken2 single result, a Kraken2 batch, a TaxTriage, an EsViritu and an NVD result, each opened after a
    /// NAO-MGS result, show no NAO-MGS block.
    func testClassifierResultAfterNaoMgsClearsNaoMgsBlock() throws {
        let next = try classifierResults() + [
            NextResult(name: "an NVD result", item: item(nvd, .nvdResult)) { self.summary.nvdManifest != nil },
        ]

        assertBlockLeaves(
            "NAO-MGS Result",
            of: item(naoMgs, .naoMgsResult),
            state: { self.summary.naoMgsManifest?.sampleName },
            whenShown: next
        )
    }

    /// The NVD twin of the test above. An NVD result keeps its manifest the same way, so each result kind opened
    /// after it, a NAO-MGS result included, shows no NVD block.
    func testClassifierResultAfterNvdClearsNvdBlock() throws {
        let next = try classifierResults() + [
            NextResult(name: "a NAO-MGS result", item: item(naoMgs, .naoMgsResult)) {
                self.summary.naoMgsManifest != nil
            },
        ]

        assertBlockLeaves(
            "NVD Result",
            of: item(nvd, .nvdResult),
            state: { self.summary.nvdManifest?.experiment },
            whenShown: next
        )
    }

    // MARK: - Helpers

    private struct NextResult {
        let name: String
        let item: SidebarItem
        /// True once the result is on screen with its own Summary facts.
        let isShown: @MainActor () -> Bool
    }

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    /// Opens `item` and waits until the Summary draws `heading`, then opens each result of `next` in turn. After each
    /// it checks that `state`, the value that feeds the block, is gone and that the drawn Summary lost `heading`.
    private func assertBlockLeaves(
        _ heading: String,
        of opened: SidebarItem,
        state: @MainActor () -> String?,
        whenShown next: [NextResult]
    ) {
        let rendered = hostSummary()
        for result in next {
            controller.displayContent(for: opened)
            let loaded = waitUntilOnRunLoop(budget: .lookup) { state() != nil }
            XCTAssertTrue(loaded, "\(opened.title) never finished loading before \(result.name)")
            let drawn = waitUntilOnRunLoop(budget: .lookup) { SummaryText.shows(heading, in: rendered) }
            XCTAssertTrue(drawn, "the Summary never drew the \(heading) block of \(opened.title)\n\(SummaryText.dump(rendered))")

            controller.displayContent(for: result.item)
            let shown = waitUntilOnRunLoop(budget: .lookup) { result.isShown() }
            XCTAssertTrue(shown, "\(result.name) never opened with its own Summary facts")
            XCTAssertNil(state(), "\(result.name) opened after \(opened.title) must hold no \(heading) block")
            let gone = waitUntilOnRunLoop(budget: .standard) { !SummaryText.shows(heading, in: rendered) }
            XCTAssertTrue(gone, "the Summary of \(result.name) still draws the \(heading) block of \(opened.title)")
        }
    }

    /// The four classifier result kinds the walk opened after the NAO-MGS result. The Kraken2 single result's sidecar
    /// names its configuration, so it shows its own Operation Details as on the walk.
    private func classifierResults() throws -> [NextResult] {
        let single = try RoutingSafetyNetFixtures.kraken2Result(
            named: "kraken2-2026-10-24T10-00-00", in: root, samples: ["SRR12486983"]
        )
        try writeMetadata(tool: "kraken2", isBatch: false, in: single)
        try writeKraken2Sidecar(in: single)
        let batch = try RoutingSafetyNetFixtures.kraken2Result(
            named: "kraken2-batch-2026-10-24T11-00-00", in: root, samples: ["SRR12486983", "SRR12486989"],
            sampleSubdirectories: true
        )
        try writeMetadata(tool: "kraken2", isBatch: true, in: batch)
        let taxTriage = try RoutingSafetyNetFixtures.taxTriageResult(
            named: "taxtriage-2026-10-24T12-00-00", in: root, samples: ["cornea"]
        )
        try writeMetadata(tool: "taxtriage", isBatch: false, in: taxTriage)
        let esViritu = try RoutingSafetyNetFixtures.esVirituResult(
            named: "esviritu-2026-10-24T13-00-00", in: root, samples: ["SRR12486983"]
        )
        try writeMetadata(tool: "esviritu", isBatch: false, in: esViritu)
        return [
            NextResult(name: "a Kraken2 single result", item: item(single, .classificationResult)) {
                self.controller.viewerController.taxonomyViewController != nil
                    && self.summary.batchOperationTool == "Kraken2"
            },
            NextResult(name: "a Kraken2 batch", item: item(batch, .batchGroup)) {
                self.controller.viewerController.taxonomyViewController != nil
            },
            NextResult(name: "a TaxTriage result", item: item(taxTriage, .taxTriageResult)) {
                self.controller.viewerController.taxTriageViewController != nil
                    && self.summary.batchOperationTool == "TaxTriage"
            },
            NextResult(name: "an EsViritu result", item: item(esViritu, .esvirituResult)) {
                self.controller.viewerController.esVirituViewController != nil
            },
        ]
    }

    private func item(_ url: URL, _ type: SidebarItemType) -> SidebarItem {
        SidebarItem(title: url.lastPathComponent, type: type, url: url)
    }

    private func writeMetadata(tool: String, isBatch: Bool, in folder: URL) throws {
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: isBatch, created: Date()),
            to: folder
        )
    }

    private func writeKraken2Sidecar(in folder: URL) throws {
        let sidecar = """
        {"config":{"databaseName":"Viral","databaseVersion":"2026-01","goal":"profile","confidence":0.2,\
        "minimumHitGroups":2,"threads":1,"sampleDisplayName":"SRR12486983"},\
        "toolVersion":"2.1.3","runtime":42,"savedAt":"2026-10-01T00:00:00Z"}
        """
        try sidecar.write(
            to: folder.appendingPathComponent(ClassificationResult.sidecarFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Hosts the Inspector's Summary section on the Inspector's own view model and returns its window, the root of
    /// the accessibility tree. SwiftUI builds its accessibility nodes only once an assistive client is attached, and
    /// this app-level attribute is how such a client announces itself (as in `ProvenanceSectionAccessibilityTests`).
    private func hostSummary() -> NSWindow {
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let inspector = controller.inspectorController.viewModel
        let host = NSHostingView(
            rootView: MetagenomicsResultSummarySection(
                viewModel: inspector.documentSectionViewModel,
                twelveSViewModel: inspector.twelveSResultDisplaySectionViewModel,
                windowStateScope: inspector.windowStateScope
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
        let summaryHost = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        summaryHost.isReleasedWhenClosed = false
        summaryHost.contentView = host
        summaryHost.orderFront(nil)
        summaryWindow = summaryHost
        return summaryHost
    }
}

/// Reads the drawn Summary through the NSAccessibility tree, which holds SwiftUI's own text nodes.
@MainActor
private enum SummaryText {
    static func shows(_ text: String, in element: NSObject) -> Bool {
        if strings(of: element).contains(text) { return true }
        return children(of: element).contains { shows(text, in: $0) }
    }

    static func dump(_ element: NSObject, depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        let line = String(repeating: "  ", count: depth) + strings(of: element).joined(separator: " | ")
        return ([line] + children(of: element).map { dump($0, depth: depth + 1) }).joined(separator: "\n")
    }

    /// The label, the modern value and the legacy value, which for a SwiftUI text node echoes its text.
    private static func strings(of element: NSObject) -> [String] {
        let label = (element as AnyObject).accessibilityLabel?() ?? nil
        let value = element.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
        let legacy = element.accessibilityAttributeValue(.value) as? String
        return [label, value, legacy].compactMap { $0 }
    }

    private static func children(of element: NSObject) -> [NSObject] {
        let modern = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
        if !modern.isEmpty { return modern.compactMap { $0 as? NSObject } }
        return ((element.accessibilityAttributeValue(.children) as? [Any]) ?? []).compactMap { $0 as? NSObject }
    }
}
