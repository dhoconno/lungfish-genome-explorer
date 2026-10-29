// ResultViewport.swift - The protocol of a result surface and the kind that names it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// The kind of item a result surface shows.
///
/// A saved bundle is named by its ``BundleKindID`` and an analysis result under
/// `Analyses/` by its ``AnalysisToolID``. Kraken2, EsViritu, TaxTriage, NAO-MGS and
/// NVD have only an analysis id, so ``SurfaceRegistry`` is keyed by both.
public enum SurfaceKind: Hashable, Sendable, CustomStringConvertible {
    /// A saved bundle, such as a `.lungfish12s` 12S amplicon result.
    case bundle(BundleKindID)
    /// An analysis result, such as a Kraken2 classification.
    case analysis(AnalysisToolID)

    /// `bundle:<id>` or `analysis:<id>`, as logs, errors and tests spell the kind.
    public var description: String {
        switch self {
        case .bundle(let id): "bundle:\(id.rawValue)"
        case .analysis(let id): "analysis:\(id.rawValue)"
        }
    }
}

/// The name of one Inspector block a surface shows, such as its sample filter.
///
/// Kit types hold no App type, so a surface names its blocks with these ids and the
/// App maps each id onto its own Inspector section.
public struct SurfaceInspectorBlock: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A result surface that ``ViewportHost`` installs as a viewer's one child.
///
/// A conformer wraps the controller it shows and loads its input before the host
/// installs it. It holds no App type, so a leaf module can define one and export a
/// factory that the App registers in ``SurfaceRegistry``.
@MainActor
public protocol ResultViewport: AnyObject {
    /// The controller the host adds as its one child.
    var viewController: NSViewController { get }

    /// The kind this surface shows.
    var surfaceKind: SurfaceKind { get }

    /// Reads `input` and configures ``viewController`` before the host installs it.
    ///
    /// `input` is what the caller passed to ``ViewportHost/show(kind:input:)``, and a
    /// surface reads it with ``expectInput(_:as:)``. The host installs the controller
    /// only when `token` is still current after this returns, so a load that a newer
    /// show or a clear overtook is dropped. The host cancels the old load first, so a
    /// long load checks `Task.isCancelled` between its steps.
    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws

    /// Whether the surface's drawer is open, for View > Show Drawer and the toolbar.
    var isDrawerOpen: Bool { get }

    /// Opens the surface's drawer when it is closed and closes it when it is open.
    func toggleDrawer()

    /// The Inspector blocks this surface shows, in order.
    var inspectorBlocks: [SurfaceInspectorBlock] { get }

    /// Called once before the host removes the controller, so the surface can stop
    /// work of its own. `next` is the kind the host shows in its place, nil when the
    /// host is cleared, so a surface replaced by its own kind can keep what the
    /// caller has already given the new one.
    func willDeactivate(replacedBy next: SurfaceKind?)
}

@MainActor
extension ResultViewport {
    /// A surface with no drawer reports it closed.
    public var isDrawerOpen: Bool { false }

    /// A surface with no drawer ignores the toggle.
    public func toggleDrawer() {}

    /// A surface with no Inspector blocks of its own shows none.
    public var inspectorBlocks: [SurfaceInspectorBlock] { [] }

    /// A surface with no work of its own has nothing to stop.
    public func willDeactivate(replacedBy next: SurfaceKind?) {}

    /// `input` as a `T`, or ``SurfaceError/unexpectedInput(kind:expected:)`` when the
    /// caller passed another type.
    public func expectInput<T>(_ input: Any, as type: T.Type) throws -> T {
        guard let value = input as? T else {
            throw SurfaceError.unexpectedInput(kind: surfaceKind, expected: String(describing: type))
        }
        return value
    }
}
