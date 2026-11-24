// MetagenomicsLayoutDefaultsInjectionTests.swift - The result viewers read their panel layout from the defaults they were given (VS-LEAK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Kraken2, EsViritu, NAO-MGS and NVD viewers build their split from the panel layout preference. Under xctest
// `UserDefaults.standard` is one domain that every xctest process of the account shares, so a viewer that reads it can
// build another process's layout for a moment (`testKraken2KeepsItsViewThroughARelaunch` failed that way, VS-MAP-2 SWIFT
// ruling 6). Each case gives the viewers a suite of its own, the way a view-switch window does, and writes nothing to
// the account's defaults.

import AppKit
import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
@testable import LungfishTaxonomyUI

@MainActor
final class MetagenomicsLayoutDefaultsInjectionTests: XCTestCase {
    private enum Viewer: String, CaseIterable {
        case kraken2 = "Kraken2"
        case esViritu = "EsViritu"
        case naoMgs = "NAO-MGS"
        case nvd = "NVD"
    }

    /// What the account's defaults held for the layout key when the case began, which it must still hold at its end.
    private var accountLayoutAtStart: String?

    override func setUp() async throws {
        accountLayoutAtStart = UserDefaults.standard.string(forKey: MetagenomicsPanelLayout.defaultsKey)
    }

    override func tearDown() async throws {
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MetagenomicsPanelLayout.defaultsKey), accountLayoutAtStart,
            "the case wrote the panel layout to the account's defaults"
        )
    }

    /// A suite of this case's own, which a viewer made from here on reads, as it does in a view-switch window. It says
    /// `layout`, or nothing when `layout` is nil. It posts no layout swap, so no other live viewer reads it.
    private func redirectToSuite(saying layout: MetagenomicsPanelLayout?) {
        let suite = makeTestDefaultsSuite(prefix: "MetagenomicsLayoutDefaultsInjectionTests")
        layout?.persist(defaults: suite.defaults, notificationCenter: NotificationCenter())
        MetadataLayoutDefaults.redirect(to: suite.defaults)
        addTeardownBlock { await MainActor.run { MetadataLayoutDefaults.restore(from: suite.defaults) } }
    }

    /// Whether the viewer builds its panes side by side, which every layout but the stacked one does.
    private func buildsSideBySide(_ viewer: Viewer) -> Bool {
        switch viewer {
        case .kraken2:
            let built = TaxonomyViewController()
            _ = built.view
            return built.testSplitView.isVertical
        case .esViritu:
            let built = EsVirituResultViewController()
            _ = built.view
            return built.testSplitView.isVertical
        case .naoMgs:
            let built = NaoMgsResultViewController()
            _ = built.view
            return built.testSplitView.isVertical
        case .nvd:
            let built = NvdResultViewController()
            _ = built.view
            return built.testSplitView.isVertical
        }
    }

    func testEveryViewerBuildsStackedFromASuiteThatSaysStacked() {
        redirectToSuite(saying: .stacked)
        for viewer in Viewer.allCases {
            XCTAssertFalse(buildsSideBySide(viewer), "\(viewer.rawValue): a suite that says stacked builds stacked panes")
        }
    }

    func testEveryViewerBuildsItsDefaultFromAnEmptySuite() {
        redirectToSuite(saying: nil)
        for viewer in Viewer.allCases {
            XCTAssertTrue(buildsSideBySide(viewer), "\(viewer.rawValue): an empty suite builds the default, side by side")
        }
    }

    func testEveryViewerBuildsListLeadingFromASuiteThatSaysListLeading() {
        redirectToSuite(saying: .listLeading)
        for viewer in Viewer.allCases {
            XCTAssertTrue(buildsSideBySide(viewer), "\(viewer.rawValue): list leading is side by side")
        }
        let built = TaxonomyViewController()
        _ = built.view
        XCTAssertTrue(
            built.testSplitView.arrangedSubviews[0].subviews.contains(built.testTableView),
            "a suite that says list leading puts the table first, which the default does not"
        )
    }
}
