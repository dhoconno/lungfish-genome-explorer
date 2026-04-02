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
    public let version: String?

    /// Download size in bytes (compressed tarball).
    public let sizeBytes: Int64

    /// Actual disk usage after extraction, if known.
    ///
    /// Mutable because the exact size is computed after extraction completes.
    public var sizeOnDisk: Int64?

    /// URL for downloading the pre-built database tarball.
    public let downloadURL: String?

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
        description: String,
        collection: DatabaseCollection? = nil,
        path: URL? = nil,
        isExternal: Bool = false,
        bookmarkData: Data? = nil,
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
        self.description = description
        self.collection = collection
        self.path = path
        self.isExternal = isExternal
        self.bookmarkData = bookmarkData
        self.lastUpdated = lastUpdated
        self.status = status
        self.recommendedRAM = recommendedRAM
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
            && lhs.description == rhs.description
            && lhs.collection == rhs.collection
            && lhs.path?.absoluteString == rhs.path?.absoluteString
            && lhs.isExternal == rhs.isExternal
            && lhs.bookmarkData == rhs.bookmarkData
            && lhs.lastUpdated == rhs.lastUpdated
            && lhs.status == rhs.status
            && lhs.recommendedRAM == rhs.recommendedRAM
    }
}

// MARK: - Built-in Catalog

extension MetagenomicsDatabaseInfo {

    /// The latest known build date for the pre-built Kraken2 indexes.
    ///
    /// Updated when new builds are published at
    /// `https://benlangmead.github.io/aws-indexes/k2`.
    static let latestBuildDate = "20240904"

    /// Complete built-in catalog of all metagenomics databases.
    ///
    /// Includes Kraken2 pre-built databases from Ben Langmead's AWS collection
    /// and EsViritu's curated viral database from Zenodo.
    public static let builtInCatalog: [MetagenomicsDatabaseInfo] = {
        // Kraken2 databases
        var catalog = DatabaseCollection.allCases.map { collection in
            MetagenomicsDatabaseInfo(
                name: collection.displayName,
                tool: MetagenomicsTool.kraken2.rawValue,
                version: latestBuildDate,
                sizeBytes: collection.approximateSizeBytes,
                sizeOnDisk: collection.approximateSizeBytes,
                downloadURL: "\(collection.downloadURLBase)_\(latestBuildDate).tar.gz",
                description: collection.contentsDescription,
                collection: collection,
                path: nil,
                isExternal: false,
                bookmarkData: nil,
                lastUpdated: nil,
                status: .missing,
                recommendedRAM: collection.approximateRAMBytes
            )
        }

        // EsViritu curated viral database
        catalog.append(MetagenomicsDatabaseInfo(
            name: "EsViritu Viral DB",
            tool: MetagenomicsTool.esviritu.rawValue,
            version: "v3.2.4",
            sizeBytes: 400 * 1_048_576,  // ~400 MB download
            sizeOnDisk: 5 * 1_073_741_824,  // ~5 GB extracted
            downloadURL: "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz",
            description: "19,925 curated viral assemblies across 63 families (Tisza et al. 2023)",
            collection: nil,
            path: nil,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: nil,
            status: .missing,
            recommendedRAM: 8 * 1_073_741_824  // ~8 GB RAM recommended
        ))

        // NCBI Taxonomy dump for taxon ID resolution
        catalog.append(MetagenomicsDatabaseInfo(
            name: "NCBI Taxonomy",
            tool: MetagenomicsTool.ncbiTaxonomy.rawValue,
            version: "2025-03",
            sizeBytes: 63 * 1_048_576,          // ~63 MB compressed
            sizeOnDisk: 200 * 1_048_576,        // ~200 MB extracted
            downloadURL: "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz",
            description: "NCBI Taxonomy names and hierarchy for taxon ID resolution",
            collection: nil,
            path: nil,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: nil,
            status: .missing,
            recommendedRAM: 256 * 1_048_576     // 256 MB
        ))

        return catalog
    }()

    /// Returns a catalog entry by collection, or `nil` if not found.
    ///
    /// - Parameter collection: The database collection to look up.
    /// - Returns: The corresponding catalog entry.
    public static func catalogEntry(for collection: DatabaseCollection) -> MetagenomicsDatabaseInfo? {
        builtInCatalog.first { $0.collection == collection }
    }
}
