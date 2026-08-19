// MetagenomicsDatabaseInfo.swift - Metagenomics reference database descriptor
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - MetagenomicsDatabaseInfo

/// Information about a metagenomics reference database.
///
/// Each instance describes one database installation -- either a built-in catalog
/// entry that has not yet been downloaded, or a fully-installed database on disk.
/// The registry persists an array of these to `metagenomics-db-registry.json`.
///
/// ## Identification
///
/// The ``name`` property serves as the stable identifier. Names follow the
/// Kraken2 collection naming convention (e.g., "Standard-8", "PlusPF", "Viral").
///
/// ## External Volume Support
///
/// When a database resides on a removable volume, ``bookmarkData`` stores a
/// security-scoped bookmark so the app can re-resolve the path after relaunch
/// without requiring a new open-panel interaction.
///
/// ## RAM Recommendations
///
/// ``recommendedRAM`` indicates the minimum physical memory for efficient
/// classification. When the system has less RAM than recommended, the
/// classification pipeline should pass `--memory-mapping` to Kraken2, which
/// trades speed for a smaller memory footprint.
public struct MetagenomicsDatabaseInfo: Sendable, Codable, Identifiable, Equatable {

    /// Stable identifier derived from the database name.
    public var id: String { name }

    /// Human-readable name (e.g., "Standard-8", "PlusPF", "Viral").
    public let name: String

    /// Tool that uses this database (e.g., "kraken2", "bracken", "metaphlan").
    public let tool: String

    /// Database version or build date (e.g., "2024-09-04").
    public var version: String?

    /// Download size in bytes (compressed tarball).
    public let sizeBytes: Int64

    /// Actual disk usage after extraction, if known.
    ///
    /// Mutable because the exact size is computed after extraction completes.
    public var sizeOnDisk: Int64?

    /// URL for downloading the pre-built database tarball.
    ///
    /// Mutable so the registry can re-point a not-yet-installed entry at the
    /// currently pinned archive when the manifest moves to a newer build.
    public internal(set) var downloadURL: String?

    /// Stable identity of this built-in catalog entry, if applicable.
    ///
    /// Unlike ``collection``, this accommodates catalog entries that are not
    /// AWS Kraken2 collections.
    ///
    /// Mutable within the module so the registry can stamp the identity onto a row
    /// that was registered from disk by ``MetagenomicsDatabaseRegistry/registerExisting(at:name:)``
    /// and therefore started with none. Once an update has resolved such a row to a
    /// catalog entry by name and tool, recording the identity means every later lookup
    /// addresses it directly instead of re-deriving the match. Existing identities are
    /// never overwritten.
    public internal(set) var catalogID: String?

    /// Reproducible installation recipe for this database, if known.
    ///
    /// Mutable for the same reason as ``downloadURL``.
    public internal(set) var installationRecipe: MetagenomicsDatabaseInstallationRecipe?

    /// Optional checksum of the installed payload.
    public var payloadDigest: String?

    /// Human-readable description of the database contents.
    public let description: String

    /// Corresponding ``DatabaseCollection`` catalog entry, if this database
    /// was created from the built-in catalog. `nil` for user-imported databases.
    public let collection: DatabaseCollection?

    // MARK: - Location

    /// Absolute path where this database is installed on disk.
    /// `nil` when the database has not been downloaded yet.
    public var path: URL?

    /// Whether the database resides on an external (removable) volume.
    public var isExternal: Bool

    /// Security-scoped bookmark data for external-volume databases.
    ///
    /// Created via `URL.bookmarkData(options: .withSecurityScope)` when the
    /// user moves a database to an external volume.
    public var bookmarkData: Data?

    // MARK: - Status

    /// Whether the database has been downloaded and has a known path.
    public var isDownloaded: Bool { path != nil }

    /// Date when the database was last verified or updated.
    public var lastUpdated: Date?

    /// Date when this database was first installed or registered locally.
    public var installedAt: Date?

    /// Current operational status.
    public var status: DatabaseStatus

    /// Recommended minimum RAM in bytes for efficient classification.
    ///
    /// When system RAM is below this value, the pipeline should use
    /// `--memory-mapping` to avoid excessive swapping.
    public var recommendedRAM: Int64

    // MARK: - Initialization

    /// Creates a new database info descriptor.
    ///
    /// - Parameters:
    ///   - name: Human-readable name.
    ///   - tool: Tool identifier (e.g., "kraken2").
    ///   - version: Database version string.
    ///   - sizeBytes: Download size in bytes.
    ///   - sizeOnDisk: Extracted size on disk.
    ///   - downloadURL: URL for the pre-built tarball.
    ///   - description: Human-readable contents description.
    ///   - collection: Catalog entry, if applicable.
    ///   - path: Local installation path.
    ///   - isExternal: Whether on an external volume.
    ///   - bookmarkData: Security-scoped bookmark data.
    ///   - lastUpdated: Last verification date.
    ///   - status: Current operational status.
    ///   - recommendedRAM: Minimum RAM for efficient use.
    public init(
        name: String,
        tool: String,
        version: String? = nil,
        sizeBytes: Int64,
        sizeOnDisk: Int64? = nil,
        downloadURL: String? = nil,
        catalogID: String? = nil,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe? = nil,
        payloadDigest: String? = nil,
        description: String,
        collection: DatabaseCollection? = nil,
        path: URL? = nil,
        isExternal: Bool = false,
        bookmarkData: Data? = nil,
        installedAt: Date? = nil,
        lastUpdated: Date? = nil,
        status: DatabaseStatus = .missing,
        recommendedRAM: Int64
    ) {
        self.name = name
        self.tool = tool
        self.version = version
        self.sizeBytes = sizeBytes
        self.sizeOnDisk = sizeOnDisk
        self.downloadURL = downloadURL
        self.catalogID = catalogID
        self.installationRecipe = installationRecipe
        self.payloadDigest = payloadDigest
        self.description = description
        self.collection = collection
        self.path = path
        self.isExternal = isExternal
        self.bookmarkData = bookmarkData
        self.installedAt = installedAt
        self.lastUpdated = lastUpdated
        self.status = status
        self.recommendedRAM = recommendedRAM
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case tool
        case version
        case sizeBytes
        case sizeOnDisk
        case downloadURL
        case catalogID
        case installationRecipe
        case payloadDigest
        case description
        case collection
        case path
        case isExternal
        case bookmarkData
        case installedAt
        case lastUpdated
        case status
        case recommendedRAM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        tool = try container.decode(String.self, forKey: .tool)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        sizeOnDisk = try container.decodeIfPresent(Int64.self, forKey: .sizeOnDisk)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        catalogID = try container.decodeIfPresent(String.self, forKey: .catalogID)
        installationRecipe = try container.decodeIfPresent(
            MetagenomicsDatabaseInstallationRecipe.self,
            forKey: .installationRecipe
        ) ?? downloadURL.flatMap(URL.init(string:)).map { .archive(url: $0) }
        payloadDigest = try container.decodeIfPresent(String.self, forKey: .payloadDigest)
        description = try container.decode(String.self, forKey: .description)
        collection = try container.decodeIfPresent(DatabaseCollection.self, forKey: .collection)
        path = try container.decodeIfPresent(URL.self, forKey: .path)
        isExternal = try container.decode(Bool.self, forKey: .isExternal)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        status = try container.decode(DatabaseStatus.self, forKey: .status)
        recommendedRAM = try container.decode(Int64.self, forKey: .recommendedRAM)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(sizeOnDisk, forKey: .sizeOnDisk)
        try container.encodeIfPresent(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(catalogID, forKey: .catalogID)
        try container.encodeIfPresent(installationRecipe, forKey: .installationRecipe)
        try container.encodeIfPresent(payloadDigest, forKey: .payloadDigest)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(collection, forKey: .collection)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(isExternal, forKey: .isExternal)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encodeIfPresent(installedAt, forKey: .installedAt)
        try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
        try container.encode(status, forKey: .status)
        try container.encode(recommendedRAM, forKey: .recommendedRAM)
    }

    // MARK: - Equatable

    /// Two database infos are equal when all stored properties match.
    ///
    /// `path` comparison uses `absoluteString` to avoid file-system-level
    /// URL normalization differences.
    public static func == (lhs: MetagenomicsDatabaseInfo, rhs: MetagenomicsDatabaseInfo) -> Bool {
        lhs.name == rhs.name
            && lhs.tool == rhs.tool
            && lhs.version == rhs.version
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.sizeOnDisk == rhs.sizeOnDisk
            && lhs.downloadURL == rhs.downloadURL
            && lhs.catalogID == rhs.catalogID
            && lhs.installationRecipe == rhs.installationRecipe
            && lhs.payloadDigest == rhs.payloadDigest
            && lhs.description == rhs.description
            && lhs.collection == rhs.collection
            && lhs.path?.absoluteString == rhs.path?.absoluteString
            && lhs.isExternal == rhs.isExternal
            && lhs.bookmarkData == rhs.bookmarkData
            && lhs.installedAt == rhs.installedAt
            && lhs.lastUpdated == rhs.lastUpdated
            && lhs.status == rhs.status
            && lhs.recommendedRAM == rhs.recommendedRAM
    }
}

// MARK: - Built-in Catalog

extension MetagenomicsDatabaseInfo {

    /// The built-in catalog entry this row corresponds to, by the project's one
    /// two-step match: the recorded ``catalogID`` first, then name and tool.
    ///
    /// Rows installed through the catalog carry a `catalogID`, but the rows real users
    /// actually have are usually registered by
    /// ``MetagenomicsDatabaseRegistry/registerExisting(at:name:)``, which records no
    /// catalog identity at all. Every place that asks "which catalog entry is this?"
    /// must apply the same fallback or the surfaces disagree: `db list` and `db info`
    /// advertise an update (they read ``availableUpdateVersion``) while the reconciler's
    /// installed-version map and the update command silently skip the row.
    ///
    /// Shared here so those call sites cannot drift apart again.
    public var resolvedCatalogEntry: MetagenomicsDatabaseInfo? {
        if let catalogID, let entry = Self.catalogEntry(catalogID: catalogID) { return entry }
        // A row that records some *other* catalogID is authoritative about its identity,
        // so a mere name collision must not override it.
        guard catalogID == nil else { return nil }
        return Self.builtInCatalog.first { $0.name == name && $0.tool == tool }
    }

    /// The catalog identity this row addresses, resolved through ``resolvedCatalogEntry``.
    ///
    /// This is the id to hand to
    /// ``MetagenomicsDatabaseRegistry/updateDatabase(catalogID:progress:)`` and to key
    /// installed-version maps by, so a hand-registered `Viral` row is planned and updated
    /// under `kraken2-viral` like a catalog-installed one.
    public var resolvedCatalogID: String? {
        catalogID ?? resolvedCatalogEntry?.catalogID
    }

    /// Latest catalog version for this database, when it can be determined.
    public var availableUpdateVersion: String? {
        guard status == .ready, path != nil else { return nil }
        guard let catalogEntry = resolvedCatalogEntry else { return nil }
        guard let latestVersion = catalogEntry.version else { return nil }
        guard latestVersion != version else { return nil }
        return latestVersion
    }

    /// Whether the installed database is older than the built-in catalog entry.
    public var isUpdateAvailable: Bool {
        availableUpdateVersion != nil
    }

    /// Complete built-in catalog of all metagenomics databases.
    ///
    /// Derived from the `databases` section of the bundled dependency manifest
    /// (`third-party-tools-lock.json`), which is the single source of truth for
    /// pinned versions and download URLs. Entries cover Kraken2 pre-built databases
    /// from Ben Langmead's AWS collection, the Kraken2 special rRNA databases built
    /// locally, EsViritu's curated viral database from Zenodo, and the NCBI taxonomy
    /// dump. Manifest database entries for other tools (bundled sidecars such as the
    /// human scrubber and Deacon indexes) are managed elsewhere and are skipped here.
    public static let builtInCatalog: [MetagenomicsDatabaseInfo] = {
        ManagedToolLock.bundled.databases.compactMap(catalogEntry(from:))
    }()

    /// Converts one manifest database spec into a catalog entry, or `nil` when the
    /// spec describes a database this catalog does not manage.
    private static func catalogEntry(from spec: DatabaseSpec) -> MetagenomicsDatabaseInfo? {
        switch spec.tool {
        case MetagenomicsTool.kraken2.rawValue:
            if let rawCollection = spec.collection {
                guard let collection = DatabaseCollection(rawValue: rawCollection),
                      let urlString = spec.url,
                      let url = URL(string: urlString) else { return nil }
                return MetagenomicsDatabaseInfo(
                    name: spec.displayName,
                    tool: spec.tool,
                    version: spec.version,
                    sizeBytes: spec.sizeBytes ?? collection.approximateSizeBytes,
                    sizeOnDisk: spec.sizeOnDisk ?? collection.approximateSizeBytes,
                    downloadURL: urlString,
                    catalogID: spec.id,
                    installationRecipe: .archive(url: url),
                    description: spec.description ?? collection.contentsDescription,
                    collection: collection,
                    status: .missing,
                    recommendedRAM: spec.recommendedRAM ?? collection.approximateRAMBytes
                )
            }
            // Kraken2 special databases are built locally from named upstream rRNA sources.
            guard let special = Kraken2SpecialDatabase.allCases.first(where: {
                spec.id == "kraken2-special-\($0.rawValue)"
            }) else { return nil }
            return MetagenomicsDatabaseInfo(
                name: spec.displayName,
                tool: spec.tool,
                version: spec.version,
                sizeBytes: spec.sizeBytes ?? 0,
                sizeOnDisk: spec.sizeOnDisk,
                downloadURL: nil,
                catalogID: spec.id,
                installationRecipe: .kraken2Special(type: special),
                description: spec.description ?? "",
                status: .missing,
                recommendedRAM: spec.recommendedRAM ?? 0
            )

        case MetagenomicsTool.esviritu.rawValue, MetagenomicsTool.ncbiTaxonomy.rawValue:
            guard let urlString = spec.url, let url = URL(string: urlString) else { return nil }
            return MetagenomicsDatabaseInfo(
                name: spec.displayName,
                tool: spec.tool,
                version: spec.version,
                sizeBytes: spec.sizeBytes ?? 0,
                sizeOnDisk: spec.sizeOnDisk,
                downloadURL: urlString,
                catalogID: spec.id,
                installationRecipe: .archive(url: url),
                description: spec.description ?? "",
                status: .missing,
                recommendedRAM: spec.recommendedRAM ?? 0
            )

        default:
            // Bundled sidecars (human scrubber, Deacon indexes) are not catalog databases.
            return nil
        }
    }

    /// Returns a catalog entry by collection, or `nil` if not found.
    ///
    /// - Parameter collection: The database collection to look up.
    /// - Returns: The corresponding catalog entry.
    public static func catalogEntry(for collection: DatabaseCollection) -> MetagenomicsDatabaseInfo? {
        builtInCatalog.first { $0.collection == collection }
    }

    /// Returns a catalog entry by its stable built-in identity.
    public static func catalogEntry(catalogID: String) -> MetagenomicsDatabaseInfo? {
        builtInCatalog.first { $0.catalogID == catalogID }
    }
}
