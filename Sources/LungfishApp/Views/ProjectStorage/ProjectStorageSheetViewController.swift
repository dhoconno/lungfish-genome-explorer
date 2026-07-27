import AppKit
import LungfishWorkflow

@MainActor
final class ProjectStorageSheetViewController: NSViewController {
    private final class OutlineNode: NSObject {
        enum Value {
            case section(ProjectStorageSheetViewModel.CategorySection)
            case entry(
                ProjectStorageEntry,
                ProjectStorageSheetViewModel.CategorySection
            )
        }

        let value: Value
        var children: [OutlineNode] = []

        init(_ value: Value) {
            self.value = value
        }
    }

    private final class EntryCheckbox: NSButton {
        var entryID: UUID?
    }

    private final class SectionCheckbox: NSButton {
        var sectionKind:
            ProjectStorageSheetViewModel.CategorySection.Kind?
    }

    private final class KeyboardRootView: NSView {
        var returnHandler: (() -> Bool)?
        var escapeHandler: (() -> Bool)?
        var spaceHandler: (() -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76:
                if returnHandler?() == true { return }
            case 53:
                if escapeHandler?() == true { return }
            case 49:
                if spaceHandler?() == true { return }
            default:
                break
            }
            super.keyDown(with: event)
        }
    }

    private let viewModel: ProjectStorageSheetViewModel
    private let progressAnnouncementThrottleInterval: TimeInterval
    private let progressAnnouncementNow: @MainActor () -> TimeInterval
    private let progressAnnouncementHandler: @MainActor (String) -> Void
    private let outlineView = NSOutlineView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cleanupButton = NSButton(
        title: "",
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(
        title: "Cancel",
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(
        title: "Retry Failed",
        target: nil,
        action: nil
    )
    private let retryScanButton = NSButton(
        title: "Retry Scan",
        target: nil,
        action: nil
    )
    private let revealReceiptButton = NSButton(
        title: "Reveal Receipt",
        target: nil,
        action: nil
    )
    private let revealTrashButton = NSButton(
        title: "Reveal in Trash",
        target: nil,
        action: nil
    )
    private var roots: [OutlineNode] = []
    private var lastAnnouncedProgress: String?
    private var lastProgressAnnouncementTime: TimeInterval?
    private var lastObservedState: ProjectStorageSheetViewModel.State?

    init(
        viewModel: ProjectStorageSheetViewModel,
        progressAnnouncementThrottleInterval: TimeInterval = 1,
        progressAnnouncementNow:
            @escaping @MainActor () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            },
        progressAnnouncementHandler:
            @escaping @MainActor (String) -> Void = {
                ProjectStorageSheetViewController.announceProgress($0)
            }
    ) {
        self.viewModel = viewModel
        self.progressAnnouncementThrottleInterval = max(
            0,
            progressAnnouncementThrottleInterval
        )
        self.progressAnnouncementNow = progressAnnouncementNow
        self.progressAnnouncementHandler = progressAnnouncementHandler
        super.init(nibName: nil, bundle: nil)
        self.viewModel.onChange = { [weak self] in
            self?.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = KeyboardRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier(ProjectStorageAccessibilityID.root)
        root.returnHandler = { [weak self] in
            self?.viewModel.handleReturnKey() ?? true
        }
        root.escapeHandler = { [weak self] in
            self?.viewModel.handleEscapeKey() ?? true
        }
        root.spaceHandler = { [weak self] in
            self?.toggleSelectedOutlineRow() ?? false
        }
        view = root

        let titleLabel = NSTextField(
            labelWithString: viewModel.sheetTitle
        )
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.title
        )

        summaryLabel.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.summary
        )
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.status
        )

        configureOutline()
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.progress
        )
        progressIndicator.setAccessibilityLabel(
            "Project storage operation progress"
        )

        cleanupButton.bezelStyle = .rounded
        cleanupButton.target = self
        cleanupButton.action = #selector(cleanupPressed(_:))
        cleanupButton.keyEquivalent = ""
        cleanupButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.cleanupButton
        )
        cleanupButton.setAccessibilityLabel(
            "Move selected project storage entries to Trash"
        )
        cleanupButton.setAccessibilityHelp(
            "Moves only individually proven removable entries. "
                + "Empty the Trash to reclaim disk space."
        )

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.cancelButton
        )
        cancelButton.setAccessibilityLabel("Cancel project storage review")
        cancelButton.setAccessibilityHelp(
            "Cancels scanning, or stops cleanup after the current item."
        )

        retryButton.target = self
        retryButton.action = #selector(retryPressed(_:))
        retryButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.retryFailedButton
        )
        retryButton.setAccessibilityLabel(
            "Retry failed project storage entries"
        )

        retryScanButton.target = self
        retryScanButton.action = #selector(retryScanPressed(_:))
        retryScanButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.retryScanButton
        )
        retryScanButton.setAccessibilityLabel("Scan project storage again")

        revealReceiptButton.target = self
        revealReceiptButton.action = #selector(revealReceiptPressed(_:))
        revealReceiptButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.revealReceiptButton
        )
        revealReceiptButton.setAccessibilityLabel(
            "Reveal durable cleanup receipt"
        )

        revealTrashButton.target = self
        revealTrashButton.action = #selector(revealTrashPressed(_:))
        revealTrashButton.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.revealTrashButton
        )
        revealTrashButton.setAccessibilityLabel(
            "Reveal a successfully moved item in Trash"
        )

        let resultActions = NSStackView(
            views: [
                retryScanButton,
                retryButton,
                revealReceiptButton,
                revealTrashButton,
            ]
        )
        resultActions.orientation = .horizontal
        resultActions.spacing = 8

        let progressRow = NSStackView(
            views: [progressIndicator, statusLabel]
        )
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.alignment = .centerY

        let primaryActions = NSStackView(
            views: [cancelButton, cleanupButton]
        )
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 8

        let footer = NSStackView(views: [resultActions, primaryActions])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 12
        resultActions.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryActions.setContentHuggingPriority(
            .required,
            for: .horizontal
        )

        let content = NSStackView(
            views: [
                titleLabel,
                summaryLabel,
                scrollView,
                progressRow,
                footer,
            ]
        )
        content.orientation = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 900),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
            content.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: 20
            ),
            content.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -20
            ),
            content.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: 20
            ),
            content.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -20
            ),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.defaultButtonCell = nil
        view.window?.makeFirstResponder(outlineView)
    }

    private func configureOutline() {
        let columns: [(String, String, CGFloat)] = [
            ("item", "Item", 245),
            ("analysis", "Analysis", 120),
            ("modified", "Modified", 145),
            ("allocated", "Estimated on Disk", 125),
            ("logical", "Logical Size", 105),
            ("status", "Status", 230),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier)
            )
            column.title = title
            column.width = width
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .medium
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier(
            ProjectStorageAccessibilityID.outline
        )
        outlineView.setAccessibilityLabel(
            "Project storage categories and entries"
        )
        outlineView.setAccessibilityHelp(
            "Expand categories to review logical size, estimated allocated "
                + "size on disk, safety status, and not-removable reasons. "
                + "Press Space to change an eligible checkbox."
        )
    }

    private func rebuildNodes() {
        roots = viewModel.categorySections.map { section in
            let root = OutlineNode(.section(section))
            root.children = section.entries.map {
                OutlineNode(.entry($0, section))
            }
            return root
        }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        rebuildNodes()
        outlineView.reloadData()
        let hasRemovable = viewModel.categorySections
            .filter(\.isCheckable)
            .contains { !$0.entries.isEmpty }
        for root in roots {
            guard case .section(let section) = root.value else { continue }
            if section.isCheckable || !hasRemovable {
                outlineView.expandItem(root)
            } else {
                outlineView.collapseItem(root)
            }
        }

        summaryLabel.stringValue = viewModel.estimatedTotalDescription
        statusLabel.stringValue = [
            viewModel.statusMessage,
            viewModel.cleanupDisabledReason,
        ].compactMap { $0 }.joined(separator: " ")
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        let previousState = lastObservedState
        lastObservedState = viewModel.state
        let isScanProgressState =
            viewModel.state == .scanning
            || viewModel.state == .revalidating
        if isScanProgressState,
           viewModel.scanProgress != nil {
            let now = progressAnnouncementNow()
            let intervalElapsed = lastProgressAnnouncementTime.map {
                now - $0 >= progressAnnouncementThrottleInterval
            } ?? true
            if intervalElapsed,
               lastAnnouncedProgress != statusLabel.stringValue {
                lastProgressAnnouncementTime = now
                lastAnnouncedProgress = statusLabel.stringValue
                progressAnnouncementHandler(statusLabel.stringValue)
            }
        } else if !isScanProgressState {
            let reachedTerminalState: Bool
            switch viewModel.state {
            case .ready, .cancelled, .failed, .finished, .stale:
                reachedTerminalState = true
            case .idle, .scanning, .revalidating, .cleaning:
                reachedTerminalState = false
            }
            if reachedTerminalState,
               previousState == .scanning
                || previousState == .revalidating
                || previousState == .cleaning {
                progressAnnouncementHandler(statusLabel.stringValue)
            }
            lastAnnouncedProgress = nil
            lastProgressAnnouncementTime = nil
        }
        cleanupButton.title = viewModel.cleanupButtonTitle
        cleanupButton.isEnabled = viewModel.canCleanup

        let busy =
            viewModel.state == .scanning
            || viewModel.state == .revalidating
            || viewModel.state == .cleaning
        if busy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        progressIndicator.isHidden = !busy

        retryScanButton.isHidden = !viewModel.canRetryScan
        retryButton.isHidden = !viewModel.canRetryFailed
        revealReceiptButton.isHidden = !viewModel.canRevealReceipt
        revealTrashButton.isHidden = viewModel.trashDestinationURLs.isEmpty
        updateRevealTrashAvailability()

        if viewModel.state == .finished {
            cancelButton.title = "Done"
            cancelButton.keyEquivalent = "\r"
            cancelButton.setAccessibilityLabel(
                "Close project storage review"
            )
            view.window?.defaultButtonCell = cancelButton.cell as? NSButtonCell
        } else {
            let isStoppableOperation =
                viewModel.state == .cleaning
                || viewModel.state == .revalidating
            cancelButton.title = isStoppableOperation ? "Stop" : "Cancel"
            cancelButton.setAccessibilityLabel(
                isStoppableOperation
                    ? "Stop project storage operation"
                    : "Cancel project storage review"
            )
            cancelButton.keyEquivalent = "\u{1b}"
            view.window?.defaultButtonCell = nil
        }
        cancelButton.isEnabled =
            viewModel.statusMessage != "Stopping after the current item…"
            && viewModel.statusMessage != "Stopping scan…"
            && viewModel.statusMessage != "Stopping revalidation…"
    }

    private func toggleSelectedOutlineRow() -> Bool {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? OutlineNode else {
            return false
        }
        switch node.value {
        case .section(let section):
            guard section.isCheckable else { return false }
            viewModel.toggleSelection(for: section)
        case .entry(let entry, let section):
            guard section.isCheckable else { return false }
            viewModel.toggleSelection(for: entry.id)
        }
        return true
    }

    @objc private func cleanupPressed(_ sender: Any?) {
        viewModel.beginCleanup()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        _ = viewModel.handleEscapeKey()
    }

    @objc private func retryPressed(_ sender: Any?) {
        viewModel.retryFailed()
    }

    @objc private func retryScanPressed(_ sender: Any?) {
        viewModel.retryScan()
    }

    @objc private func revealReceiptPressed(_ sender: Any?) {
        viewModel.revealReceipt()
    }

    @objc private func revealTrashPressed(_ sender: Any?) {
        guard let entryID = selectedTrashEntryID else { return }
        viewModel.revealTrashDestination(for: entryID)
    }

    private var selectedTrashEntryID: UUID? {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? OutlineNode,
              case .entry(let entry, _) = node.value,
              viewModel.trashDestinationURLs[entry.id] != nil else {
            return nil
        }
        return entry.id
    }

    private func updateRevealTrashAvailability() {
        revealTrashButton.isEnabled = selectedTrashEntryID != nil
    }

    private static func announceProgress(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

extension ProjectStorageSheetViewController: NSOutlineViewDataSource {
    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? OutlineNode)?.children.count ?? roots.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? OutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        isItemExpandable item: Any
    ) -> Bool {
        !((item as? OutlineNode)?.children.isEmpty ?? true)
    }
}

extension ProjectStorageSheetViewController: NSOutlineViewDelegate {
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateRevealTrashAvailability()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? OutlineNode,
              let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }
        switch node.value {
        case .section(let section):
            guard identifier == "item" else { return nil }
            if section.isCheckable {
                let button = SectionCheckbox(
                    checkboxWithTitle: section.title,
                    target: self,
                    action: #selector(sectionCheckboxChanged(_:))
                )
                button.sectionKind = section.kind
                let selected = Set(section.entries.map(\.id))
                if selected.isEmpty {
                    button.state = .off
                    button.isEnabled = false
                } else if selected.isSubset(of: viewModel.selectedEntryIDs) {
                    button.state = .on
                } else if selected.isDisjoint(
                    with: viewModel.selectedEntryIDs
                ) {
                    button.state = .off
                } else {
                    button.allowsMixedState = true
                    button.state = .mixed
                }
                button.setAccessibilityIdentifier(
                    ProjectStorageAccessibilityID.categoryCheckboxPrefix
                        + section.kind.rawValue
                )
                button.setAccessibilityLabel(
                    viewModel.categoryAccessibilityLabel(for: section)
                )
                button.setAccessibilityHelp(
                    "Select or clear every individually removable entry in "
                        + "this category."
                )
                return button
            }
            let categoryLabel = label(section.title, weight: .semibold)
            categoryLabel.setAccessibilityIdentifier(
                ProjectStorageAccessibilityID.categoryCheckboxPrefix
                    + section.kind.rawValue
            )
            categoryLabel.setAccessibilityLabel(
                viewModel.categoryAccessibilityLabel(for: section)
            )
            categoryLabel.setAccessibilityHelp(
                "Entries in this category are not removable; expand the "
                    + "category to review individual safety reasons."
            )
            return categoryLabel

        case .entry(let entry, let section):
            switch identifier {
            case "item":
                if section.isCheckable {
                    let title = URL(
                        fileURLWithPath: entry.relativePath
                    ).lastPathComponent
                    let button = EntryCheckbox(
                        checkboxWithTitle: title,
                        target: self,
                        action: #selector(entryCheckboxChanged(_:))
                    )
                    button.entryID = entry.id
                    button.state = viewModel.selectedEntryIDs.contains(entry.id)
                        ? .on
                        : .off
                    button.setAccessibilityIdentifier(
                        ProjectStorageAccessibilityID.entryCheckboxPrefix
                            + entry.id.uuidString.lowercased()
                    )
                    let checked = button.state == .on
                        ? "checked"
                        : "not checked"
                    let status = viewModel.cleanupStatusText(for: entry)
                    button.setAccessibilityLabel(
                        "\(title), "
                            + "\(viewModel.allocatedSizeText(for: entry)) "
                            + "estimated on disk, \(checked), "
                            + "status: \(status), "
                            + "reason: \(entry.classification.reason)"
                    )
                    button.setAccessibilityHelp(
                        entry.classification.reason
                    )
                    return button
                }
                let title = URL(
                    fileURLWithPath: entry.relativePath
                ).lastPathComponent
                let itemLabel = label(title)
                itemLabel.setAccessibilityLabel(
                    "\(title), "
                        + "\(viewModel.allocatedSizeText(for: entry)) "
                        + "estimated on disk, not checkable, "
                        + "status: \(viewModel.cleanupStatusText(for: entry)), "
                        + "reason: \(entry.classification.reason)"
                )
                itemLabel.setAccessibilityHelp(entry.classification.reason)
                return itemLabel
            case "analysis":
                return label(viewModel.analysisText(for: entry))
            case "modified":
                return label(viewModel.modifiedDateText(for: entry))
            case "allocated":
                return label(viewModel.allocatedSizeText(for: entry))
            case "logical":
                return label(viewModel.logicalSizeText(for: entry))
            case "status":
                return label(viewModel.cleanupStatusText(for: entry))
            default:
                return nil
            }
        }
    }

    private func label(
        _ value: String,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    @objc private func entryCheckboxChanged(_ sender: EntryCheckbox) {
        guard let entryID = sender.entryID else { return }
        viewModel.toggleSelection(for: entryID)
    }

    @objc private func sectionCheckboxChanged(_ sender: SectionCheckbox) {
        guard let kind = sender.sectionKind,
              let section = viewModel.categorySections.first(where: {
                  $0.kind == kind
              }) else {
            return
        }
        viewModel.toggleSelection(for: section)
    }
}
