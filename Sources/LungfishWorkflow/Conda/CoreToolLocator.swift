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
        ManagedStorageConfigStore(homeDirectory: homeDirectory).currentLocation().condaRootURL
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

        return [
            "PATH": "\(binDir.path):\(existingPath)",
            "JAVA_HOME": javaHome.path,
            "BBMAP_JAVA": java.path,
        ]
    }
}
