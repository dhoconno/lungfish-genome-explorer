// ReadSelectionActionMenuBuilder.swift - Context menu for selected aligned reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09): the main mapping viewport's
// read-track right-click menu. Selection-count-aware, mirroring the pattern
// established by `FASTASequenceActionMenuBuilder` (this file intentionally
// keeps its own small `ActionTarget` rather than sharing one, since the two
// builders serve different item sets and call sites).

import AppKit
import ObjectiveC

/// Handlers backing the read-selection context menu's two actions.
@MainActor
public struct ReadSelectionActionHandlers {
    /// Copies the selected reads as FASTA (aligned orientation, in-memory).
    public var onCopyAsFASTA: (() -> Void)?

    /// Extracts the selected reads' original (unaligned) records via
    /// `ReadExtractionService`.
    public var onExtractReads: (() -> Void)?

    public init(
        onCopyAsFASTA: (() -> Void)? = nil,
        onExtractReads: (() -> Void)? = nil
    ) {
        self.onCopyAsFASTA = onCopyAsFASTA
        self.onExtractReads = onExtractReads
    }
}

/// Builds the read-track right-click context menu shown when one or more
/// aligned reads are selected in the main mapping viewport.
@MainActor
public enum ReadSelectionActionMenuBuilder {
    private static let actionAssociationKey = UnsafeRawPointer(bitPattern: 0x2EAD5E1)!

    private final class ActionTarget: NSObject {
        let handler: () -> Void

        init(handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func performAction(_ sender: Any?) {
            handler()
        }
    }

    /// Builds the read-selection menu. Both items are disabled at zero
    /// selection; callers should not present this menu at all when nothing
    /// is selected, but the enablement is defensive regardless.
    public static func buildMenu(
        selectionCount: Int,
        handlers: ReadSelectionActionHandlers
    ) -> NSMenu {
        let menu = NSMenu(title: "Read Selection")
        buildItems(selectionCount: selectionCount, handlers: handlers).forEach(menu.addItem(_:))
        return menu
    }

    public static func buildItems(
        selectionCount: Int,
        handlers: ReadSelectionActionHandlers
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let isEnabled = selectionCount > 0

        addItem(
            titled: "Copy as FASTA (aligned orientation)",
            handler: handlers.onCopyAsFASTA,
            enabled: isEnabled,
            toolTip: "Copies the selected read(s) exactly as aligned (soft clips included, in aligned orientation), directly from the SAM record.",
            to: &items
        )
        addItem(
            titled: "Extract Reads… (original reads)",
            handler: handlers.onExtractReads,
            enabled: isEnabled,
            toolTip: "Extracts the selected read(s) as originally sequenced from the source FASTQ (or the BAM when the source is unavailable).",
            to: &items
        )

        return items
    }

    private static func addItem(
        titled title: String,
        handler: (() -> Void)?,
        enabled: Bool,
        toolTip: String? = nil,
        to items: inout [NSMenuItem]
    ) {
        guard let handler else { return }

        let target = ActionTarget(handler: handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(ActionTarget.performAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = enabled
        item.toolTip = toolTip
        objc_setAssociatedObject(
            item,
            actionAssociationKey,
            target,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        items.append(item)
    }
}
