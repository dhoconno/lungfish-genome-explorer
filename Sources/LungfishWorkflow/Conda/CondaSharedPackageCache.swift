// CondaSharedPackageCache.swift - One micromamba package cache for every channel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Points a conda root's micromamba at the shared package cache.
///
/// micromamba reads `$MAMBA_ROOT_PREFIX/.mambarc`, so writing `pkgs_dirs`
/// there covers every launch that sets `MAMBA_ROOT_PREFIX` (CondaManager,
/// Nextflow, pipelines) without touching their environments. The shared cache
/// is listed first, so new packages are downloaded and extracted once under
/// `~/.lungfish-shared/conda/pkgs`, and each channel's environments hardlink
/// from it (micromamba links from the cache on the same volume). The root's
/// own `pkgs/` stays second so packages already extracted there remain usable.
///
/// Sharing is only configured on the same APFS volume. Anywhere else the file
/// is left absent and micromamba keeps its per-root cache as before.
public struct CondaSharedPackageCache: Sendable {
    public static let configurationFilename = ".mambarc"
    public static let environmentKey = "LUNGFISH_CONDA_SHARED_PKGS"
    static let marker = "# Managed by Lungfish Genome Explorer: shared package cache."

    private let homeDirectory: URL
    private let environment: [String: String]
    private let sameVolume: @Sendable (URL, URL) -> Bool
    private var fileManager: FileManager { .default }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(homeDirectory: homeDirectory, environment: environment, sameVolume: APFSCloneSupport.onSameVolume)
    }

    init(
        homeDirectory: URL,
        environment: [String: String],
        sameVolume: @escaping @Sendable (URL, URL) -> Bool
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.environment = environment
        self.sameVolume = sameVolume
    }

    /// The shared cache this configuration would use, or `nil` when sharing is
    /// disabled through `LUNGFISH_CONDA_SHARED_PKGS=0`.
    public var sharedCacheURL: URL? {
        let raw = environment[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ["0", "off", "false", "no"].contains(raw.lowercased()) { return nil }
        if raw.hasPrefix("/"), !raw.contains(" ") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }
        return ManagedStorageChannelRoots.sharedCondaPackageCacheURL(homeDirectory: homeDirectory)
    }

    /// Writes or removes `<rootPrefix>/.mambarc` for the current situation and
    /// returns the shared cache in use, or `nil` when the root keeps its own cache.
    @discardableResult
    public func configure(rootPrefix: URL) throws -> URL? {
        let root = rootPrefix.standardizedFileURL
        let configURL = root.appendingPathComponent(Self.configurationFilename)
        guard let shared = sharedCacheURL, shared != root.appendingPathComponent("pkgs", isDirectory: true),
              !root.path.contains(" "), sameVolume(root, shared) else {
            try removeManagedConfiguration(at: configURL)
            return nil
        }
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = Self.configurationContents(sharedCache: shared, rootPrefix: root)
        if let existing = try? String(contentsOf: configURL, encoding: .utf8), existing == contents {
            return shared
        }
        if fileManager.fileExists(atPath: configURL.path), !Self.isManaged(configURL) {
            // A hand-written micromamba config belongs to the user; leave it alone.
            return nil
        }
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return shared
    }

    static func configurationContents(sharedCache: URL, rootPrefix: URL) -> String {
        """
        \(marker)
        # Packages are downloaded and extracted once into the shared cache and
        # hardlinked into this root's environments. Edit at your own risk: the
        # file is rewritten whenever micromamba is prepared.
        pkgs_dirs:
          - \(sharedCache.path)
          - \(rootPrefix.appendingPathComponent("pkgs", isDirectory: true).path)

        """
    }

    static func isManaged(_ configURL: URL) -> Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.hasPrefix(marker) == true
    }

    private func removeManagedConfiguration(at configURL: URL) throws {
        guard fileManager.fileExists(atPath: configURL.path), Self.isManaged(configURL) else { return }
        try fileManager.removeItem(at: configURL)
    }
}
