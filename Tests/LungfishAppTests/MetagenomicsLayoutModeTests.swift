import XCTest
@testable import LungfishApp

@MainActor
final class MetagenomicsLayoutModeTests: XCTestCase {
    private func setLayoutPreference(
        _ layout: MetagenomicsPanelLayout,
        legacyTableOnLeft: Bool
    ) {
        UserDefaults.standard.set(layout.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        UserDefaults.standard.set(legacyTableOnLeft, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
    }

    nonisolated private static func clearLayoutPreference() {
        UserDefaults.standard.removeObject(forKey: "metagenomicsPanelLayout")
        UserDefaults.standard.removeObject(forKey: "metagenomicsTableOnLeft")
    }

    override func tearDown() {
        Self.clearLayoutPreference()
        super.tearDown()
    }

    func testTaxonomyViewStacksTableAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0].subviews.contains(vc.testTableView))
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1].subviews.contains(vc.testSunburstView))
    }

    func testTaxonomyLiveWindowKeepsBothPanesVisibleInStackedMode() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.height, 120)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.height, 120)
    }

    func testTaxonomyLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxonomyViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testNaoMgsViewStacksTaxonomyTableAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testTableContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testNaoMgsLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NaoMgsResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testNvdViewStacksOutlineAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NvdResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testOutlineContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testNvdLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NvdResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testTaxTriageViewStacksListAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testRightPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testLeftPaneContainer)
    }

    func testTaxTriageLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testEsVirituLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = EsVirituResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testTaxonomyViewDidLayoutDoesNotApplyNewPreferenceWithoutNotification() {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        let initialFirstPane = vc.testSplitView.arrangedSubviews[0]
        let initialSecondPane = vc.testSplitView.arrangedSubviews[1]

        setLayoutPreference(.stacked, legacyTableOnLeft: false)
        vc.viewDidLayout()

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === initialFirstPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === initialSecondPane)
    }

    func testNaoMgsViewDidLayoutDoesNotApplyNewPreferenceWithoutNotification() {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        let initialFirstPane = vc.testSplitView.arrangedSubviews[0]
        let initialSecondPane = vc.testSplitView.arrangedSubviews[1]

        setLayoutPreference(.stacked, legacyTableOnLeft: false)
        vc.viewDidLayout()

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === initialFirstPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === initialSecondPane)
    }

    func testTaxTriageLayoutChangeResetsCollapsedStackedPaneToSensibleWidth() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        vc.testSplitView.setPosition(80, ofDividerAt: 0)

        setLayoutPreference(.listLeading, legacyTableOnLeft: true)
        NotificationCenter.default.post(name: .metagenomicsLayoutSwapRequested, object: nil)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let firstPaneWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let secondPaneWidth = vc.testSplitView.arrangedSubviews[1].frame.width
        XCTAssertGreaterThan(firstPaneWidth, 200)
        XCTAssertGreaterThan(secondPaneWidth, 80)
    }

    func testTaxTriageSplitAllowsHiddenTrailingDetailPaneToFullyCollapse() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        vc.testSplitView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        vc.testSplitView.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        vc.testLeftPaneContainer.isHidden = true

        let totalExtent = vc.testSplitView.bounds.height
        let clamped = vc.splitView(
            vc.testSplitView,
            constrainSplitPosition: totalExtent,
            ofSubviewAt: 0
        )

        XCTAssertEqual(clamped, totalExtent, accuracy: 0.5)
    }
}
