// DependencyReceiptStore.swift - Load, save, and synthesize the dependency install receipt
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reads and writes `<storageRoot>/dependency-receipt.json`, and reconstructs a receipt
/// from what is on disk when none exists.
public struct DependencyReceiptStore: Sendable {
    public let storageRoot: URL

    public init(storageRoot: URL) { self.storageRoot = storageRoot.standardizedFileURL }

    public var receiptURL: URL { storageRoot.appendingPathComponent("dependency-receipt.json") }

    /// The stored receipt, or nil when none has been written yet.
    /// Throws on a corrupt or future-schema receipt so the caller can synthesize instead.
    public func load() throws -> DependencyReceipt? {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let data = try Data(contentsOf: receiptURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(DependencyReceipt.self, from: data)
        guard receipt.schemaVersion == DependencyReceipt.currentSchemaVersion else {
            throw DependencyReceiptError.unsupportedSchema(receipt.schemaVersion)
        }
        return receipt
    }

    /// Writes the receipt atomically, stamping `updatedAt`.
    ///
    /// Returns the receipt as written: `updatedAt` carries the save timestamp, and every
    /// date is truncated to whole seconds to match the ISO8601 on-disk resolution, so the
    /// returned value compares equal to what a subsequent `load()` produces.
    @discardableResult
    public func save(_ receipt: DependencyReceipt) throws -> DependencyReceipt {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var copy = receipt
        copy.updatedAt = Date()
        copy.truncateDatesToWholeSeconds()
        let data = try encoder.encode(copy)
        let tmp = receiptURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            _ = try FileManager.default.replaceItemAt(receiptURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: receiptURL)
        }
        return copy
    }

    /// Builds a receipt from what is on disk when none exists (users upgrading from pre-receipt builds).
    ///
    /// Every directory under `<condaRoot>/envs` that has a readable `conda-meta` becomes an
    /// entry; the planner decides which of those are retired. Directories whose names start
    /// with `.` are skipped.
    public func synthesize(condaRoot: URL, manifest: ManagedToolLock) -> DependencyReceipt {
        let envsURL = condaRoot.appendingPathComponent("envs", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: envsURL.path)) ?? []
        var environments: [String: [CondaMetaPackage]] = [:]
        var installedAt: [String: Date] = [:]
        for name in names where !name.hasPrefix(".") {
            let envURL = envsURL.appendingPathComponent(name)
            environments[name] = CondaMetaReader.packages(inEnvironment: envURL)
            if let created = (try? FileManager.default.attributesOfItem(atPath: envURL.path))?[.creationDate] as? Date {
                installedAt[name] = created
            }
        }
        return synthesize(environments: environments, manifest: manifest, installedAt: installedAt)
    }

    /// Builds a receipt from already-enumerated environment package lists.
    ///
    /// Used by the reconciler, which reads environments through injectable services rather
    /// than touching the filesystem directly. Entries default to `Date()` for `installedAt`.
    public func synthesize(
        environments: [String: [CondaMetaPackage]],
        manifest: ManagedToolLock
    ) -> DependencyReceipt {
        synthesize(environments: environments, manifest: manifest, installedAt: [:])
    }

    private func synthesize(
        environments: [String: [CondaMetaPackage]],
        manifest: ManagedToolLock,
        installedAt: [String: Date]
    ) -> DependencyReceipt {
        var receipt = DependencyReceipt.empty()
        receipt.synthesized = true
        let primaryByEnv = Self.primaryPackagesByEnvironment(manifest: manifest)
        for (name, packages) in environments {
            guard !packages.isEmpty else { continue }
            let known = primaryByEnv[name]
            let primaryName = known?.name ?? name
            guard let pkg = packages.first(where: { $0.name == primaryName })
                ?? packages.first(where: { $0.name == name }) else { continue }
            let channel = known?.channel ?? Self.inferChannel(pkg.channel)
            let spec = [
                channel.map { "\($0)::" } ?? "",
                pkg.name,
                "=",
                pkg.version,
                pkg.build.map { "=\($0)" } ?? ""
            ].joined()
            receipt.environments[name] = .init(
                packageSpec: spec,
                packID: known?.packID,
                installedAt: installedAt[name] ?? Date(),
                state: .installed
            )
        }
        return receipt
    }

    private struct PrimaryPackage {
        let name: String
        let channel: String?
        let packID: String?
    }

    /// Maps env name -> primary package the manifest pins there (env "bbtools" -> package "bbmap").
    private static func primaryPackagesByEnvironment(manifest: ManagedToolLock) -> [String: PrimaryPackage] {
        var result: [String: PrimaryPackage] = [:]
        for tool in manifest.tools {
            guard let parsed = CondaSpec(spec: tool.packageSpec) else { continue }
            result[tool.environment] = PrimaryPackage(
                name: parsed.name,
                channel: parsed.channel,
                packID: manifest.packID
            )
        }
        for tool in manifest.packTools where result[tool.environment] == nil {
            guard let parsed = CondaSpec(spec: tool.packageSpec) else { continue }
            result[tool.environment] = PrimaryPackage(
                name: parsed.name,
                channel: parsed.channel,
                packID: tool.packID
            )
        }
        return result
    }

    private static func inferChannel(_ url: String?) -> String? {
        guard let url else { return nil }
        if url.contains("/bioconda") { return "bioconda" }
        if url.contains("/conda-forge") { return "conda-forge" }
        return nil
    }
}

public enum DependencyReceiptError: Error, Equatable {
    case unsupportedSchema(Int)
}
