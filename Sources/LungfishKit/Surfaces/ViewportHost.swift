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
@MainActor
public final class ViewportHost {
    /// The installed surface, or nil while nothing is installed or a load is in flight.
    public private(set) var activeViewport: (any ResultViewport)?

    /// The kind of the latest show that no clear has ended, loading or installed.
    public private(set) var requestedKind: SurfaceKind?

    /// The task of the latest show. Its value is that show's outcome.
    public private(set) var loadTask: Task<SurfaceShowOutcome, Never>?

    private var gate = AsyncRequestGate<SurfaceRequest>()
    private let registry: SurfaceRegistry
    private weak var containerView: NSView?
    private weak var parentController: NSViewController?

    /// A host that installs surfaces made by `registry` into `containerView`, as
    /// children of `parentController`. The host holds both weakly, since the viewer
    /// that owns them owns the host.
    public init(registry: SurfaceRegistry, containerView: NSView, parentController: NSViewController) {
        self.registry = registry
        self.containerView = containerView
        self.parentController = parentController
    }

    /// Shows a new surface of `kind` loaded from `input`, in place of the installed one.
    ///
    /// - Returns: The load task, whose value says whether the surface was installed.
    @discardableResult
    public func show(kind: SurfaceKind, input: Any) -> Task<SurfaceShowOutcome, Never> {
        loadTask?.cancel()
        let token = gate.begin(identity: SurfaceRequest(kind: kind))
        requestedKind = kind
        removeActiveViewport()

        let task: Task<SurfaceShowOutcome, Never>
        do {
            let viewport = try registry.make(kind)
            task = Task { @MainActor [weak self] in
                guard let self else { return .refused }
                return await self.load(viewport, input: input, token: token)
            }
        } catch {
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
        removeActiveViewport()
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
        return commit(viewport) ? .committed : .refused
    }

    /// Installs `viewport` as the one child. Refuses when the viewer has gone.
    private func commit(_ viewport: any ResultViewport) -> Bool {
        guard let containerView, let parentController else { return false }
        removeActiveViewport()
        let controller = viewport.viewController
        parentController.addChild(controller)
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: containerView.topAnchor),
            view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        activeViewport = viewport
        return true
    }

    private func removeActiveViewport() {
        guard let viewport = activeViewport else { return }
        activeViewport = nil
        viewport.willDeactivate()
        viewport.viewController.view.removeFromSuperview()
        viewport.viewController.removeFromParent()
    }
}
