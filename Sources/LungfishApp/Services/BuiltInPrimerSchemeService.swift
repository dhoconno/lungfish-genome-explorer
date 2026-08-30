// BuiltInPrimerSchemeService.swift - Discover primer scheme bundles shipped with the app
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Enumerates built-in .lungfishprimers bundles shipped in the app's Resources.
public enum BuiltInPrimerSchemeService {
    /// Returns built-in primer scheme bundles from the portable app resource root.
    public static func listBuiltInSchemes() -> [PrimerSchemeBundle] {
        guard let folderURL = RuntimeResourceLocator.path("PrimerSchemes", in: .app) else {
            return []
        }
        return loadSchemes(from: folderURL)
    }

    /// Returns built-in schemes from an explicitly injected bundle.
    public static func listBuiltInSchemes(in bundle: Bundle) -> [PrimerSchemeBundle] {
        guard let resourceURL = bundle.resourceURL else { return [] }
        return loadSchemes(
            from: resourceURL.appendingPathComponent("PrimerSchemes", isDirectory: true)
        )
    }

    private static func loadSchemes(from folderURL: URL) -> [PrimerSchemeBundle] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "lungfishprimers" }
            .compactMap { try? PrimerSchemeBundle.load(from: $0) }
            .sorted { $0.manifest.name < $1.manifest.name }
    }
}
