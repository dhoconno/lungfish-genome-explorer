// CoreToolLocator.swift - Resolve always-required managed tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public enum CoreToolLocator {
    public static let bbToolsPhiXReferenceFileName = "phix174_ill.ref.fa.gz"

    public static func managedExecutableURL(
        environment: String,
        executableName: String,
        homeDirectory: URL,
        fallbackExecutablePaths: [String] = []
    ) -> URL {
        let envRoot = environmentURL(named: environment, homeDirectory: homeDirectory)
        let primary = envRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(executableName)
        let fileManager = FileManager.default

        if fileManager.isExecutableFile(atPath: primary.path) {
            return primary
        }

        for fallbackPath in fallbackExecutablePaths {
            let fallback = envRoot.appendingPathComponent(fallbackPath)
            if fileManager.isExecutableFile(atPath: fallback.path) {
                return fallback
            }
        }

        return primary
    }

    public static func bbToolsJavaURL(homeDirectory: URL) -> URL {
        environmentURL(named: "bbtools", homeDirectory: homeDirectory)
            .appendingPathComponent("lib/jvm", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("java")
    }

    public static func condaRoot(homeDirectory: URL) -> URL {
        let store = ManagedStorageConfigStore(homeDirectory: homeDirectory)

        // An explicitly injected home wins over the ambient storage-root
        // environment overrides.
        //
        // currentCondaRootURL() consults LUNGFISH_CONDA_ROOT and
        // LUNGFISH_STORAGE_ROOT from the process environment before it looks at
        // the home this store was built with. That is right for the app and the
        // CLI, where the override is the user asking for a different root. It is
        // wrong for a caller that passed a specific home precisely to pin tool
        // resolution to it: tests build stub executables under a temporary home
        // and construct a runner with it, and under an ambient override those
        // runs silently resolved the developer's real tools instead of the
        // stubs, turning a passing suite into confusing failures the moment
        // anything set a storage root.
        //
        // The default home keeps the old behavior, so the override still works
        // for every caller that did not name a home of its own.
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser
        if homeDirectory.standardizedFileURL != defaultHome.standardizedFileURL {
            return store.currentCondaRootURL(environment: [:])
        }

        return store.currentCondaRootURL()
    }

    public static func environmentURL(
        named environment: String,
        homeDirectory: URL
    ) -> URL {
        condaRoot(homeDirectory: homeDirectory)
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
    }

    public static func executableURL(
        environment: String,
        executableName: String,
        homeDirectory: URL
    ) -> URL {
        environmentURL(named: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(executableName)
    }

    public static func bbToolsResourceURL(
        named resourceName: String,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let envRoot = environmentURL(named: "bbtools", homeDirectory: homeDirectory)
        let directCandidates = [
            envRoot
                .appendingPathComponent("share/bbmap/resources", isDirectory: true)
                .appendingPathComponent(resourceName),
            envRoot
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent(resourceName),
        ]

        for candidate in directCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let optRoot = envRoot.appendingPathComponent("opt", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: optRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.hasPrefix("bbmap")
        {
            let candidate = entry
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent(resourceName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    public static func bbToolsPhiXReferenceURL(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        bbToolsResourceURL(
            named: bbToolsPhiXReferenceFileName,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    public static func bbToolsEnvironment(
        homeDirectory: URL,
        existingPath: String
    ) -> [String: String] {
        let envRoot = environmentURL(named: "bbtools", homeDirectory: homeDirectory)
        let binDir = envRoot.appendingPathComponent("bin", isDirectory: true)
        let javaHome = envRoot.appendingPathComponent("lib/jvm", isDirectory: true)
        let java = bbToolsJavaURL(homeDirectory: homeDirectory)
        let javaBinDir = java.deletingLastPathComponent()

        return [
            "PATH": "\(javaBinDir.path):\(binDir.path):\(existingPath)",
            "JAVA_HOME": javaHome.path,
            "BBMAP_JAVA": java.path,
        ]
    }
}
