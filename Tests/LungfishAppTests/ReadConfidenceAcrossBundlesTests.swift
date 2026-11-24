// ReadConfidenceAcrossBundlesTests.swift - A Minimum alignment confidence belongs to the bundle it was set on (Phase 3.2 lane S3BESIDE, ALIGN-CONFIDENCE-CARRY)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// W-27 of the 3.2 session 1 walk. A confidence of 30 set on one reference stayed 30 on the next bundle that opened, because
// `ReadStyleSectionViewModel.clear()` did not reset `minMapQ`, and the open pushes the block's value to the viewport. Depth and
// the pale reads changed and only the Inspector showed the filter. Both tests go through the sidebar and the Inspector's block,
// the only production writer of the viewport's filter, as `ReferenceBundleReadFilterSameRowTests` does. No store keeps the
// value per bundle (`rg minMapQ Sources` finds the block, the notification and the viewer), so the row is a reset.
//
// The manager ruled on the first agent's open question (option b, 2026-11-06). The confidence resets only when a different bundle
// opens, and selecting the same reference row again keeps the value the person set, as REFMAP's rule keeps a read group filter
// (`ReferenceBundleReadFilterSameRowTests`). `testAConfidenceStaysWhenTheSameRowIsSelectedAgain` pins that case. A reset inside
// `ReadStyleSectionViewModel.clear()` fails it, because the Inspector clears the block on every selection, the same row included.
//
// The fix round (BIO SF2, 2026-11-06) widens the same rule to every filter that reaches depth and read counts. The consensus
// quality limits, the duplicate, secondary and supplementary toggles and the read group filter start at their defaults when a
// different bundle opens, and the same bundle keeps them. `testTheOtherDepthFiltersReadTheDefaultOnTheNextBundleThatOpens` pins it.
//
// ALIGNCARRY (Phase 3.3, ALIGN-CONSENSUS-SETTINGS-CARRY). The six consensus settings, which are the masking switch, the gap threshold,
// the minimum depth, the masking depth, the caller mode and the IUPAC switch, ride in the same payload and carried to the next bundle,
// so the consensus track and an export made from it used another bundle's values. They follow the rule of the depth filters.
// `testConsensusSettingsResetOnADifferentBundle` goes through the window and the viewport the track and the export read.
// `testTheSixConsensusSettingsFollowTheBundleRuleOfTheDepthFilters` pins the block's rule, the same bundle and classifier evidence included.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class ReadConfidenceAcrossBundlesTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ReadConfidenceAcrossBundles")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    /// Two reference rows of the window's sidebar, each built in a folder of its own, so each is a bundle of its own.
    private func twoReferenceRows() async throws -> (first: RoutingRowFixture, second: RoutingRowFixture) {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Reference" })
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let firstRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("first", isDirectory: true))
        let secondRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("second", isDirectory: true))
        let first = try await row.build(RoutingRowContext(root: firstRoot, paths: SafetyNetPathRenderer(root: firstRoot)))
        let second = try await row.build(RoutingRowContext(root: secondRoot, paths: SafetyNetPathRenderer(root: secondRoot)))
        return (first, second)
    }

    private func openedBundleURL(_ viewer: ViewerViewController) -> URL? {
        viewer.referenceBundleViewportController?.testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
    }

    private func viewportConfidence(_ viewer: ViewerViewController) -> Int? {
        viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView.minMapQSetting
    }

    /// What a person does: set the confidence on one reference, then select another reference.
    func testAConfidenceSetOnOneBundleReadsTheDefaultOnTheNextBundleThatOpens() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let firstOpened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(firstOpened, "the first reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the first bundle's viewport")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        XCTAssertEqual(readStyle.minMapQ, 0, "the Inspector shows the first bundle's confidence on the second bundle")
        XCTAssertEqual(viewportConfidence(viewer), 0, "the second bundle's reads and depth are filtered by the first bundle's confidence")
    }

    /// A value set on a bundle stays while that bundle stays open, in focus mode and under a later push of the block's settings.
    func testAConfidenceStaysWhileTheSameBundleStaysOpen() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let opened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        viewport.testEnterFocusedDetailMode()
        XCTAssertEqual(viewportConfidence(viewer), 30, "focus mode took the confidence away")
        XCTAssertEqual(readStyle.minMapQ, 30, "focus mode took the confidence out of the Inspector")

        readStyle.onSettingsChanged?()
        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "a later push rebuilt the viewport")
        XCTAssertEqual(viewportConfidence(viewer), 30, "a later push took the confidence away")
        XCTAssertEqual(readStyle.minMapQ, 30, "the Inspector no longer shows the confidence the reads are under")
    }

    /// REFMAP's rule for the confidence: a value set in the Inspector stays when the same reference row is selected again.
    func testAConfidenceStaysWhenTheSameRowIsSelectedAgain() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let opened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the viewport")

        harness.select(rows.first.item)
        await harness.split.bundleOpenTask?.value

        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "the same input rebuilt the viewport")
        XCTAssertEqual(readStyle.minMapQ, 30, "the same row took the confidence away from the Inspector")
        XCTAssertEqual(viewportConfidence(viewer), 30, "the same row took the confidence away from the reads and depth")
    }

    /// The block's own rule, without a window. The same bundle keeps the value across the clear that every selection makes. A
    /// different bundle starts at the default, and so does a return to the first bundle after a second one. Classifier evidence
    /// starts at the default and leaves no bundle behind. The consensus confidence and the read group filter follow the same rule
    /// (BIO SF2), and the same bundle keeps them as REFMAP's rule keeps a read group filter.
    func testTheBlockResetsOnlyWhenADifferentBundleLoads() {
        let viewModel = ReadStyleSectionViewModel()
        let first = root.appendingPathComponent("first.lungfishref", isDirectory: true)
        let second = root.appendingPathComponent("second.lungfishref", isDirectory: true)

        viewModel.resetConfidenceUnlessSameBundle(at: first)
        viewModel.minMapQ = 30
        viewModel.consensusMinMapQ = 30
        viewModel.selectedReadGroups = ["S1-rg"]
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 30, "the same bundle lost its confidence")
        XCTAssertEqual(viewModel.consensusMinMapQ, 30, "the same bundle lost its consensus confidence")
        XCTAssertEqual(viewModel.selectedReadGroups, ["S1-rg"], "the same bundle lost its read group filter")

        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: second)
        XCTAssertEqual(viewModel.minMapQ, 0, "a different bundle kept the confidence")
        XCTAssertEqual(viewModel.consensusMinMapQ, 0, "a different bundle kept the consensus confidence")
        XCTAssertTrue(viewModel.selectedReadGroups.isEmpty, "a different bundle kept the read group filter")

        viewModel.minMapQ = 20
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 0, "a return to the first bundle kept the second bundle's confidence")

        viewModel.minMapQ = 10
        viewModel.consensusMinBaseQ = 20
        viewModel.resetConfidenceForClassifierEvidence()
        XCTAssertEqual(viewModel.minMapQ, 0, "classifier evidence kept a bundle's confidence")
        XCTAssertEqual(viewModel.consensusMinBaseQ, 0, "classifier evidence kept a bundle's consensus base quality")
        viewModel.minMapQ = 5
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(viewModel.minMapQ, 0, "a bundle kept the confidence set on classifier evidence")
    }

    /// A confidence kept across a detour to an item that opens no reference bundle must reach the viewport that reopens the bundle.
    /// The bundle is still the last one the block loaded, so the Inspector keeps the value, and the reads and depth must be under it.
    func testAConfidenceSurvivesADetourToAnotherItemAndTheViewportAgrees() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let opened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the viewport")

        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Quick Look" })
        let detourRow = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let detourRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("detour", isDirectory: true))
        let detour = try await detourRow.build(RoutingRowContext(root: detourRoot, paths: SafetyNetPathRenderer(root: detourRoot)))
        harness.select(detour.item)
        await harness.split.bundleOpenTask?.value
        harness.select(rows.first.item)
        await harness.split.bundleOpenTask?.value
        let reopened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) == firstURL && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(reopened, "the first reference never reopened after the detour")

        XCTAssertEqual(readStyle.minMapQ, 30, "the detour took the confidence away from the Inspector")
        XCTAssertEqual(
            viewportConfidence(viewer), 30,
            "the reopened bundle's reads and depth are not under the confidence the Inspector shows"
        )
    }

    /// The other filters that reach depth and read counts go back to their defaults with the confidence when a different bundle
    /// opens, in the Inspector and in the viewport that depth and the reads come from.
    func testTheOtherDepthFiltersReadTheDefaultOnTheNextBundleThatOpens() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let firstOpened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(firstOpened, "the first reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.consensusMinMapQ = 30
        readStyle.consensusMinBaseQ = 20
        readStyle.showDuplicates = true
        readStyle.showSecondary = true
        readStyle.showSupplementary = true
        readStyle.selectedReadGroups = ["S1-rg"]
        readStyle.onSettingsChanged?()
        let firstView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(firstView.consensusMinMapQSetting, 30, "the Inspector's consensus confidence never reached the first viewport")
        XCTAssertEqual(firstView.selectedReadGroupsSetting, ["S1-rg"], "the Inspector's read group filter never reached the first viewport")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        let fresh = ReadStyleSectionViewModel()
        XCTAssertEqual(readStyle.consensusMinMapQ, fresh.consensusMinMapQ, "the Inspector shows the first bundle's consensus confidence")
        XCTAssertEqual(readStyle.consensusMinBaseQ, fresh.consensusMinBaseQ, "the Inspector shows the first bundle's consensus base quality")
        XCTAssertEqual(readStyle.showDuplicates, fresh.showDuplicates, "the Inspector includes duplicates on the second bundle")
        XCTAssertEqual(readStyle.showSecondary, fresh.showSecondary, "the Inspector includes secondary alignments on the second bundle")
        XCTAssertEqual(readStyle.showSupplementary, fresh.showSupplementary, "the Inspector includes supplementary alignments on the second bundle")
        XCTAssertEqual(readStyle.selectedReadGroups, fresh.selectedReadGroups, "the Inspector keeps the first bundle's read group filter")

        let secondView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(secondView.consensusMinMapQSetting, 0, "the second bundle's depth is filtered by the first bundle's consensus confidence")
        XCTAssertEqual(secondView.consensusMinBaseQSetting, 0, "the second bundle's depth is filtered by the first bundle's base quality")
        XCTAssertEqual(secondView.excludeFlagsSetting, fresh.computedExcludeFlags, "the second bundle's reads are filtered by the first bundle's flags")
        XCTAssertTrue(secondView.selectedReadGroupsSetting.isEmpty, "the second bundle's reads are filtered by the first bundle's read groups")
    }

    /// The reset reaches the viewport while the Inspector is hidden. The slider's change handler lives in the Inspector's own view,
    /// so if that view were what carried the reset, a hidden Inspector would read 0 when it returned while the reads stayed at 30.
    func testTheResetReachesTheViewportWhileTheInspectorIsHidden() async throws {
        // Collapsing the window's Inspector saves its state to the runner's defaults, so these keys go back as they were.
        let panelDefaults = HostDefaultsRestorer(keys: [
            MainSplitViewController.sidebarCollapsedDefaultsKey, MainSplitViewController.inspectorCollapsedDefaultsKey,
            MainSplitViewController.sidebarWidthDefaultsKey, MainSplitViewController.inspectorWidthDefaultsKey,
        ])
        defer { panelDefaults.restore() }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(rows.first.item)
        let firstOpened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(firstOpened, "the first reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the first bundle's viewport")

        harness.split.setInspectorVisible(false, animated: false, source: "ReadConfidenceAcrossBundlesTests")
        XCTAssertFalse(harness.split.isInspectorVisible, "the window's Inspector did not collapse")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")

        XCTAssertEqual(readStyle.minMapQ, 0, "the Inspector keeps the first bundle's confidence on the second bundle")
        XCTAssertEqual(
            viewportConfidence(viewer), 0,
            "the second bundle's reads and depth stay under the first bundle's confidence while the Inspector is hidden"
        )
    }

    private func consensusSix(of block: ReadStyleSectionViewModel) -> ConsensusSix {
        ConsensusSix(
            masking: block.consensusMaskingEnabled, gapPercent: Int(block.consensusGapThresholdPercent),
            minDepth: Int(block.consensusMinDepth), maskingMinDepth: Int(block.consensusMaskingMinDepth),
            mode: block.consensusMode, ambiguity: block.consensusUseAmbiguity
        )
    }

    private func consensusSix(of view: SequenceViewerView) -> ConsensusSix {
        ConsensusSix(
            masking: view.consensusMaskingEnabledSetting, gapPercent: view.consensusGapThresholdPercentSetting,
            minDepth: view.consensusMinDepthSetting, maskingMinDepth: view.consensusMaskingMinDepthSetting,
            mode: view.consensusModeSetting, ambiguity: view.consensusUseAmbiguitySetting
        )
    }

    private func write(_ six: ConsensusSix, to block: ReadStyleSectionViewModel) {
        block.consensusMaskingEnabled = six.masking
        block.consensusGapThresholdPercent = Double(six.gapPercent)
        block.consensusMinDepth = Double(six.minDepth)
        block.consensusMaskingMinDepth = Double(six.maskingMinDepth)
        block.consensusMode = six.mode
        block.consensusUseAmbiguity = six.ambiguity
    }

    /// The six consensus settings belong to the bundle they were set on. A different bundle opens with the declared defaults in the
    /// Inspector and in the viewport that draws the consensus track and builds an export. Reselecting the first bundle after a
    /// second one is a different bundle again (the W-27 rule), so the first bundle's old values do not come back and the second
    /// bundle's values do not follow.
    func testConsensusSettingsResetOnADifferentBundle() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rows = try await twoReferenceRows()
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel
        let declared = consensusSix(of: ReadStyleSectionViewModel())
        XCTAssertNotEqual(ConsensusSix.setOnFirstBundle, declared, "the values the test sets on the first bundle are the defaults")
        XCTAssertNotEqual(ConsensusSix.setOnSecondBundle, declared, "the values the test sets on the second bundle are the defaults")

        harness.select(rows.first.item)
        let firstOpened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) != nil && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(firstOpened, "the first reference never opened and wired its read filter")
        let firstURL = try XCTUnwrap(openedBundleURL(viewer))

        write(.setOnFirstBundle, to: readStyle)
        readStyle.onSettingsChanged?()
        let firstView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(consensusSix(of: firstView), .setOnFirstBundle, "the Inspector's consensus settings never reached the first viewport")

        harness.select(rows.second.item)
        await harness.split.bundleOpenTask?.value
        let secondOpened = await waitUntil(budget: .lookup) {
            if let url = self.openedBundleURL(viewer), url != firstURL { return readStyle.onSettingsChanged != nil }
            return false
        }
        XCTAssertTrue(secondOpened, "the second reference never opened")
        XCTAssertEqual(consensusSix(of: readStyle), declared, "the Inspector shows the first bundle's consensus settings on the second bundle")
        let secondView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(
            consensusSix(of: secondView), declared,
            "the second bundle's consensus track and export use the settings of the first bundle"
        )

        write(.setOnSecondBundle, to: readStyle)
        readStyle.onSettingsChanged?()
        XCTAssertEqual(consensusSix(of: secondView), .setOnSecondBundle, "the Inspector's consensus settings never reached the second viewport")

        harness.select(rows.first.item)
        await harness.split.bundleOpenTask?.value
        let reopened = await waitUntil(budget: .lookup) {
            self.openedBundleURL(viewer) == firstURL && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(reopened, "the first reference never reopened")
        XCTAssertEqual(consensusSix(of: readStyle), declared, "a return to the first bundle kept the settings of the second bundle")
        let returnedView = try XCTUnwrap(viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewerView)
        XCTAssertEqual(
            consensusSix(of: returnedView), declared,
            "the first bundle's consensus track and export use the settings of the second bundle after a return"
        )
    }

    /// The block's own rule for the six, without a window. The same bundle keeps them across the clear that every selection makes.
    /// A different bundle starts at the declared defaults, and so does a return to the first bundle after a second one. Classifier
    /// evidence starts at the defaults and leaves no bundle behind, as it does for the depth filters.
    func testTheSixConsensusSettingsFollowTheBundleRuleOfTheDepthFilters() {
        let viewModel = ReadStyleSectionViewModel()
        let declared = consensusSix(of: ReadStyleSectionViewModel())
        let first = root.appendingPathComponent("first.lungfishref", isDirectory: true)
        let second = root.appendingPathComponent("second.lungfishref", isDirectory: true)

        viewModel.resetConfidenceUnlessSameBundle(at: first)
        write(.setOnFirstBundle, to: viewModel)
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(consensusSix(of: viewModel), .setOnFirstBundle, "the same bundle lost its consensus settings")

        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: second)
        XCTAssertEqual(consensusSix(of: viewModel), declared, "a different bundle kept the consensus settings")

        write(.setOnSecondBundle, to: viewModel)
        viewModel.clear()
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(consensusSix(of: viewModel), declared, "a return to the first bundle kept the second bundle's consensus settings")

        write(.setOnFirstBundle, to: viewModel)
        viewModel.resetConfidenceForClassifierEvidence()
        XCTAssertEqual(consensusSix(of: viewModel), declared, "classifier evidence kept a bundle's consensus settings")
        write(.setOnSecondBundle, to: viewModel)
        viewModel.resetConfidenceUnlessSameBundle(at: first)
        XCTAssertEqual(consensusSix(of: viewModel), declared, "a bundle kept the consensus settings set on classifier evidence")
    }
}

// MARK: - The view memory store as the one source when the bundle reopens (VS-MAP-2 item 2, VS B6)

extension ReadConfidenceAcrossBundlesTests {
    private static let word5a = ViewMemoryFilterLineForm.hiddenWithoutCount(kind: "Read", noun: "reads").text

    private func filterLineText(_ viewer: ViewerViewController) -> String? {
        viewer.referenceBundleViewportController?.readFilterLine?.displayedText
    }

    private func embeddedSettled(_ viewer: ViewerViewController) -> Bool {
        viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewMemoryIsSettled ?? false
    }

    /// Selects `row` and waits until its reference shows, its block is wired and its view memory has restored.
    private func open(_ row: RoutingRowFixture, in harness: ViewSwitchWindowHarness) async throws -> URL {
        let viewer = harness.split.viewerController!
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel
        let before = viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewMemory
        harness.select(row.item)
        await harness.split.bundleOpenTask?.value
        let opened = await waitUntil(budget: .lookup) {
            guard let visit = viewer.referenceBundleViewportController?.testEmbeddedViewerController.viewMemory,
                  visit !== before, self.openedBundleURL(viewer) != nil else { return false }
            return visit.applied && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened, wired its read filter and restored its view")
        return try XCTUnwrap(openedBundleURL(viewer))
    }

    /// A confidence set on a reference comes back after a relaunch, from the store: the Inspector's block and the
    /// viewport agree, and the viewport says the filter hides reads (word 5a). Another bundle opens at the default.
    func testAConfidenceComesBackFromTheStoreAfterARelaunchOfTheSameBundle() async throws {
        let storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
        let rows = try await twoReferenceRows()
        do {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            let store = ViewMemoryStore(root: storeRoot)
            harness.keepViews(in: store)
            let viewer = harness.split.viewerController!
            let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel
            _ = try await open(rows.first, in: harness)
            readStyle.minMapQ = 30
            readStyle.onSettingsChanged?()
            XCTAssertEqual(viewportConfidence(viewer), 30, "the Inspector's confidence never reached the viewport")
            XCTAssertNil(filterLineText(viewer), "a filter set in this visit shows no line")
            _ = try await open(rows.second, in: harness)
            XCTAssertEqual(readStyle.minMapQ, 0, "another bundle opens at the default (W-27)")
            XCTAssertEqual(viewportConfidence(viewer), 0, "another bundle's reads are not filtered by the first's")
            store.flushSynchronously()
        }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: ViewMemoryStore(root: storeRoot))
        let viewer = harness.split.viewerController!
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel
        _ = try await open(rows.first, in: harness)
        XCTAssertEqual(viewportConfidence(viewer), 30, "the confidence comes back from the store after the relaunch")
        XCTAssertEqual(readStyle.minMapQ, 30, "the Inspector shows the filter the viewport shows")
        XCTAssertEqual(filterLineText(viewer), Self.word5a, "the viewport says the restored filter hides reads")
    }

    /// The URL carry through another kind and the store give the same filter, and the viewport says so (word 5a).
    func testAConfidenceCarriedThroughAnotherKindShowsItsLineInTheViewport() async throws {
        let rows = try await twoReferenceRows()
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Kraken2" })
        let otherRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("other", isDirectory: true))
        let other = try await XCTUnwrap(ViewSwitchKinds.row(of: kind)).build(
            RoutingRowContext(root: otherRoot, paths: SafetyNetPathRenderer(root: otherRoot)))
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: ViewMemoryStore(root: root.appendingPathComponent("view-memory", isDirectory: true)))
        let viewer = harness.split.viewerController!
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel
        _ = try await open(rows.first, in: harness)
        readStyle.minMapQ = 30
        readStyle.onSettingsChanged?()

        harness.select(other.item)
        await harness.split.bundleOpenTask?.value
        _ = try await open(rows.first, in: harness)
        XCTAssertEqual(viewportConfidence(viewer), 30, "the same bundle keeps its confidence")
        XCTAssertEqual(readStyle.minMapQ, 30, "the Inspector and the viewport agree")
        XCTAssertEqual(filterLineText(viewer), Self.word5a, "the viewport says the carried filter hides reads")
    }
}

/// The six consensus settings as one value, so a test reads and compares them as the block and the viewport hold them.
private struct ConsensusSix: Equatable {
    var masking: Bool
    var gapPercent: Int
    var minDepth: Int
    var maskingMinDepth: Int
    var mode: AlignmentConsensusMode
    var ambiguity: Bool

    /// Every field differs from its declared default, and every value lies inside the range the viewport clamps to.
    static let setOnFirstBundle = ConsensusSix(masking: true, gapPercent: 70, minDepth: 20, maskingMinDepth: 15, mode: .simple, ambiguity: true)
    static let setOnSecondBundle = ConsensusSix(masking: true, gapPercent: 60, minDepth: 30, maskingMinDepth: 12, mode: .simple, ambiguity: true)
}
