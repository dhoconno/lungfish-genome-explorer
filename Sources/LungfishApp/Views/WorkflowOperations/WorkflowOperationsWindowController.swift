import AppKit
import SwiftUI

@MainActor
final class WorkflowOperationsWindowController: NSWindowController {
    private static var shared: WorkflowOperationsWindowController?

    private let state: WorkflowOperationDialogState
    private var routeContext: OperationRouteContext?
    private let service: WorkflowOperationExecutionService

    static func show(
        projectURL: URL?,
        routeContext: OperationRouteContext? = nil,
        selectedReadURLs: [URL] = []
    ) {
        if shared == nil {
            shared = WorkflowOperationsWindowController(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs
            )
        } else {
            shared?.configure(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs
            )
        }
        shared?.showWindow(nil)
    }

    private init(
        projectURL: URL?,
        routeContext: OperationRouteContext?,
        selectedReadURLs: [URL],
        service: WorkflowOperationExecutionService = WorkflowOperationExecutionService()
    ) {
        self.state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs
        )
        self.routeContext = routeContext
        self.service = service

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workflow Operations"
        window.minSize = NSSize(width: 720, height: 460)
        window.setFrameAutosaveName("WorkflowOperationsWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(WorkflowOperationsAccessibilityID.window)

        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: WorkflowOperationsDialog(state: state) { [weak self] request in
                self?.run(request)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configure(
        projectURL: URL?,
        routeContext: OperationRouteContext?,
        selectedReadURLs: [URL]
    ) {
        self.routeContext = routeContext
        state.configureProject(projectURL: projectURL, selectedReadURLs: selectedReadURLs)
    }

    private func run(_ request: WorkflowOperationLaunchRequest) {
        window?.close()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await service.run(request, routeContext: routeContext)
            } catch {
                showWindow(nil)
                state.errorMessage = error.localizedDescription
                state.showingError = true
            }
        }
    }
}
