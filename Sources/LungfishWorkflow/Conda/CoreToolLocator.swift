// CoreToolLocator.swift - Resolve always-required managed tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum CoreToolLocator {
    public static func condaRoot(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("conda", isDirectory: true)
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

    public static func bbToolsEnvironment(
        homeDirectory: URL,
        existingPath: String
    ) -> [String: String] {
        let envRoot = environmentURL(named: "bbtools", homeDirectory: homeDirectory)
        let binDir = envRoot.appendingPathComponent("bin", isDirectory: true)
        let java = binDir.appendingPathComponent("java")

        return [
            "PATH": "\(binDir.path):\(existingPath)",
            "JAVA_HOME": envRoot.path,
            "BBMAP_JAVA": java.path,
        ]
    }
}
