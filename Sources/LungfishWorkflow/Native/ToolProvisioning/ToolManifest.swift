// ToolManifest.swift
// LungfishWorkflow
//
// Defines the manifest format for bundled bioinformatics tools.

import Foundation

// MARK: - ToolManifest

/// Describes a collection of tools to be provisioned and bundled with the app.
public struct ToolManifest: Codable, Sendable {
    /// Manifest format version.
    public let formatVersion: String

    /// When this manifest was last updated.
    public let lastUpdated: Date

    /// Tools defined in this manifest.
    public let tools: [BundledToolSpec]

    public init(
        formatVersion: String = "1.0",
        lastUpdated: Date = Date(),
        tools: [BundledToolSpec]
    ) {
        self.formatVersion = formatVersion
        self.lastUpdated = lastUpdated
        self.tools = tools
    }

    /// Creates a manifest from a JSON file.
    public static func load(from url: URL) throws -> ToolManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ToolManifest.self, from: data)
    }

    /// Saves the manifest to a JSON file.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}

// MARK: - BundledToolSpec

/// Defines a single tool or tool package to be provisioned and bundled with the app.
///
/// This is different from `ToolDefinition` (the protocol for workflow tools) - this
/// struct specifically describes how to provision (download/compile) bioinformatics
/// tools that are bundled with the application.
public struct BundledToolSpec: Codable, Sendable, Identifiable {
    public var id: String { name }

    /// Unique identifier for this tool/package.
    public let name: String

    /// Human-readable display name.
    public let displayName: String

    /// Version string.
    public let version: String

    /// License information.
    public let license: LicenseInfo

    /// How this tool is provisioned (download binary vs compile from source).
    public let provisioningMethod: ProvisioningMethod

    /// Executables provided by this tool package.
    public let executables: [String]

    /// Dependencies on other tool packages (by name).
    public let dependencies: [String]

    /// Supported architectures.
    public let supportedArchitectures: [Architecture]

    /// Optional notes about this tool.
    public let notes: String?

    public init(
        name: String,
        displayName: String,
        version: String,
        license: LicenseInfo,
        provisioningMethod: ProvisioningMethod,
        executables: [String],
        dependencies: [String] = [],
        supportedArchitectures: [Architecture] = [.arm64, .x86_64],
        notes: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.version = version
        self.license = license
        self.provisioningMethod = provisioningMethod
        self.executables = executables
        self.dependencies = dependencies
        self.supportedArchitectures = supportedArchitectures
        self.notes = notes
    }
}

// MARK: - LicenseInfo

/// License information for a tool.
public struct LicenseInfo: Codable, Sendable {
    /// SPDX license identifier (e.g., "MIT", "Apache-2.0").
    public let spdxId: String

    /// URL to the full license text.
    public let url: URL?

    /// Brief description of license terms.
    public let summary: String?

    public init(spdxId: String, url: URL? = nil, summary: String? = nil) {
        self.spdxId = spdxId
        self.url = url
        self.summary = summary
    }

    /// Common MIT license.
    public static let mit = LicenseInfo(
        spdxId: "MIT",
        summary: "Permissive open source license"
    )

    /// MIT/Expat license used by samtools.
    public static let mitExpat = LicenseInfo(
        spdxId: "MIT",
        url: URL(string: "https://github.com/samtools/samtools/blob/develop/LICENSE"),
        summary: "MIT/Expat permissive license"
    )
}

// MARK: - ProvisioningMethod

/// How a tool is provisioned.
public enum ProvisioningMethod: Codable, Sendable {
    /// Download a pre-built binary.
    case downloadBinary(BinaryDownload)

    /// Compile from source.
    case compileFromSource(SourceCompilation)

    /// Use a custom provisioner (identified by name).
    case custom(String)
}

// MARK: - BinaryDownload

/// Configuration for downloading pre-built binaries.
public struct BinaryDownload: Codable, Sendable {
    /// Download URLs per architecture.
    public let urls: [Architecture: URL]

    /// Expected checksums per architecture (SHA256).
    public let checksums: [Architecture: String]?

    /// Whether the download is an archive that needs extraction.
    public let isArchive: Bool

    /// Path within archive to the executable(s), if applicable.
    public let archivePaths: [String]?

    public init(
        urls: [Architecture: URL],
        checksums: [Architecture: String]? = nil,
        isArchive: Bool = false,
        archivePaths: [String]? = nil
    ) {
        self.urls = urls
        self.checksums = checksums
        self.isArchive = isArchive
        self.archivePaths = archivePaths
    }
}

// MARK: - SourceCompilation

/// Configuration for compiling from source.
public struct SourceCompilation: Codable, Sendable {
    /// URL to download source archive.
    public let sourceURL: URL

    /// Expected SHA256 checksum of source archive.
    public let sourceChecksum: String?

    /// Archive format.
    public let archiveFormat: ArchiveFormat

    /// Build system used.
    public let buildSystem: BuildSystem

    /// Configure flags.
    public let configureFlags: [String]

    /// Environment variables for build.
    public let buildEnvironment: [String: String]

    /// Post-build commands.
    public let postBuildCommands: [String]?

    public init(
        sourceURL: URL,
        sourceChecksum: String? = nil,
        archiveFormat: ArchiveFormat = .tarBz2,
        buildSystem: BuildSystem = .autotools,
        configureFlags: [String] = [],
        buildEnvironment: [String: String] = [:],
        postBuildCommands: [String]? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourceChecksum = sourceChecksum
        self.archiveFormat = archiveFormat
        self.buildSystem = buildSystem
        self.configureFlags = configureFlags
        self.buildEnvironment = buildEnvironment
        self.postBuildCommands = postBuildCommands
    }
}

// MARK: - Supporting Types

/// Target architecture.
public enum Architecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    /// The current machine's architecture.
    public static var current: Architecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }

    /// Clang architecture flag.
    public var clangFlag: String {
        "-arch \(rawValue)"
    }
}

/// Archive format.
public enum ArchiveFormat: String, Codable, Sendable {
    case tarGz = "tar.gz"
    case tarBz2 = "tar.bz2"
    case tarXz = "tar.xz"
    case zip = "zip"

    /// The tar extraction flag for this format.
    public var tarFlag: String? {
        switch self {
        case .tarGz: return "-z"
        case .tarBz2: return "-j"
        case .tarXz: return "-J"
        case .zip: return nil
        }
    }
}

/// Build system type.
public enum BuildSystem: String, Codable, Sendable {
    case autotools  // ./configure && make
    case cmake
    case make       // Just make, no configure
    case custom
}

// MARK: - Built-in Tool Specifications

extension BundledToolSpec {

    /// htslib - provides bgzip and tabix.
    public static func htslib(version: String = "1.21") -> BundledToolSpec {
        BundledToolSpec(
            name: "htslib",
            displayName: "HTSlib",
            version: version,
            license: .mitExpat,
            provisioningMethod: .compileFromSource(SourceCompilation(
                sourceURL: URL(string: "https://github.com/samtools/htslib/releases/download/\(version)/htslib-\(version).tar.bz2")!,
                archiveFormat: .tarBz2,
                buildSystem: .autotools,
                configureFlags: [
                    "--disable-libcurl",
                    "--disable-gcs",
                    "--disable-s3"
                ]
            )),
            executables: ["bgzip", "tabix"],
            dependencies: []
        )
    }

    /// samtools - SAM/BAM file manipulation.
    public static func samtools(version: String = "1.21") -> BundledToolSpec {
        BundledToolSpec(
            name: "samtools",
            displayName: "SAMtools",
            version: version,
            license: .mitExpat,
            provisioningMethod: .compileFromSource(SourceCompilation(
                sourceURL: URL(string: "https://github.com/samtools/samtools/releases/download/\(version)/samtools-\(version).tar.bz2")!,
                archiveFormat: .tarBz2,
                buildSystem: .autotools,
                configureFlags: ["--without-curses"]
            )),
            executables: ["samtools"],
            dependencies: ["htslib"]
        )
    }

    /// bcftools - VCF/BCF file manipulation.
    public static func bcftools(version: String = "1.21") -> BundledToolSpec {
        BundledToolSpec(
            name: "bcftools",
            displayName: "BCFtools",
            version: version,
            license: .mitExpat,
            provisioningMethod: .compileFromSource(SourceCompilation(
                sourceURL: URL(string: "https://github.com/samtools/bcftools/releases/download/\(version)/bcftools-\(version).tar.bz2")!,
                archiveFormat: .tarBz2,
                buildSystem: .autotools,
                configureFlags: ["--disable-perl-filters"]
            )),
            executables: ["bcftools"],
            dependencies: ["htslib"]
        )
    }

    /// UCSC tools - bedToBigBed, bedGraphToBigWig (pre-built x86_64 only).
    public static func ucscTools(version: String = "469") -> BundledToolSpec {
        BundledToolSpec(
            name: "ucsc-tools",
            displayName: "UCSC Genome Browser Tools",
            version: version,
            license: LicenseInfo(
                spdxId: "MIT",
                url: URL(string: "https://genome-source.gi.ucsc.edu/gitlist/kent.git/blob/master/src/LICENSE"),
                summary: "MIT license (UCSC Genome Browser)"
            ),
            provisioningMethod: .downloadBinary(BinaryDownload(
                urls: [
                    // UCSC only provides x86_64, works on arm64 via Rosetta
                    .x86_64: URL(string: "https://hgdownload.soe.ucsc.edu/admin/exe/macOSX.x86_64")!
                ],
                isArchive: false
            )),
            executables: ["bedToBigBed", "bedGraphToBigWig"],
            dependencies: [],
            supportedArchitectures: [.x86_64],  // Runs via Rosetta on arm64
            notes: "Pre-built x86_64 binaries from UCSC. Run via Rosetta 2 on Apple Silicon."
        )
    }

    /// Returns the default set of tools for Lungfish.
    public static var defaultTools: [BundledToolSpec] {
        [
            .htslib(),
            .samtools(),
            .bcftools(),
            .ucscTools()
        ]
    }
}
