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

    func testNaoMgsViewStacksTaxonomyTableAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testTableContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testNvdViewStacksOutlineAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NvdResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testOutlineContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
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
}
