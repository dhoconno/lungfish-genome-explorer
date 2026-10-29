// ViewSwitchWindowHarness.swift - A main window on screen for the view-switch tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The routing table selects each row on a split controller with no window,
// so it sees no window frame and no toolbar. The view-switch tests open a real
// MainWindowController window inside the main screen's visible frame instead,
// select each kind's sidebar row through the same `displayContent(for:)` call
// the sidebar's debounced selection makes, and read the routing observation,
// the toolbar and the window frame after each switch.
//
// The window keeps no frame and no toolbar layout in the test runner's
// defaults. A file the viewer previews is recorded rather than drawn, as in
// the routing table, and no project is open, so a route that would ask for a
// name stops where the routing table row says it does.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

@MainActor
final class ViewSwitchWindowHarness {
    let controller: MainWindowController
    let window: NSWindow
    let split: MainSplitViewController
    let recorder = LoadedDocumentRecorder()

    init() throws {
        controller = MainWindowController()
        window = try XCTUnwrap(controller.window)
        // MainWindowController names a frame autosave and a toolbar that saves
        // its layout. A test leaves nothing in the runner's defaults.
        window.setFrameAutosaveName("")
        window.toolbar?.autosavesConfiguration = false
        window.isReleasedWhenClosed = false
        split = try XCTUnwrap(controller.mainSplitViewController)
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first, "the view-switch tests need a screen")
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 40))
        window.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        window.orderFront(nil)
        RecordingFilePreviewRenderer.install(on: split.viewerController)
        let recorder = recorder
        let loader = split.externalDocumentLoader
        split.externalDocumentLoader = { url in
            recorder.urls.append(url)
            return try await loader(url)
        }
    }

    /// Selects a sidebar row the way the sidebar does once its debounce ends.
    func select(_ item: SidebarItem) {
        split.displayContent(for: item)
    }

    /// The settled reading of the window, with the paths of `kindRoot` written
    /// relative to it and the paths of other kinds as `../<folder>/...`.
    func read(kindRoot: URL, matrixRoot: URL) -> ViewSwitchReading {
        let paths = SafetyNetPathRenderer(root: kindRoot, fallback: matrixRoot)
        var observation = RoutingObserver.observe(split, paths: paths, loaded: [])
        observation.loaded = []
        return ViewSwitchReading(observation: observation, frame: frameReading)
    }

    /// Whether the window lies inside the visible frame of its screen.
    var frameReading: String {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = window.frame
        if visible.contains(frame) { return "inside the screen" }
        return "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)) "
            + "outside the visible \(Int(visible.width))x\(Int(visible.height)) at \(Int(visible.minX)),\(Int(visible.minY))"
    }

    /// Ends every load the window started and closes it.
    func close() {
        split.invalidateDisplayRequest()
        split.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "view-switch window closed")
        split.viewerController.clearViewport()
        split.inspectorController.clearSelection()
        controller.close()
    }
}

/// What a person sees after a switch, as lines that compare one by one.
struct ViewSwitchReading: Equatable {
    var observation: RoutingObservation
    var frame: String

    var lines: [String] {
        observation.fullDescription.components(separatedBy: "\n") + ["frame: \(frame)"]
    }

    /// The lines a kind shows when it is selected alone: its routing row's
    /// outcome with no loader list, the Provenance target the kind records
    /// only in a window, the toolbar its mode shows and a frame inside the
    /// screen.
    static func alone(_ expected: RoutingObservation, kind: ViewSwitchKind) -> ViewSwitchReading {
        var observation = expected
        observation.loaded = []
        if let provenance = kind.windowProvenance { observation.provenance = provenance }
        observation.toolbar = ViewSwitchToolbar.items(for: expected.mode)
        return ViewSwitchReading(observation: observation, frame: "inside the screen")
    }

    /// The lines that differ from `expected`, "+ line" for a line only this
    /// reading has and "- line" for one only `expected` has, in reading order.
    func faults(against expected: ViewSwitchReading) -> [String] {
        var missing = expected.lines
        var added: [String] = []
        for line in lines {
            if let index = missing.firstIndex(of: line) {
                missing.remove(at: index)
            } else {
                added.append("+ \(line)")
            }
        }
        return added + missing.map { "- \($0)" }
    }
}

/// The window toolbar items each content mode shows, as the window
/// controller sets them when the viewer posts its mode
/// (`MainWindowController.swift:269-300`).
enum ViewSwitchToolbar {
    static let sidebar = "ToggleSidebar"
    static let chromosomes = "ToggleChromosomeDrawer"
    static let translate = "TranslateTool"
    static let operations = "Operations"
    static let drawer = "ToggleAnnotationDrawer"
    static let inspector = "ToggleInspector"

    static func items(for mode: ViewportContentMode) -> [String] {
        switch mode {
        case .genomics: return [sidebar, chromosomes, translate, operations, drawer, inspector]
        case .empty: return [sidebar, chromosomes, translate, operations, inspector]
        case .mapping: return [sidebar, translate, operations, inspector]
        case .fastq, .metagenomics: return [sidebar, operations, drawer, inspector]
        case .assembly, .genotype: return [sidebar, operations, inspector]
        }
    }
}
