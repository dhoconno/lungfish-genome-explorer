// ManagedStorageChannelRoots.swift - Every channel's managed storage root on this Mac
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Locates the managed storage roots of every upstream channel so identical
/// content can be shared between them with APFS clones.
///
/// Channels keep separate roots for isolation (`~/.lungfish`,
/// `~/.lungfish-stable`, `~/.lungfish-debug`). A channel that selected a
/// custom root records it in its bootstrap config, which is honoured here.
/// The shared root (`~/.lungfish-shared`) holds content every channel may
/// use, today the micromamba package cache.
public enum ManagedStorageChannelRoots {
    public static let sharedRootDirectoryName = ".lungfish-shared"

    /// The upstream channels that own a managed storage root.
    public static let upstreamIdentities: [LungfishAppIdentity] = [.preview, .stable, .debug]

    public static func sharedRootURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.standardizedFileURL.appendingPathComponent(sharedRootDirectoryName, isDirectory: true)
    }

    /// The micromamba package cache every channel lists first in `pkgs_dirs`.
    public static func sharedCondaPackageCacheURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        sharedRootURL(homeDirectory: homeDirectory)
            .appendingPathComponent("conda", isDirectory: true)
            .appendingPathComponent("pkgs", isDirectory: true)
    }

    /// The root each upstream channel uses on this Mac, whether or not it exists.
    ///
    /// Reads only the channel's bootstrap config on disk (never preferences or
    /// the process environment), so the answer is the same from any channel or
    /// from a test that points `homeDirectory` at a temporary folder.
    public static func knownChannelRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        var roots: [URL] = []
        for identity in upstreamIdentities {
            let root = configuredRoot(for: identity, homeDirectory: homeDirectory, fileManager: fileManager)
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    /// The channel roots that exist on disk, plus the shared root when present.
    public static func existingRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        (knownChannelRoots(homeDirectory: homeDirectory, fileManager: fileManager) + [sharedRootURL(homeDirectory: homeDirectory)])
            .filter { isDirectory($0, fileManager: fileManager) }
    }

    /// Other channels' existing roots on the same volume as `root`, the only
    /// places a clone can be taken from.
    public static func siblingRoots(
        of root: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        let current = root.standardizedFileURL
        return knownChannelRoots(homeDirectory: homeDirectory, fileManager: fileManager).filter { candidate in
            candidate != current
                && isDirectory(candidate, fileManager: fileManager)
                && APFSCloneSupport.onSameVolume(candidate, current)
        }
    }

    static func configuredRoot(
        for identity: LungfishAppIdentity,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> URL {
        let home = homeDirectory.standardizedFileURL
        let configURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(identity.managedStorageConfigDirectoryName, isDirectory: true)
            .appendingPathComponent("storage-location.json")
        if fileManager.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(ManagedStorageBootstrapConfig.self, from: data),
           config.activeRootPath.hasPrefix("/"),
           config.migrationState != .pending {
            return URL(fileURLWithPath: config.activeRootPath, isDirectory: true).standardizedFileURL
        }
        return ManagedStorageLocation.defaultLocation(homeDirectory: home, appIdentity: identity).rootURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
