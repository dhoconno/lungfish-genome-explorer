import AppKit
import LungfishWorkflow
import LungfishKit
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
        selectedReadURLs: [URL] = [],
        sidebarInputSelection: WorkflowSidebarInputSelection? = nil
    ) {
        if shared == nil {
            shared = WorkflowOperationsWindowController(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs,
                sidebarInputSelection: sidebarInputSelection
            )
        } else {
            shared?.configure(
                projectURL: projectURL,
                routeContext: routeContext,
                selectedReadURLs: selectedReadURLs,
                sidebarInputSelection: sidebarInputSelection
            )
        }
        shared?.showWindow(nil)
    }

    private init(
        projectURL: URL?,
        routeContext: OperationRouteContext?,
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection?,
        service: WorkflowOperationExecutionService = WorkflowOperationExecutionService()
    ) {
        self.state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarInputSelection,
            projectDiscoveryMode: .asynchronous
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
            rootView: WorkflowOperationsDialog(
                state: state,
                onRun: { [weak self] request in
                    self?.run(request)
                },
                onCreateTwelveSReferenceBundle: { [weak self] configuration in
                    self?.createTwelveSReferenceBundle(configuration)
                }
            )
        )
        refreshAISpecialistPresetAvailability()
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
        selectedReadURLs: [URL],
        sidebarInputSelection: WorkflowSidebarInputSelection?
    ) {
        self.routeContext = routeContext
        state.configureProject(
            projectURL: projectURL,
            selectedReadURLs: selectedReadURLs,
            sidebarInputSelection: sidebarInputSelection
        )
        refreshAISpecialistPresetAvailability()
    }

    private func refreshAISpecialistPresetAvailability() {
        Task { @MainActor [weak self] in
            let available = await GenotypeAIHaplotypingExecutionService.hasConfiguredProvider()
            self?.state.setAISpecialistPresetsAvailable(available)
        }
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

    private func createTwelveSReferenceBundle(_ configuration: TwelveSReferenceBundleBuildConfiguration) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await service.runTwelveSReferenceBundleBuild(configuration, routeContext: routeContext)
                state.refreshProjectReferences(selecting: configuration.outputURL)
            } catch {
                state.errorMessage = error.localizedDescription
                state.showingError = true
            }
        }
    }
}
