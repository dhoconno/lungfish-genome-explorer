// ViewportHost.swift - The one slot that installs a result surface into a viewer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// What one ``ViewportHost`` request shows. The host's gate issues a token for each.
public struct SurfaceRequest: Hashable, Sendable {
    /// The kind the request shows.
    public let kind: SurfaceKind

    public init(kind: SurfaceKind) {
        self.kind = kind
    }
}

/// How one ``ViewportHost/show(kind:input:)`` ended.
public enum SurfaceShowOutcome: Sendable {
    /// The surface loaded while its token was current and is now the one child.
    case committed
    /// A newer show or a clear took the slot before the load ended, so the host
    /// dropped the surface without installing it.
    case refused
    /// The registry or the load threw while the token was current. Nothing is
    /// installed, and the caller shows the error's words where the viewer was.
    case failed(any Error)
}

/// The one slot of a viewer that shows a result surface.
///
/// The host owns the installed surface, the one load task and the gate that issues
/// tokens. ``show(kind:input:)`` cancels the load in flight, takes a new token,
/// removes the installed surface, makes the new one from the registry and loads it.
/// The host installs the new surface only while its token is still current, as the
/// one child of the parent controller with its view pinned to the container's edges.
/// ``clear()`` cancels the load and removes the child.
///
/// The load starts at once on the main actor, so a surface whose load does not
/// suspend, such as one given a result its caller has already read, is installed
/// before ``show(kind:input:)`` returns, and ``lastOutcome`` says how it ended.
///
/// The host also keeps each view (`Sources/LungfishKit/ViewMemory/`). It captures a ``ViewMemoryAdopting`` surface
/// before ``ResultViewport/willDeactivate(replacedBy:)``, hands a new one its kept view after `load` and before the
/// install, and draws the reset line above it when part of that view was not kept.
@MainActor
public final class ViewportHost {
    /// The installed surface, or nil while nothing is installed or a load is in flight.
    public private(set) var activeViewport: (any ResultViewport)?

    /// The kind of the latest show that no clear has ended, loading or installed.
    public private(set) var requestedKind: SurfaceKind?

    /// The task of the latest show. Its value is that show's outcome.
    public private(set) var loadTask: Task<SurfaceShowOutcome, Never>?

    /// The outcome of the latest show once its load has ended, or nil while it
    /// loads and after a clear.
    public private(set) var lastOutcome: SurfaceShowOutcome?

    /// The factories this host makes surfaces from. A test registers a stand-in here.
    public let registry: SurfaceRegistry

    /// The store this host keeps views in, the process default unless a test injects one (VS A6).
    public let viewMemoryStore: ViewMemoryStore

    /// The reset line drawn above the installed surface, nil when none shows (VS U2).
    public internal(set) var resetLine: ViewMemoryResetLineView?

    /// Called after the host installs a surface, with that surface, and after a clear, with nil. The viewer puts back
    /// what it lays out above the installed surface, such as the strip of a result an earlier build made wrong. It
    /// must not call ``show(kind:input:)`` or ``clear()``, since a load that does not suspend installs inside `show`.
    public var activeViewportDidChange: (@MainActor (_ installed: (any ResultViewport)?) -> Void)?

    /// The installed adopter's capture and reset, nil when the installed surface keeps no view.
    var viewMemorySession: ViewMemorySession?
    /// The top constraint of the installed surface and the anchor it pins to, which the reset line moves down.
    var installedTop: (constraint: NSLayoutConstraint, anchor: NSLayoutYAxisAnchor)?
    var windowCloseObserver: ViewMemoryWindowCloseObserver?

    private var gate = AsyncRequestGate<SurfaceRequest>()
    weak var containerView: NSView?
    private weak var parentController: NSViewController?

    /// A host that installs surfaces made by `registry` into `containerView`, as
    /// children of `parentController`. The host holds both weakly, since the viewer
    /// that owns them owns the host.
    public init(
        registry: SurfaceRegistry, containerView: NSView, parentController: NSViewController,
        viewMemoryStore: ViewMemoryStore = .shared
    ) {
        self.registry = registry
        self.containerView = containerView
        self.parentController = parentController
        self.viewMemoryStore = viewMemoryStore
        startViewMemory()
    }

    /// The window that shows the container, for the window-close capture.
    var containerWindow: NSWindow? { containerView?.window }

    /// Shows a new surface of `kind` loaded from `input`, in place of the installed one.
    ///
    /// - Returns: The load task, whose value says whether the surface was installed.
    @discardableResult
    public func show(kind: SurfaceKind, input: Any) -> Task<SurfaceShowOutcome, Never> {
        loadTask?.cancel()
        let token = gate.begin(identity: SurfaceRequest(kind: kind))
        requestedKind = kind
        lastOutcome = nil
        removeActiveViewport(replacedBy: kind)

        let task: Task<SurfaceShowOutcome, Never>
        do {
            let viewport = try registry.make(kind)
            task = Task.immediate { @MainActor [weak self] in
                guard let self else { return .refused }
                let outcome = await self.load(viewport, input: input, token: token)
                if self.gate.isCurrent(token) { self.lastOutcome = outcome }
                return outcome
            }
        } catch {
            lastOutcome = .failed(error)
            task = Task { .failed(error) }
        }
        loadTask = task
        return task
    }

    /// Cancels the load in flight and removes the installed surface.
    public func clear() {
        loadTask?.cancel()
        loadTask = nil
        gate.invalidate()
        requestedKind = nil
        lastOutcome = nil
        removeActiveViewport(replacedBy: nil)
        activeViewportDidChange?(nil)
    }

    /// Whether `token` belongs to the latest show that no clear has ended. An
    /// installed surface checks it before it applies the result of later work.
    public func isCurrent(_ token: AsyncRequestToken<SurfaceRequest>) -> Bool {
        gate.isCurrent(token)
    }

    private func load(
        _ viewport: any ResultViewport,
        input: Any,
        token: AsyncRequestToken<SurfaceRequest>
    ) async -> SurfaceShowOutcome {
        do {
            try await viewport.load(input: input, token: token)
        } catch {
            return gate.isCurrent(token) ? .failed(error) : .refused
        }
        guard gate.isCurrent(token) else { return .refused }
        let memory = prepareViewMemory(for: viewport)
        return commit(viewport, memory: memory) ? .committed : .refused
    }

    /// Installs `viewport` as the one child, with its view memory session and reset line. Refuses when the viewer
    /// has gone.
    private func commit(_ viewport: any ResultViewport, memory: ViewMemoryOpening?) -> Bool {
        guard let containerView, let parentController else { return false }
        removeActiveViewport(replacedBy: viewport.surfaceKind)
        let controller = viewport.viewController
        parentController.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)
        let top = viewport.pinsTopToSafeArea ? containerView.safeAreaLayoutGuide.topAnchor : containerView.topAnchor
        let topConstraint = view.topAnchor.constraint(equalTo: top)
        NSLayoutConstraint.activate([
            topConstraint,
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        installedTop = (topConstraint, top)
        activeViewport = viewport
        viewMemorySession = memory?.session
        if let words = memory?.words { showResetLine(words) }
        activeViewportDidChange?(viewport)
        return true
    }

    /// Keeps the installed view, then removes the installed surface and its reset line and tells it which kind
    /// takes its place.
    private func removeActiveViewport(replacedBy next: SurfaceKind?) {
        guard let viewport = activeViewport else { return }
        viewMemorySession?.capture()
        viewMemorySession = nil
        removeResetLine()
        installedTop = nil
        activeViewport = nil
        viewport.willDeactivate(replacedBy: next)
        viewport.viewController.view.removeFromSuperview()
        viewport.viewController.removeFromParent()
    }
}
