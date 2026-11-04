// PhylogeneticTreeSurface.swift - The phylogenetic tree viewer as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The phylogenetic tree viewer as a ``ResultViewport``.
///
/// Its input is the URL of a tree bundle. The load builds a ``PhylogeneticTreeViewController`` and reads the bundle
/// into it with `displayBundle(at:)`, which does not suspend, so the host installs the viewer before `show` returns.
/// A bundle that does not read throws that file's own error, and the host reports `.failed` with it. The App registers
/// ``factory()`` for `.bundle(.phylogeneticTree)` and wires the viewer's two callbacks after the show.
@MainActor
public final class PhylogeneticTreeSurface: ResultViewport {
    /// The tree viewer the host installs, the one the load built.
    public private(set) var controller: PhylogeneticTreeViewController?

    /// Called whenever the host removes this viewer, so the App can take the tree's blocks out of the Inspector. It
    /// runs for its own kind too: the App gives the Inspector a new tree's blocks only after that tree's show.
    public var onWillDeactivate: (@MainActor () -> Void)?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    public init() {}

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory() -> SurfaceRegistry.Factory {
        { PhylogeneticTreeSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .bundle(.phylogeneticTree) }

    /// Cuts the two callbacks the App wired on the viewer, so a controller that something else still holds reaches
    /// neither the Inspector nor a command, then runs ``onWillDeactivate``. It runs for every kind that takes this
    /// viewer's place, its own kind included. The viewer holds no edit, so there is nothing to save.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        controller?.onSelectionStateChanged = nil
        controller?.onTreeBundleOperationRequested = nil
        onWillDeactivate?()
    }

    /// Builds the viewer and reads the bundle at the URL the App passed as `input`.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let url = try expectInput(input, as: URL.self)
        let tree = PhylogeneticTreeViewController()
        try tree.displayBundle(at: url)
        controller = tree
    }
}
