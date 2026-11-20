// ManagedToolLock+Entry.swift - One lock entry seen through either lock list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// One lock entry seen through either list, `tools` or `packTools`.
///
/// This is a read-only view. The lock stays the single place the facts live, and a caller
/// that needs a field this view does not carry reads the lock entry itself.
public struct ManagedToolLockEntry: Sendable, Hashable {
    /// Which lock list the entry came from.
    public enum Source: Sendable, Hashable {
        case tool
        case packTool(packID: String)
    }

    public let id: ManagedToolID
    public let environment: String
    /// The pinned version. Optional only because `tools[].version` is optional in the lock.
    public let version: String?
    public let executables: [String]
    public let source: Source
    /// Present when the pack builds a Python runtime for the tool, such as primalscheme3.
    public let pythonRuntime: ManagedPythonRuntimeSpec?
    /// Present when the pack builds the tool from source, such as bracken.
    public let sourceBuild: SourceBuildSpec?
    public let preserveExistingInstall: Bool?

    /// True for a pack tool whose pack the registry marks experimental.
    ///
    /// The CLI refuses to install an experimental pack, so no provisioned root holds its
    /// environment and a conformance run cannot require it.
    public var isInExperimentalPack: Bool {
        guard case .packTool(let packID) = source else { return false }
        return PluginPack.builtInPack(id: packID)?.isExperimental == true
    }
}

extension ManagedToolLock {
    /// Every lock entry, `tools` first and then `packTools`, in lock order.
    public var entries: [ManagedToolLockEntry] {
        let fromTools = tools.map { spec in
            ManagedToolLockEntry(
                id: ManagedToolID(rawValue: spec.id),
                environment: spec.environment,
                version: spec.version,
                executables: spec.executables,
                source: .tool,
                pythonRuntime: nil,
                sourceBuild: nil,
                preserveExistingInstall: nil
            )
        }
        let fromPackTools = packTools.map { spec in
            ManagedToolLockEntry(
                id: ManagedToolID(rawValue: spec.toolID),
                environment: spec.environment,
                version: spec.version,
                executables: spec.executables,
                source: .packTool(packID: spec.packID),
                pythonRuntime: spec.pythonRuntime,
                sourceBuild: spec.sourceBuild,
                preserveExistingInstall: spec.preserveExistingInstall
            )
        }
        return fromTools + fromPackTools
    }

    /// The entry with this id, searching `tools` and then `packTools`.
    public func entry(id: ManagedToolID) -> ManagedToolLockEntry? {
        entries.first { $0.id == id }
    }

    /// The first entry installed in this environment, searching `tools` and then `packTools`.
    public func entry(environment: String) -> ManagedToolLockEntry? {
        entries.first { $0.environment == environment }
    }

    /// The entry of this environment that a record names. A pack can install several tools in one environment (`sc-embed`
    /// holds `scanpy`, `python-igraph`, `leidenalg` and `umap-learn`), so the first entry of the environment names the right
    /// tool for one of them only. A record names its tool by the tool id of its step, else by the package of the spec it
    /// recorded, else by the version it recorded, and the first entry of the environment answers when none of these picks
    /// one. An environment of one entry answers with that entry whatever the record says.
    public func entry(inEnvironment environment: String, tool: String?, package: String?, version: String?) -> ManagedToolLockEntry? {
        let installed = entries.filter { $0.environment == environment }
        guard installed.count > 1 else { return installed.first }
        if let tool, let named = installed.first(where: { $0.id.rawValue == tool }) { return named }
        if let package, let named = installed.first(where: { candidate in
            packageSpec(of: candidate).flatMap { CondaSpec(spec: $0)?.name } == package
        }) { return named }
        if let version, let named = installed.first(where: { $0.version == version }) { return named }
        return installed.first
    }
}
