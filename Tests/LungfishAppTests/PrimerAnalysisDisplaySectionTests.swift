import AppKit
import SwiftUI
import XCTest
import ViewInspector
@testable import LungfishApp

@MainActor
final class PrimerAnalysisDisplaySectionTests: XCTestCase {
    func testViewTabRequiresAvailablePrimalDisplaySessionAndRoutesToItsControls() throws {
        let model = InspectorViewModel()
        model.primerAnalysisDocument = .init(bundleURL: URL(fileURLWithPath: "/fixture.lungfishprimeranalysis"))
        XCTAssertFalse(model.availableTabs.contains(.view))
        model.primerAnalysisDisplaySession = PrimerAnalysisDisplaySession()
        XCTAssertFalse(model.availableTabs.contains(.view))

        model.primerAnalysisDisplaySession = makeSession()
        XCTAssertTrue(model.availableTabs.contains(.view))
        model.selectedTab = .view
        XCTAssertNoThrow(try InspectorView(viewModel: model).inspect()
            .find(ViewType.View<PrimerAnalysisDisplaySection>.self))

        model.primerAnalysisDisplaySession = nil
        model.reconcileSelectedTab()
        XCTAssertEqual(model.selectedTab, .bundle)
    }

    func testStrandAndSpanControlsChangeSharedDisplaySettingsAndResetShowsAll() throws {
        let session = makeSession()
        let view = PrimerAnalysisDisplaySection(session: session)
        let inspected = try view.inspect()
        try inspected.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.forward"
        }).tap()
        try inspected.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.amplicons"
        }).tap()
        XCTAssertFalse(session.settings.showForward)
        XCTAssertFalse(session.settings.showAmplicons)
        XCTAssertTrue(session.settings.showReverse)
        XCTAssertEqual(session.visibleCount, 2)

        try inspected.find(button: "Show all").tap()
        XCTAssertTrue(session.settings.showForward)
        XCTAssertTrue(session.settings.showAmplicons)
        XCTAssertEqual(session.visibleCount, 4)
        XCTAssertFalse(session.settings.filterByCompatibility)
    }

    func testPoolToggleUsesSchemeIdentityRatherThanHidingSameNumberInOtherScheme() throws {
        let session = makeSession()
        let id = PrimerAnalysisDisplaySettings.poolID(resultID: "scheme-a", pool: 1)
        try PrimerAnalysisDisplaySection(session: session).inspect()
            .find(ViewType.Toggle.self, where: {
                try $0.accessibilityIdentifier() == "primerAnalysisDisplay.pool.\(id)"
            }).tap()
        XCTAssertEqual(session.visibleCount, 2)
        XCTAssertFalse(session.isVisible(session.targets[0].primers[0], in: session.targets[0]))
        XCTAssertTrue(session.isVisible(session.targets[1].primers[0], in: session.targets[1]))
    }

    func testIndividualCheckboxHidesOnlyThatNativeMemberAndCanRestoreIt() throws {
        let session = makeSession()
        let inspected = try PrimerAnalysisDisplaySection(session: session).inspect()
        let toggle = try inspected.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.primer.a-left"
        })
        try toggle.tap()
        XCTAssertEqual(session.settings.hiddenPrimerIDs, ["a-left"])
        XCTAssertEqual(session.visibleCount, 3)
        XCTAssertEqual(session.targets[0].primers.map(\.id), ["a-left", "a-right"])
        try toggle.tap()
        XCTAssertTrue(session.settings.hiddenPrimerIDs.isEmpty)
        XCTAssertEqual(session.visibleCount, 4)
    }

    func testIndividualCheckboxIsDisabledWhenAnotherFilterExcludesTheOligo() throws {
        let session = makeSession()
        session.setPoolShown(1, resultID: "scheme-a", shown: false)

        let toggle = try PrimerAnalysisDisplaySection(session: session).inspect()
            .find(ViewType.Toggle.self, where: {
                try $0.accessibilityIdentifier() == "primerAnalysisDisplay.primer.a-left"
            })

        XCTAssertTrue(toggle.isDisabled())
        XCTAssertFalse(try toggle.isOn())
        XCTAssertEqual(try toggle.help().string(), "Unavailable while Pool 1 is hidden.")
        XCTAssertTrue(session.settings.hiddenPrimerIDs.isEmpty)
        XCTAssertFalse(session.isVisible(session.targets[0].primers[0], in: session.targets[0]))

        session.setPoolShown(1, resultID: "scheme-a", shown: true)
        let restored = try PrimerAnalysisDisplaySection(session: session).inspect()
            .find(ViewType.Toggle.self, where: {
                try $0.accessibilityIdentifier() == "primerAnalysisDisplay.primer.a-left"
            })
        XCTAssertFalse(restored.isDisabled())
        XCTAssertTrue(try restored.isOn())
    }

    func testCompatibilityControlsRequireSavedAlignmentAndExplicitCalculation() async throws {
        let unavailable = try PrimerAnalysisDisplaySection(session: makeSession()).inspect()
        XCTAssertThrowsError(try unavailable.find(button: "Calculate MSA matches"))
        XCTAssertThrowsError(try unavailable.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.identityDots"
        }))

        let session = makeSession(withBinding: true)
        let before = try PrimerAnalysisDisplaySection(session: session).inspect()
        XCTAssertFalse(session.settings.filterByCompatibility)
        XCTAssertThrowsError(try before.find(ViewType.Slider.self))
        try before.find(button: "Calculate MSA matches").tap()
        for _ in 0..<100 where !session.compatibilityReady {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.compatibilityReady)
        let ready = try PrimerAnalysisDisplaySection(session: session).inspect()
        try ready.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.compatibilityFilter"
        }).tap()
        XCTAssertTrue(session.settings.filterByCompatibility)
        let filtering = try PrimerAnalysisDisplaySection(session: session).inspect()
        // SwiftUI's private Slider binding inspected here is normalized to 0...1.
        try filtering.find(ViewType.Slider.self).setValue(0.6)
        XCTAssertEqual(session.settings.minimumCompatibilityPercent, 60.0)
        try filtering.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.unassessed"
        }).tap()
        XCTAssertFalse(session.settings.showUnassessed)
        let excludedByMSA = try PrimerAnalysisDisplaySection(session: session).inspect()
            .find(ViewType.Toggle.self, where: {
                try $0.accessibilityIdentifier() == "primerAnalysisDisplay.primer.a-left"
            })
        XCTAssertTrue(excludedByMSA.isDisabled())
        XCTAssertFalse(try excludedByMSA.isOn())
        XCTAssertEqual(try excludedByMSA.help().string(),
                       "Unavailable because the MSA match filter excludes this oligo.")
        try filtering.find(ViewType.Toggle.self, where: {
            try $0.accessibilityIdentifier() == "primerAnalysisDisplay.identityDots"
        }).tap()
        XCTAssertFalse(session.settings.showIdentityDots)
    }

    func testRenderPrimerDisplayInspectorAtNativeWidths() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [CGFloat(320), 420] {
            let session = makeSession(withBinding: true)
            let model = InspectorViewModel()
            model.primerAnalysisDocument = .init(bundleURL: URL(fileURLWithPath: "/fixture.lungfishprimeranalysis"))
            model.primerAnalysisDisplaySession = session
            model.selectedTab = .view
            let host = NSHostingView(rootView: InspectorView(viewModel: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1050),
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
                .write(to: output.appendingPathComponent("primer-display-inspector-\(Int(width)).png"))
            window.close()
        }
    }

    private func makeSession(withBinding: Bool = false) -> PrimerAnalysisDisplaySession {
        func target(_ prefix: String, resultID: String, label: String) -> PrimerTargetDesignReview {
            .init(id: prefix, label: label, referenceLength: 4, coverageLabel: "Saved reference span", coveredBases: 4,
                intervals: [.init(id: "\(prefix)-amplicon", start: 0, end: 4, pool: 1,
                    primerIDs: ["\(prefix)-left", "\(prefix)-right"])],
                primers: [
                    .init(id: "\(prefix)-left", name: "\(prefix)_1_LEFT_1", start: 0, end: 2, strand: "+", pool: 1,
                          sequence: "AC", ampliconIDs: ["\(prefix)-amplicon"]),
                    .init(id: "\(prefix)-right", name: "\(prefix)_1_RIGHT_1", start: 2, end: 4, strand: "-", pool: 1,
                          sequence: "AC", ampliconIDs: ["\(prefix)-amplicon"])
                ], notes: [], sourceResultID: resultID, referenceID: "ref-\(prefix)")
        }
        let targets = [target("a", resultID: "scheme-a", label: "Scheme A · Reference A"),
                       target("b", resultID: "scheme-b", label: "Scheme B · Reference B")]
        let contexts: [PrimerBindingInspectionContext] = withBinding ? [
            .init(id: "context-a", title: "Reference A", alignedFASTA: ">one\nACGT\n>two\nATGT\n",
                annotations: [], primers: [
                    .init(id: "left", name: "a_1_LEFT_1", sequence: "AC", strand: "+", alignedStart: 0,
                          alignedEnd: 2, contiguousReference: true, reviewPrimerID: "a-left"),
                    .init(id: "right", name: "a_1_RIGHT_1", sequence: "AC", strand: "-", alignedStart: 2,
                          alignedEnd: 4, contiguousReference: true, reviewPrimerID: "a-right")
                ], unavailableReason: nil, rows: [
                    .init(name: "one", sequence: Array("ACGT")), .init(name: "two", sequence: Array("ATGT"))
                ])
        ] : []
        return PrimerAnalysisDisplaySession(targets: targets, bindingContexts: contexts)
    }
}
