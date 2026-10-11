// CondaManager+Environment.swift - The environment runTool gives micromamba and what it changed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension CondaManager {
    /// The fixed PATH of a hermetic tool run, the system folders and nothing
    /// of the user's.
    static let hermeticToolPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The complete environment `runTool` gives micromamba.
    ///
    /// The environment is hermetic, so nothing from the caller's shell reaches
    /// the child except TMPDIR. It holds the root prefix, the fixed system
    /// ``hermeticToolPath``, the account's home folder, which managed
    /// launchers read, and the parent's TMPDIR when it has one. The caller's
    /// variables go over those and win.
    ///
    /// - Parameters:
    ///   - variables: The caller's variables.
    ///   - homeDirectory: The account's home folder.
    ///   - temporaryDirectory: The parent's TMPDIR, or nil when it has none.
    nonisolated func hermeticToolEnvironment(
        adding variables: [String: String]?,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        temporaryDirectory: String? = ProcessInfo.processInfo.environment["TMPDIR"]
    ) -> [String: String] {
        var environment: [String: String] = [
            "MAMBA_ROOT_PREFIX": rootPrefix.path,
            "PATH": Self.hermeticToolPath,
            "HOME": homeDirectory,
        ]
        if let temporaryDirectory {
            environment["TMPDIR"] = temporaryDirectory
        }
        if let variables {
            environment.merge(variables) { _, new in new }
        }
        return environment
    }

    /// What `environment` changes for the provenance observer, or nil when no
    /// observer is bound.
    ///
    /// The change is built only for an observed launch, because building it
    /// sanitizes paths and nothing else reads it. It never changes the
    /// environment itself. The observer is read here, when the spec is built,
    /// so bind it around the spec's construction as well as its launch. A
    /// binding around `ToolProcess.run` alone delivers the stage with no
    /// change.
    nonisolated func observedEnvironmentChange(of environment: [String: String]) -> ToolProcessEnvironmentChange? {
        guard ToolProcessObservation.observer != nil else { return nil }
        return environmentChange(of: environment, sanitizing: environmentChangeContext)
    }

    /// The change a hermetic `environment` makes, from an empty one.
    ///
    /// It names every variable the child has, and keeps a value only for an
    /// allowlisted name (`ToolProcessEnvironmentChange.valueRecordedNames`),
    /// so `HOME` and `TMPDIR` keep their names alone. PATH keeps no value.
    /// Its ``ToolProcessEnvironmentChange/pathPrefix`` holds the whole PATH
    /// the launch set, which is the fixed system folders unless the caller
    /// gave its own.
    nonisolated func environmentChange(
        of environment: [String: String],
        sanitizing context: PortablePath.Context
    ) -> ToolProcessEnvironmentChange {
        ToolProcessEnvironmentChange(
            base: .hermetic,
            set: environment,
            pathPrefix: (environment["PATH"] ?? "").split(separator: ":").map(String.init),
            sanitizing: context
        )
    }

    /// The context that sanitizes a change. This manager's conda root reads
    /// `<tool-root>`, and the managed storage root reads `<storage-root>`.
    nonisolated var environmentChangeContext: PortablePath.Context {
        PortablePath.Context(
            projectURL: nil,
            toolRootURL: rootPrefix,
            storageRootURL: PortablePath.defaultManagedRoots.storageRoot
        )
    }
}
