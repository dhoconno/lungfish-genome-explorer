// BundleFixtureResource.swift - build-engine-agnostic Bundle.module resource lookup
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Errors thrown by `fixtureURL(_:in:)`.
public enum BundleFixtureResourceError: Error, CustomStringConvertible {
    case notFound(relativePath: String, bundle: Bundle, searched: [String])

    public var description: String {
        switch self {
        case let .notFound(relativePath, bundle, searched):
            return "Fixture resource \"\(relativePath)\" not found in bundle "
                + "\(bundle.bundleURL.path). Searched: \(searched.joined(separator: ", "))"
        }
    }
}

/// Resolves a fixture resource's URL inside a SwiftPM test bundle, independent
/// of which build engine produced it.
///
/// `Bundle.module.url(forResource:withExtension:)` only resolves resources at
/// the top level of the resource bundle. That is where the native SwiftPM
/// build engine places a `.copy("Resources")` directory's contents (flattened
/// so `Resources/primerschemes/x` becomes `<bundle>/primerschemes/x`), but the
/// Swift Build engine nests it one level deeper, under the bundle's own
/// `Contents/Resources/` (so the same fixture lands at
/// `<bundle>/Contents/Resources/Resources/primerschemes/x`). A lookup that
/// only tries the top level silently returns nil under Swift Build, crashing
/// callers that force-unwrap it (SIGTRAP) — see TST-03 in
/// docs/reports/2026-09-23-best-practices-audit/testing-ci.md.
///
/// This helper tries every layout SwiftPM is known to produce and returns the
/// first that exists on disk, so tests do not depend on the active engine.
///
/// - Parameters:
///   - relativePath: The resource's path relative to the resource root that
///     was declared with `.copy("...")` in `Package.swift`, e.g.
///     `"primerschemes/valid-simple.lungfishprimers"`.
///   - bundle: The resource bundle to search. Defaults to `Bundle.module`
///     from the caller's module when passed explicitly; callers must pass
///     their own `Bundle.module` since this helper lives in a different
///     module.
/// - Returns: The resolved, existing URL.
/// - Throws: `BundleFixtureResourceError.notFound` if no candidate layout
///   contains the resource. Never returns an optional and never force
///   unwraps, so callers get a descriptive failure instead of a crash.
public func fixtureURL(_ relativePath: String, in bundle: Bundle) throws -> URL {
    let fileManager = FileManager.default
    var candidates: [URL] = []

    if let resourceURL = bundle.resourceURL {
        // Native SwiftPM engine: `.copy("Resources")` contents land flat at
        // the bundle's resource root.
        candidates.append(resourceURL.appendingPathComponent(relativePath))
        // Swift Build engine: the copied directory keeps its own name
        // ("Resources") as one more path component under the resource root.
        candidates.append(
            resourceURL
                .appendingPathComponent("Resources")
                .appendingPathComponent(relativePath)
        )
    }

    // Bundle.module.url(forResource:withExtension:) is still tried directly
    // in case a future SwiftPM layout resolves it correctly where the two
    // filesystem probes above do not (for example, resources embedded in an
    // Info.plist resource index rather than found by path).
    let resourceComponent = (relativePath as NSString).lastPathComponent
    let subdirectory = (relativePath as NSString).deletingLastPathComponent
    if let direct = bundle.url(
        forResource: resourceComponent,
        withExtension: nil,
        subdirectory: subdirectory.isEmpty ? nil : subdirectory
    ) {
        candidates.append(direct)
    }

    for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
        return candidate
    }

    throw BundleFixtureResourceError.notFound(
        relativePath: relativePath,
        bundle: bundle,
        searched: candidates.map(\.path)
    )
}
