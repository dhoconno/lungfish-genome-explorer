import AppKit
import SwiftUI
import XCTest
import LungfishIO
import ViewInspector
@testable import LungfishApp

@MainActor
final class PrimerOrderExportViewTests: XCTestCase {
    func testOrderNameBindingDisablesExportWhenEmptyAndRestoresItWhenNamed() throws {
        let model = PrimerOrderExportViewModel(draft: makeDraft())
        let view = PrimerOrderExportView(model: model, onCancel: {}, onExport: { _, _ in })
        try view.inspect().find(ViewType.TextField.self, where: {
            try $0.accessibilityIdentifier() == "primerOrderExport.name"
        }).setInput("   ")
        XCTAssertEqual(model.metadata.name, "   ")
        XCTAssertTrue(try view.inspect().find(button: "Export").isDisabled())
        try view.inspect().find(ViewType.TextField.self, where: {
            try $0.accessibilityIdentifier() == "primerOrderExport.name"
        }).setInput("Reviewed order")
        XCTAssertFalse(try view.inspect().find(button: "Export").isDisabled())
    }

    func testExportForwardsAllFrozenMembersAndOptionalMetadataBeyondPreview() throws {
        let draft = makeDraft(count: 13)
        let model = PrimerOrderExportViewModel(draft: draft)
        XCTAssertEqual(model.metadata.name, "Displayed primer order")
        XCTAssertEqual(model.metadata.requestedBy, "")
        XCTAssertEqual(model.metadata.project, "")
        XCTAssertEqual(model.metadata.orderReference, "")
        XCTAssertEqual(model.metadata.notes, "")
        model.metadataExpanded = true
        var exportedDraft: PrimerOrderDraft?
        var exportedMetadata: PrimerOrderMetadata?
        let view = PrimerOrderExportView(model: model, onCancel: {}, onExport: {
            exportedDraft = $0
            exportedMetadata = $1
        })
        let inspected = try view.inspect()
        for (id, value) in [("requestedBy", "Scientist"), ("project", "Genetics review"),
                            ("orderReference", "Order 42"), ("notes", "Keep the saved 5′–3′ sequences.")] {
            try inspected.find(ViewType.TextField.self, where: {
                try $0.accessibilityIdentifier() == "primerOrderExport.\(id)"
            }).setInput(value)
        }
        XCTAssertEqual(model.metadata.requestedBy, "Scientist")
        XCTAssertEqual(model.metadata.project, "Genetics review")
        XCTAssertEqual(model.metadata.orderReference, "Order 42")
        XCTAssertEqual(model.metadata.notes, "Keep the saved 5′–3′ sequences.")
        XCTAssertNoThrow(try inspected.find(text: "oligo_1"))
        XCTAssertNoThrow(try inspected.find(text: "oligo_8"))
        XCTAssertThrowsError(try inspected.find(text: "oligo_9"))
        try inspected.find(button: "Export").tap()
        XCTAssertEqual(exportedDraft?.id, draft.id)
        XCTAssertEqual(exportedDraft?.oligos.count, 13)
        XCTAssertEqual(exportedDraft?.selection.selectedPrimerIDs, (1...13).map { "primer-\($0)" })
        XCTAssertEqual(exportedMetadata, model.metadata)
    }

    func testCancelDoesNotSubmitFrozenSelection() throws {
        var canceled = false
        var submitted = false
        let view = PrimerOrderExportView(model: .init(draft: makeDraft()), onCancel: {
            canceled = true
        }, onExport: { _, _ in submitted = true })
        try view.inspect().find(button: "Cancel").tap()
        XCTAssertTrue(canceled)
        XCTAssertFalse(submitted)
    }

    func testUnavailableSessionDisablesInspectorOrderExport() throws {
        let session = PrimerAnalysisDisplaySession()
        let inspected = try PrimerAnalysisDisplaySection(session: session).inspect()
        XCTAssertTrue(try inspected.find(button: "Export displayed primer order…").isDisabled())
    }

    func testSavedOrderResultShowsEveryExportedMemberAndVerifiedOutputActions() throws {
        let document = makeDocument(count: 13)
        let inspected = try PrimerOrderResultContent(document: document,
            orderURL: URL(fileURLWithPath: document.outputDirectoryPath)).inspect()
        for index in 1...13 {
            XCTAssertNoThrow(try inspected.find(text: "oligo_\(index)"))
        }
        XCTAssertNoThrow(try inspected.find(button: "Open order workbook"))
        XCTAssertNoThrow(try inspected.find(button: "Open IDT upload copy"))
        XCTAssertNoThrow(try inspected.find(button: "Open CSV"))
    }

    func testRenderSavedOrderResultAtNarrowAndWideWidths() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let document = makeDocument(count: 13)
        for width in [CGFloat(640), 1100] {
            let host = NSHostingView(rootView: PrimerOrderResultContent(document: document,
                orderURL: URL(fileURLWithPath: document.outputDirectoryPath)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("primer-order-result-\(Int(width)).png"))
            window.close()
        }
    }

    func testRenderOrderReviewSheetWithMultiplePoolsAndMetadata() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for expanded in [false, true] {
            let model = PrimerOrderExportViewModel(draft: makeDraft(count: 13))
            model.metadataExpanded = expanded
            if expanded {
                model.metadata.requestedBy = "Scientist"
                model.metadata.project = "Genetics review"
                model.metadata.orderReference = "Order 42"
                model.metadata.notes = "Sequences remain in the saved 5′–3′ orientation."
            }
            let host = NSHostingView(rootView: PrimerOrderExportView(model: model,
                onCancel: {}, onExport: { _, _ in }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 820),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = window.contentLayoutRect
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(expanded ? "primer-order-review-metadata.png" : "primer-order-review.png"))
            window.close()
        }
    }

    private func makeDraft(count: Int = 2) -> PrimerOrderDraft {
        let url = URL(fileURLWithPath: "/Project/Analyses/Saved design.lungfishprimeranalysis")
        let artifact = PrimerAnalysisArtifact(relativePath: "provenance.json", role: "provenance",
            format: "json", sha256: String(repeating: "0", count: 64), byteSize: 0)
        let manifest = PrimerAnalysisManifest(analysisID: UUID(), runID: UUID(), inputs: [], results: [],
            artifacts: [], provenance: artifact, grouping: .independent, publishedRootPath: url.path)
        let oligos = (1...count).map { index in
            PrimerOrderOligo(primerID: "primer-\(index)", targetID: "target-\(index % 2)",
                sourceResultID: "scheme-\(index % 2)", schemeLabel: "Scheme \(index % 2 + 1)",
                poolName: "Scheme \(index % 2 + 1) · Pool 1", pool: 1, referenceID: "reference-\(index % 2)",
                name: "oligo_\(index)", sequence: "ACGTACGTACGTACGTACGT", start: 0, end: 20,
                strand: index % 2 == 0 ? "+" : "-", ampliconIDs: ["amplicon-\(index)"], compatibility: nil)
        }
        let selection = PrimerOrderSelection(capturedAt: Date(timeIntervalSince1970: 100), analysisURL: url,
            manifest: manifest, settings: .init(), compatibilityReady: false, compatibilitySummaries: [:],
            selectedPrimerIDs: oligos.map(\.primerID))
        return PrimerOrderDraft(selection: selection, oligos: oligos, defaultName: "Displayed primer order")
    }

    private func makeDocument(count: Int) -> PrimerOrderDocument {
        let draft = makeDraft(count: count)
        return PrimerOrderDocument(schemaVersion: 1, metadata: .init(name: "Reviewed primer order"),
            selection: draft.selection, oligos: draft.oligos, outputDirectoryPath: "/Project/Analyses/Reviewed order",
            templateSHA256: String(repeating: "0", count: 64), sequenceSemantics: "saved-5prime-to-3prime")
    }
}
