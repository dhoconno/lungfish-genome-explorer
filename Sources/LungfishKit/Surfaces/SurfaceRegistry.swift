// SurfaceRegistry.swift - The factory that makes the result surface of each kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why a result surface could not be made or loaded, in words a person reads.
public enum SurfaceError: Error, LocalizedError, Equatable {
    /// No factory is registered for the kind.
    case notRegistered(SurfaceKind)
    /// The surface was given data of another type than the one it reads.
    case unexpectedInput(kind: SurfaceKind, expected: String)
    /// A caller that needs the surface installed at once found it still loading or
    /// overtaken by a newer show.
    case notInstalled(SurfaceKind)

    public var errorDescription: String? {
        switch self {
        case .notRegistered(let kind):
            "Lungfish has no viewer for this kind of item (\(kind))."
        case .unexpectedInput(let kind, _):
            "The viewer for this item (\(kind)) was given data it cannot read."
        case .notInstalled(let kind):
            "The viewer for this item (\(kind)) did not open."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notRegistered:
            "Check for a newer version of Lungfish. If this version should open the item, report the kind named above."
        case .unexpectedInput:
            "Select the item again. If the viewer stays empty, report the kind named above."
        case .notInstalled:
            "Select the item again."
        }
    }
}

/// The factories that make the result surface of each kind.
///
/// Kit cannot import the leaf modules, so the App fills the registry at one
/// composition point. A leaf exports a factory and the App registers it with one
/// line. Registering a kind again replaces its factory, so a test can put a stub
/// surface in place of the App's.
@MainActor
public final class SurfaceRegistry {
    /// Makes a new surface each time ``ViewportHost`` shows its kind.
    public typealias Factory = @MainActor () -> any ResultViewport

    private var factories: [SurfaceKind: Factory] = [:]

    public init() {}

    /// Registers `factory` for `kind`, in place of any factory registered before.
    public func register(_ kind: SurfaceKind, factory: @escaping Factory) {
        factories[kind] = factory
    }

    /// Whether a factory is registered for `kind`.
    public func isRegistered(_ kind: SurfaceKind) -> Bool {
        factories[kind] != nil
    }

    /// Every kind with a registered factory.
    public var registeredKinds: Set<SurfaceKind> {
        Set(factories.keys)
    }

    /// A new surface for `kind`, or ``SurfaceError/notRegistered(_:)``.
    public func make(_ kind: SurfaceKind) throws -> any ResultViewport {
        guard let factory = factories[kind] else {
            throw SurfaceError.notRegistered(kind)
        }
        return factory()
    }
}
