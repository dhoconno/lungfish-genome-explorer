// NativeToolRunner+Environment.swift - What a native tool launch changes in the inherited environment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension NativeToolRunner {
    /// What a launch that passes `overrides` changes in the inherited
    /// environment, for the provenance observer, or nil when no observer is
    /// bound.
    ///
    /// `overrides` is what the launch hands to
    /// ``ToolProcessSpec/inheritedEnvironment(overriding:)``. For a managed
    /// tool that is the caller's variables with the tool's environment `bin`
    /// folder put before PATH, and for a BBTools script also its own JAVA_HOME
    /// and BBMAP_JAVA. The change is built only for an observed launch,
    /// because building it sanitizes paths and nothing else reads it. It never
    /// changes the environment itself.
    func observedEnvironmentChange(overriding overrides: [String: String]?) -> ToolProcessEnvironmentChange? {
        guard ToolProcessObservation.observer != nil else { return nil }
        return Self.environmentChange(overriding: overrides, sanitizing: environmentChangeContext)
    }

    /// The change that setting `overrides` over the inherited environment makes.
    ///
    /// It names every variable in `overrides`, keeps a value only for an
    /// allowlisted name (`ToolProcessEnvironmentChange.valueRecordedNames`)
    /// and removes nothing, because this adapter never unsets a variable.
    /// PATH keeps no value, and ``ToolProcessEnvironmentChange/pathPrefix``
    /// holds the entries before the inherited PATH, so the user's PATH never
    /// reaches a record.
    ///
    /// - Parameters:
    ///   - overrides: The variables the launch sets.
    ///   - inheritedPath: The PATH the launch inherits.
    ///   - context: The sanitizing context, with this runner's tool root.
    static func environmentChange(
        overriding overrides: [String: String]?,
        inheritedPath: String? = ProcessInfo.processInfo.environment["PATH"],
        sanitizing context: PortablePath.Context
    ) -> ToolProcessEnvironmentChange {
        let variables = overrides ?? [:]
        return ToolProcessEnvironmentChange(
            base: .inherited,
            set: variables,
            pathPrefix: pathPrefix(of: variables["PATH"], inheritedPath: inheritedPath),
            sanitizing: context
        )
    }

    /// The PATH entries that a launch put before the inherited PATH.
    ///
    /// - Parameters:
    ///   - path: The PATH the launch sets, or nil when it sets none.
    ///   - inheritedPath: The PATH the launch inherits.
    /// - Returns: Nothing when `path` is nil or is the inherited PATH. The
    ///   entries in front of the inherited PATH when `path` ends with it, for
    ///   example the environment `bin` folder of a managed tool. All entries
    ///   of `path` when it does not end with the inherited PATH, because the
    ///   launch then replaced the PATH. Empty entries are left out.
    static func pathPrefix(of path: String?, inheritedPath: String?) -> [String] {
        guard let path, path != inheritedPath else { return [] }
        var prefix = Substring(path)
        if let inheritedPath, !inheritedPath.isEmpty, path.hasSuffix(":" + inheritedPath) {
            prefix = prefix.dropLast(inheritedPath.count + 1)
        }
        return prefix.split(separator: ":").map(String.init)
    }

    /// The `NativeTool` name that `name` spells, or nil.
    ///
    /// `run` hands its tool's name to `runProcess`, and a direct caller of
    /// `runProcess` names its tool with a free label such as "Primer3 version
    /// probe". Only a `NativeTool` name is an identity for a record.
    static func nativeToolName(_ name: String?) -> String? {
        name.flatMap { NativeTool(rawValue: $0)?.rawValue }
    }

    /// The context that sanitizes a change: this runner's conda root reads
    /// `<tool-root>`, and the managed storage root reads `<storage-root>`.
    var environmentChangeContext: PortablePath.Context {
        PortablePath.Context(
            projectURL: nil,
            toolRootURL: CoreToolLocator.condaRoot(homeDirectory: homeDirectory, appIdentity: appIdentity),
            storageRootURL: PortablePath.defaultManagedRoots.storageRoot
        )
    }
}
