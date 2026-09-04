import AppKit
import SwiftUI

@MainActor
struct FASTQOperationsDialogPresenter {
    static func present(
        from window: NSWindow,
        selectedInputURLs: [URL],
        initialCategory: FASTQOperationCategoryID,
        initialToolID: FASTQOperationToolID? = nil,
        projectURL: URL? = nil,
        availableToolIDs: [FASTQOperationToolID]? = nil,
        primaryActionTitle: String = "Run",
        mafftAllSequenceCount: Int = 0,
        mafftSelectedSequenceNames: [String] = [],
        onRun: ((FASTQOperationDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let state = FASTQOperationDialogState(
            initialCategory: initialCategory,
            selectedInputURLs: selectedInputURLs,
            projectURL: projectURL,
            availableToolIDs: availableToolIDs
        )
        if let initialToolID {
            state.selectTool(initialToolID)
        }
        state.mafftAllSequenceCount = mafftAllSequenceCount
        state.mafftSelectedSequenceNames = mafftSelectedSequenceNames
        // Default to the selection when the caller supplied one, since the
        // user reached the dialog by selecting those sequences.
        state.mafftSequenceScope = mafftSelectedSequenceNames.isEmpty ? .all : .selected

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = initialCategory.title
        panel.isReleasedWhenClosed = false

        let dialog = FASTQOperationDialog(
            state: state,
            primaryActionTitle: primaryActionTitle,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                window.endSheet(panel)
                onRun?(state)
            }
        )

        let hostingController = NSHostingController(rootView: dialog)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 980, height: 700))
        window.beginSheet(panel)
    }
}
