// StubResultViewport.swift - A result surface for the ViewportHost tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// A controller with a plain view, so no nib is looked up.
final class StubSurfaceController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    }
}

/// A result surface whose load reads a `String` and ends at once, or, when it holds
/// its load, when the test calls ``releaseLoad()``. The hold is a seam, so a test
/// orders two loads without a sleep or a second thread.
@MainActor
final class StubResultViewport: ResultViewport {
    let viewController: NSViewController = StubSurfaceController()
    let surfaceKind: SurfaceKind

    /// The inputs and tokens of each load, in order.
    private(set) var loadedInputs: [String] = []
    private(set) var receivedTokens: [AsyncRequestToken<SurfaceRequest>] = []
    /// How many times the host deactivated this surface.
    private(set) var deactivationCount = 0
    /// The kind the host named at each deactivation, nil for a clear.
    private(set) var replacedBy: [SurfaceKind?] = []

    private let holdsLoad: Bool
    private let loadError: (any Error)?
    private var released = false
    private var heldLoad: CheckedContinuation<Void, Never>?

    init(kind: SurfaceKind, holdsLoad: Bool = false, loadError: (any Error)? = nil) {
        self.surfaceKind = kind
        self.holdsLoad = holdsLoad
        self.loadError = loadError
    }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        receivedTokens.append(token)
        loadedInputs.append(try expectInput(input, as: String.self))
        if holdsLoad, !released {
            await withCheckedContinuation { continuation in
                heldLoad = continuation
            }
        }
        if let loadError { throw loadError }
    }

    /// Ends a held load, or lets a load that has not started yet end at once.
    func releaseLoad() {
        released = true
        heldLoad?.resume()
        heldLoad = nil
    }

    func willDeactivate(replacedBy next: SurfaceKind?) {
        deactivationCount += 1
        replacedBy.append(next)
    }
}

/// Makes the stubs a registry hands out and keeps each one for the test to read.
@MainActor
final class StubSurfaceFactory {
    private(set) var made: [StubResultViewport] = []
    /// Whether the next surfaces made hold their load.
    var holdsLoad = false
    /// The error the next surfaces made throw from their load.
    var loadError: (any Error)?

    /// Registers a stub factory for each kind.
    func register(_ kinds: [SurfaceKind], in registry: SurfaceRegistry) {
        for kind in kinds {
            registry.register(kind) { [unowned self] in self.make(kind) }
        }
    }

    private func make(_ kind: SurfaceKind) -> StubResultViewport {
        let stub = StubResultViewport(kind: kind, holdsLoad: holdsLoad, loadError: loadError)
        made.append(stub)
        return stub
    }
}
