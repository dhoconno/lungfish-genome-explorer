// BuiltInPrimerSchemeService.swift - Discover primer scheme bundles shipped with the app
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Enumerates built-in .lungfishprimers bundles shipped in the app's Resources.
///
/// In production, callers query against `Bundle.main`; tests query against `Bundle.module`
/// (the LungfishApp module's bundle) via the `in:` overload.
public enum BuiltInPrimerSchemeService {
    /// Returns built-in primer scheme bundles sorted by manifest name.
    ///
    /// - Parameter bundle: The bundle whose Resources/PrimerSchemes folder should be enumerated. Defaults to `.main`.
    public static func listBuiltInSchemes(in bundle: Bundle = .main) -> [PrimerSchemeBundle] {
        let bundledSchemes = loadSchemes(in: bundle)
        if !bundledSchemes.isEmpty {
            return bundledSchemes
        }
        if bundle.bundleURL != Bundle.module.bundleURL {
            return loadSchemes(in: Bundle.module)
        }
        return []
    }

    private static func loadSchemes(in bundle: Bundle) -> [PrimerSchemeBundle] {
        guard let resourceURL = bundle.resourceURL else { return [] }
        let folderURL = resourceURL.appendingPathComponent("PrimerSchemes", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "lungfishprimers" }
            .compactMap { try? PrimerSchemeBundle.load(from: $0) }
            .sorted { $0.manifest.name < $1.manifest.name }
    }
}
