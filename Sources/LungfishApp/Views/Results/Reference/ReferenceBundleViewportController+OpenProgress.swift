// ReferenceBundleViewportController+OpenProgress.swift - What each pane shows while a large reference opens
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The panes' progress while a reference or mapping opens (UX ruling Q-S1).
///
/// The open decodes its files off the main actor, so the viewport shows at
/// once and each waiting pane names its work. The list or table holds a small
/// spinner and "Loading sequences…", the summary bar keeps its title and adds
/// a trailing status item, and the embedded viewer reads "Loading reference
/// viewer…" until it opens. VoiceOver hears one announcement, when the list
/// or table first becomes usable.
@MainActor
final class ReferenceViewportOpenProgress {
    static let loadingSequences = "Loading sequences\u{2026}"
    static let loadingViewer = "Loading reference viewer\u{2026}"

    let statusSpinner = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let listSpinner = NSProgressIndicator()
    let listLabel = NSTextField(labelWithString: loadingSequences)
    lazy var statusItem = NSStackView(views: [statusSpinner, statusLabel])
    lazy var listPlaceholder = NSStackView(views: [listSpinner, listLabel])

    /// The viewport shows the loading state and has no input yet.
    var isAwaitingInput = false
    /// The bundle or mapping result folder the loading state stands for.
    var documentURL: URL?
    /// The viewport opened through the loading state, so it announces its
    /// rows once and its first viewer open waits a turn for the list to paint.
    var isProgressive = false
    var defersViewerOpen = false
    var pendingViewerOpen: (() -> Void)?
    var hasAnnouncedReady = false
    /// Posts a VoiceOver announcement. Tests replace it to read the posts.
    var announce: (String) -> Void = { message in
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    static func readyAnnouncement(isMappingTable: Bool, count: Int) -> String {
        let sequences = count == 1 ? "1 sequence" : "\(count.formatted()) sequences"
        return "\(isMappingTable ? "Mapping table" : "Sequence list") ready, \(sequences)"
    }
}

extension ReferenceBundleViewportController {
    var isAwaitingOpenInput: Bool { openProgress.isAwaitingInput }

    /// Whether this viewport is the loading state of the open of `url`.
    func isAwaitingOpen(of url: URL) -> Bool {
        openProgress.isAwaitingInput && openProgress.documentURL == url.standardizedFileURL
    }

    /// Shows the viewport before its rows are read: the list and the status
    /// item read "Loading sequences…" and the summary bar keeps the title.
    func showOpenLoading(title: String, documentURL: URL) {
        _ = view
        let progress = openProgress
        installOpenProgressViewsIfNeeded()
        progress.documentURL = documentURL.standardizedFileURL
        progress.isAwaitingInput = true
        progress.isProgressive = true
        progress.defersViewerOpen = true
        summaryLabel.stringValue = title
        contigTableView.isHidden = true
        sequenceTableView.isHidden = true
        progress.listPlaceholder.isHidden = false
        progress.listSpinner.startAnimation(nil)
        setOpenStatus(ReferenceViewportOpenProgress.loadingSequences)
        showDetailPlaceholder("Select a sequence to inspect.")
    }

    /// The input's rows are configured: the list placeholder goes, and the
    /// status item names the viewer while its open is pending.
    func finishOpenLoading() {
        let progress = openProgress
        guard progress.isAwaitingInput else { return }
        progress.isAwaitingInput = false
        progress.listSpinner.stopAnimation(nil)
        progress.listPlaceholder.isHidden = true
        setOpenStatus(progress.pendingViewerOpen == nil ? nil : ReferenceViewportOpenProgress.loadingViewer)
        announceReadyIfUsable()
    }

    /// Posts "Sequence list ready, N sequences" or "Mapping table ready, N
    /// sequences" the first time the list or table of a progressive open
    /// holds rows. Later row changes announce nothing.
    func announceReadyIfUsable() {
        let progress = openProgress
        guard progress.isProgressive, !progress.isAwaitingInput, !progress.hasAnnouncedReady else { return }
        let isMappingTable = currentInput?.kind == .mappingResult
        let count = isMappingTable ? contigTableView.displayedRows.count : sequenceTableView.displayedRows.count
        guard count > 0 else { return }
        progress.hasAnnouncedReady = true
        progress.announce(ReferenceViewportOpenProgress.readyAnnouncement(isMappingTable: isMappingTable, count: count))
    }

    /// Holds the first viewer open of a progressive open for one main-actor
    /// turn so the list paints first, and reports whether it took `open`. A
    /// selection made meanwhile opens the viewer at once on that row and
    /// drops the held open.
    func deferFirstViewerOpen(_ open: @escaping () -> Void) -> Bool {
        let progress = openProgress
        guard progress.defersViewerOpen, loadedViewerBundleURL == nil else { return false }
        progress.defersViewerOpen = false
        if progress.pendingViewerOpen != nil {
            progress.pendingViewerOpen = nil
            if !progress.isAwaitingInput {
                setOpenStatus(nil)
            }
            return false
        }
        progress.defersViewerOpen = true
        progress.pendingViewerOpen = open
        showDetailPlaceholder(ReferenceViewportOpenProgress.loadingViewer)
        if !progress.isAwaitingInput {
            setOpenStatus(ReferenceViewportOpenProgress.loadingViewer)
        }
        Task { @MainActor [weak self] in
            self?.runPendingViewerOpen()
        }
        return true
    }

    private func runPendingViewerOpen() {
        let progress = openProgress
        guard let open = progress.pendingViewerOpen else { return }
        progress.pendingViewerOpen = nil
        progress.defersViewerOpen = false
        open()
        if !progress.isAwaitingInput {
            setOpenStatus(nil)
        }
    }

    /// The summary bar's trailing status item. Its spinner is hidden from
    /// VoiceOver, and its label's accessibility label reads the same text.
    private func setOpenStatus(_ text: String?) {
        let progress = openProgress
        guard progress.statusItem.superview != nil else { return }
        progress.statusLabel.stringValue = text ?? ""
        progress.statusLabel.setAccessibilityLabel(text)
        progress.statusItem.isHidden = text == nil
        if text == nil {
            progress.statusSpinner.stopAnimation(nil)
        } else {
            progress.statusSpinner.startAnimation(nil)
        }
    }

    private func installOpenProgressViewsIfNeeded() {
        let progress = openProgress
        guard progress.statusItem.superview == nil else { return }
        for spinner in [progress.statusSpinner, progress.listSpinner] {
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.setAccessibilityElement(false)
        }
        progress.statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progress.statusLabel.textColor = .secondaryLabelColor
        progress.statusLabel.setAccessibilityIdentifier("reference-viewport-open-status-label")
        progress.statusItem.spacing = 6
        progress.statusItem.translatesAutoresizingMaskIntoConstraints = false
        progress.statusItem.setAccessibilityIdentifier("reference-viewport-open-status")
        progress.listLabel.textColor = .secondaryLabelColor
        progress.listLabel.setAccessibilityLabel(ReferenceViewportOpenProgress.loadingSequences)
        progress.listLabel.setAccessibilityIdentifier("reference-viewport-list-loading-label")
        progress.listPlaceholder.orientation = .vertical
        progress.listPlaceholder.spacing = 8
        progress.listPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        progress.listPlaceholder.setAccessibilityIdentifier("reference-viewport-list-loading")
        summaryBar.addSubview(progress.statusItem)
        listContainer.addSubview(progress.listPlaceholder)
        NSLayoutConstraint.activate([
            progress.statusItem.trailingAnchor.constraint(equalTo: focusButton.leadingAnchor, constant: -12),
            progress.statusItem.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.statusItem.leadingAnchor, constant: -12),
            progress.listPlaceholder.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            progress.listPlaceholder.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
        ])
    }
}
