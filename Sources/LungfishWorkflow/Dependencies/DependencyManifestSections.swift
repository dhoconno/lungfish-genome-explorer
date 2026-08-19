// DependencyManifestSections.swift - Manifest sections for the single dependency source of truth
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

/// The `ManagedToolLock` document, viewed as the app's single dependency manifest:
/// managed CLI tools, optional pack tools, pipeline pins, bundled/catalog databases,
/// and bootstrap (micromamba) metadata.
public typealias DependencyManifest = ManagedToolLock

/// A pinned tool belonging to an optional `PluginPack` (as opposed to the always-installed
/// `ManagedToolLock.tools`).
public struct PackToolSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(packID)/\(toolID)" }
    public let packID: String
    public let toolID: String
    public let environment: String
    public let packageSpec: String
    public let executables: [String]
    public let version: String
    public let license: String?
    public let sourceUrl: String?
    /// Opt-in: when this environment already exists on disk with all `executables` present but
    /// its conda-meta carries no record of the pinned package, keep what is there instead of
    /// reinstalling over it.
    ///
    /// Absent (or false) means the ordinary policy applies: unreadable provenance is a
    /// `.metadataMismatch` and the environment is reinstalled from the pin. Set this only for a
    /// tool whose pinned build is not an improvement on what a user is likely to have built
    /// themselves, because it trades "the manifest is the authority" for "do not destroy a
    /// working local install". It never suppresses a genuine version or build change, and never
    /// suppresses the first install of a missing environment.
    public let preserveExistingInstall: Bool?
    /// Present when the pack builds this tool FROM SOURCE instead of installing
    /// `packageSpec`. The pins a source build depends on (its toolchain packages and the
    /// pinned tarball) live here so the sweep tooling can see them; the guard tests
    /// forbid conda spec literals outside the manifest. `packageSpec` remains the conda
    /// fallback the reconciler applies when it must rebuild the environment itself.
    public let sourceBuild: SourceBuildSpec?

    public init(
        packID: String,
        toolID: String,
        environment: String,
        packageSpec: String,
        executables: [String],
        version: String,
        license: String?,
        sourceUrl: String?,
        preserveExistingInstall: Bool? = nil,
        sourceBuild: SourceBuildSpec? = nil
    ) {
        self.packID = packID
        self.toolID = toolID
        self.environment = environment
        self.packageSpec = packageSpec
        self.executables = executables
        self.version = version
        self.license = license
        self.sourceUrl = sourceUrl
        self.preserveExistingInstall = preserveExistingInstall
        self.sourceBuild = sourceBuild
    }

    enum CodingKeys: String, CodingKey {
        case packID, toolID = "id", environment, packageSpec, executables, version, license, sourceUrl
        case preserveExistingInstall
        case sourceBuild
    }
}

/// A source build a pack tool applies instead of its conda `packageSpec`.
public struct SourceBuildSpec: Sendable, Codable, Hashable {
    /// The version the source build produces; this is what the tool actually is.
    public let version: String
    /// The pinned source archive.
    public let url: String
    /// SHA-256 of the archive, lowercase hex.
    public let sha256: String
    /// Conda packages the build and runtime need, installed in place of `packageSpec`.
    public let toolchainPackages: [String]

    public init(version: String, url: String, sha256: String, toolchainPackages: [String]) {
        self.version = version
        self.url = url
        self.sha256 = sha256.lowercased()
        self.toolchainPackages = toolchainPackages
    }
}

/// A pinned external pipeline (e.g. a Nextflow pipeline repository) the app invokes.
public struct PipelineSpec: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let repository: String
    public let revision: String
    public let releaseVersion: String
}

/// Whether a database update is merely advisory (the app notes a newer version exists) or
/// required (the app blocks/prompts because the installed database is incompatible).
public enum DatabaseUpdatePolicy: String, Sendable, Codable {
    case advisory
    case required
}

/// A pinned reference database: either a bundled sidecar (human-scrubber, deacon indexes)
/// or a catalog entry the user downloads on demand (Kraken2 collections, EsViritu, etc.).
public struct DatabaseSpec: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let tool: String
    public let displayName: String
    public let version: String
    public let url: String?
    public let filename: String?
    public let md5: String?
    public let sha256: String?
    public let md5Sidecar: Bool?
    public let indexFormat: Int?
    public let minimumToolVersion: String?
    public let sizeBytes: Int64?
    public let sizeOnDisk: Int64?
    public let recommendedRAM: Int64?
    public let description: String?
    public let releaseDate: String?
    public let sourceUrl: String?
    public let releasesUrl: String?
    public let updatePolicy: DatabaseUpdatePolicy?
    /// Kraken2 collection raw value when this entry is a Kraken2 catalog entry (e.g. "standard-16").
    public let collection: String?

    public var effectiveUpdatePolicy: DatabaseUpdatePolicy { updatePolicy ?? .advisory }
}

/// Pinned micromamba binary metadata used to bootstrap the conda root.
public struct MicromambaSpec: Sendable, Codable, Hashable {
    public let version: String
    /// Keyed by platform ("osx-arm64").
    public let sha256: [String: String]?
}

/// Bootstrap-time pins (currently just micromamba itself).
public struct BootstrapSpec: Sendable, Codable, Hashable {
    public let micromamba: MicromambaSpec
}

public extension ManagedToolLock {
    /// The bundled dependency manifest, decoded once and cached.
    ///
    /// Callers that build static tables (`PluginPack.builtIn`) read specs through this
    /// instead of re-decoding the JSON per lookup. If the bundled resource cannot be
    /// loaded, this is an empty manifest, so downstream tables fall back to their own
    /// missing-entry handling rather than trapping at launch.
    static let bundled: ManagedToolLock = (try? loadFromBundle())
        ?? ManagedToolLock(
            packID: "lungfish-tools",
            displayName: "Third-Party Tools",
            version: "unknown",
            tools: [],
            managedData: []
        )

    /// The manifest's dependency set, falling back to a legacy synthetic identifier
    /// (`legacy-<version>`) for manifests written before `dependencySet` existed.
    var resolvedDependencySet: String { dependencySet ?? "legacy-\(version)" }

    func packTool(packID: String, id: String) -> PackToolSpec? {
        packTools.first { $0.packID == packID && $0.toolID == id }
    }
    func pipeline(id: String) -> PipelineSpec? { pipelines.first { $0.id == id } }
    func database(id: String) -> DatabaseSpec? { databases.first { $0.id == id } }

    /// The conda package spec (`channel::name=version=build`) for a managed tool or pack tool,
    /// looked up by its `environment` name. Managed `tools` are searched before `packTools`.
    func packageSpec(forEnvironment environment: String) -> String? {
        tools.first { $0.environment == environment }?.packageSpec
            ?? packTools.first { $0.environment == environment }?.packageSpec
    }

    /// The pinned version for a managed tool or pack tool, looked up by its `environment` name.
    func toolVersion(forEnvironment environment: String) -> String? {
        tools.first { $0.environment == environment }?.version
            ?? packTools.first { $0.environment == environment }?.version
    }

    /// Every conda spec the manifest pins (managed tools + pack tools).
    var allCondaSpecs: [String] { tools.map(\.packageSpec) + packTools.map(\.packageSpec) }

    /// sha256 over canonical (sorted-keys) JSON of the manifest.
    var manifestHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
