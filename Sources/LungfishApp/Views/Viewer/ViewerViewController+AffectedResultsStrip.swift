// ViewerViewController+AffectedResultsStrip.swift - One strip above a result that an earlier build made wrong
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

/// The strip above a result whose record names a build that a row of ``AffectedResults`` holds. It carries the same
/// words as the Inspector's Warnings row and stays until the result is made again by an unaffected build.
@MainActor
final class AffectedResultsStripView: NSView {
    static let stripIdentifier = NSUserInterfaceItemIdentifier("affectedResultsStrip")

    let label: NSTextField
    /// The surface the strip sits above.
    weak var surfaceView: NSView?
    /// The top constraint the host gave the surface, put back when the strip goes.
    var replacedTopConstraint: NSLayoutConstraint?
    var placementConstraints: [NSLayoutConstraint] = []

    init(words: String) {
        label = NSTextField(wrappingLabelWithString: words)
        super.init(frame: .zero)
        identifier = Self.stripIdentifier
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Affected result")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = true
        label.setAccessibilityIdentifier("affected-results-strip-label")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
    }
}

/// Places and removes the strip in the viewer's container, above the surface the host installed.
@MainActor
enum AffectedResultsStrip {
    /// The strip in `container`, if one is placed.
    static func strip(in container: NSView) -> AffectedResultsStripView? {
        container.subviews.lazy.compactMap { $0 as? AffectedResultsStripView }.first
    }

    /// The words of the strip for `rows`. The first row's sentence and what to do read in full, and any further
    /// rows are counted and left to the Inspector's Provenance tab, the one tab with Warnings. Nil when no row matched.
    static func words(for rows: [AffectedResultRow]) -> String? {
        guard let first = rows.first else { return nil }
        guard rows.count > 1 else { return first.words }
        let others = rows.count - 1
        return first.words
            + " \(others) more \(others == 1 ? "note is" : "notes are") under Warnings on the Inspector's Provenance tab."
    }

    /// Shows `words` in a strip above `surfaceView`, or takes the strip away when `words` is nil or the surface is
    /// not in `container`. The host pins the surface's top to the container, and the strip takes that place so that
    /// the surface starts below it.
    ///
    /// The strip starts at the container's safe area. The main window draws its content under the title bar and
    /// toolbar (`.fullSizeContentView`), and a surface pinned to the container's top edge keeps its own content below
    /// them, but the strip has nothing that does. At that edge the bar covered every word and left a 1 to 2 pt line
    /// (walk finding AFFECTED-STRIP-NO-WORDS, build 13190).
    static func place(words: String?, above surfaceView: NSView?, in container: NSView) {
        remove(from: container)
        guard let words, !words.isEmpty, let surfaceView, surfaceView.superview === container else { return }
        let strip = AffectedResultsStripView(words: words)
        strip.surfaceView = surfaceView
        container.addSubview(strip, positioned: .above, relativeTo: surfaceView)
        let originalTop = container.constraints.first {
            $0.isActive && $0.firstItem === surfaceView && $0.firstAttribute == .top
        }
        originalTop?.isActive = false
        strip.replacedTopConstraint = originalTop
        strip.placementConstraints = [
            strip.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: strip.bottomAnchor),
        ]
        NSLayoutConstraint.activate(strip.placementConstraints)
    }

    /// Takes the strip away and gives the surface its own top constraint back, when the surface is still there.
    static func remove(from container: NSView) {
        guard let strip = strip(in: container) else { return }
        NSLayoutConstraint.deactivate(strip.placementConstraints)
        if let original = strip.replacedTopConstraint, strip.surfaceView?.superview === container {
            original.isActive = true
        }
        strip.removeFromSuperview()
    }
}

extension ViewerViewController {
    /// Listens for the Provenance model's notice, so that a result of an affected build shows its strip. It is the
    /// one call that places the strip, and `viewDidLoad` makes it once.
    func installAffectedResultsStrip() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(affectedResultsDidChange(_:)), name: .affectedResultsDidChange, object: nil
        )
    }

    /// Keeps the words for `rows` and shows them in a strip above the installed surface, or removes the strip and the
    /// words when none matched.
    func showAffectedResultsStrip(rows: [AffectedResultRow]) {
        affectedResultsWords = AffectedResultsStrip.words(for: rows)
        AffectedResultsStrip.place(words: affectedResultsWords, above: installedSurface?.viewController.view, in: view)
    }

    /// Keeps the strip with the surface the host shows, which the host calls after each install and clear. The
    /// Inspector's lookup can end before the viewer installs the result it is about, even before the display that
    /// clears the viewer first, so the viewer keeps the words and gives them to each surface the host installs. A
    /// viewer that shows no surface shows no strip. Only a notice changes the words, and the Inspector's clear at each
    /// selection sends an empty one, so the words never outlive their item.
    func affectedResultsStripFollowSurface(_ installed: (any ResultViewport)?) {
        AffectedResultsStrip.place(words: affectedResultsWords, above: installed?.viewController.view, in: view)
    }

    @objc private func affectedResultsDidChange(_ notification: Notification) {
        // The notice is a window event. A viewer that no split view controller owns, such as an embedded one, finds its
        // window's scope itself, and a viewer in no project window takes none of these notices.
        guard ProvenanceInspectorViewModel.viewerTakes(notification, inWindowWith: windowEventScope) else { return }
        // Only the Inspector of this window speaks for this viewer.
        if let split = parent as? MainSplitViewController,
           let model = split.inspectorController?.provenanceSectionViewModel,
           (notification.object as AnyObject?) !== model {
            return
        }
        let rows = notification.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow] ?? []
        showAffectedResultsStrip(rows: rows)
    }
}
