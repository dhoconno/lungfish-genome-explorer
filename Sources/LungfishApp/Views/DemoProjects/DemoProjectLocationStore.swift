// DemoProjectLocationStore.swift - Remembers where the user keeps demo projects
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Per-user folder that holds downloaded demo projects.
///
/// The app passes `UserDefaults.standard`; tests pass an isolated suite so
/// they never touch the user's real preferences.
@MainActor
final class DemoProjectLocationStore {
    static let defaultsKey = "DemoProjectsInstallDirectory"

    private let defaults: UserDefaults
    private let homeDirectory: URL

    init(defaults: UserDefaults, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
    }

    /// `~/Documents/LGE Demo Projects` unless the user chose another folder.
    var defaultDirectory: URL {
        DemoProjectInstaller.defaultInstallDirectory(homeDirectory: homeDirectory)
    }

    var directory: URL {
        get {
            guard let path = defaults.string(forKey: Self.defaultsKey), path.hasPrefix("/") else {
                return defaultDirectory
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        set {
            let standardized = newValue.standardizedFileURL
            if standardized.path == defaultDirectory.standardizedFileURL.path {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(standardized.path, forKey: Self.defaultsKey)
            }
        }
    }

    var isUsingDefault: Bool {
        defaults.string(forKey: Self.defaultsKey) == nil
    }

    func resetToDefault() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
