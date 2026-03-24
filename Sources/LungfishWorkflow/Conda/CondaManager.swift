// CondaManager.swift - Micromamba-based package management for bioinformatics tools
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "CondaManager")

// MARK: - CondaError

/// Errors that can occur during conda operations.
public enum CondaError: Error, LocalizedError, Sendable {
    case micromambaNotFound
    case micromambaDownloadFailed(String)
    case environmentCreationFailed(String)
    case environmentNotFound(String)
    case packageInstallFailed(String)
    case packageNotFound(String)
    case toolNotFound(tool: String, environment: String)
    case executionFailed(tool: String, exitCode: Int32, stderr: String)
    case linuxOnlyPackage(String)
    case networkError(String)
    case diskSpaceError(String)
    case timeout(tool: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .micromambaNotFound:
            return "Micromamba binary not found. It will be downloaded automatically."
        case .micromambaDownloadFailed(let msg):
            return "Failed to download micromamba: \(msg)"
        case .environmentCreationFailed(let msg):
            return "Failed to create conda environment: \(msg)"
        case .environmentNotFound(let name):
            return "Conda environment '\(name)' not found"
        case .packageInstallFailed(let msg):
            return "Failed to install package: \(msg)"
        case .packageNotFound(let name):
            return "Package '\(name)' not found in bioconda or conda-forge"
        case .toolNotFound(let tool, let env):
            return "Tool '\(tool)' not found in environment '\(env)'"
        case .executionFailed(let tool, let code, let stderr):
            return "Tool '\(tool)' failed with exit code \(code): \(stderr)"
        case .linuxOnlyPackage(let name):
            return "Package '\(name)' is only available for Linux. Use Apple Containers to run it."
        case .networkError(let msg):
            return "Network error during conda operation: \(msg)"
        case .diskSpaceError(let msg):
            return "Insufficient disk space: \(msg)"
        case .timeout(let tool, let seconds):
            return "Tool '\(tool)' timed out after \(Int(seconds)) seconds"
        }
    }
}

// MARK: - CondaEnvironment

/// Represents a micromamba/conda environment.
public struct CondaEnvironment: Sendable, Codable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let path: URL
    public let packageCount: Int

    public init(name: String, path: URL, packageCount: Int = 0) {
        self.name = name
        self.path = path
        self.packageCount = packageCount
    }
}

// MARK: - CondaPackageInfo

/// Information about an installed or available conda package.
public struct CondaPackageInfo: Sendable, Codable, Identifiable, Hashable {
    public var id: String { "\(name)-\(version)-\(channel)" }
    public let name: String
    public let version: String
    public let channel: String
    public let buildString: String
    public let subdir: String
    public let license: String?
    public let description: String?
    public let sizeBytes: Int64?

    public init(
        name: String, version: String, channel: String,
        buildString: String = "", subdir: String = "",
        license: String? = nil, description: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.name = name
        self.version = version
        self.channel = channel
        self.buildString = buildString
        self.subdir = subdir
        self.license = license
        self.description = description
        self.sizeBytes = sizeBytes
    }

    /// Whether this package has a native macOS arm64 build.
    public var isNativeMacOS: Bool {
        subdir == "osx-arm64" || subdir == "noarch"
    }
}

// MARK: - PostInstallHook

/// A command to run after a plugin pack is installed.
///
/// Post-install hooks download reference data, update databases, or perform
/// other setup that tools need before they can function. Hooks may also be
/// re-run periodically to keep data current.
public struct PostInstallHook: Sendable, Codable, Hashable {
    /// Human-readable description of what this hook does.
    public let description: String

    /// The conda environment in which to run the command.
    public let environment: String

    /// The command to execute. First element is the tool name; remaining
    /// elements are arguments. Passed to ``CondaManager/runTool(name:arguments:environment:)``.
    public let command: [String]

    /// Whether this hook requires network access.
    public let requiresNetwork: Bool

    /// How often this hook should be re-run, in days.
    /// `nil` means run only once at install time.
    /// `7` means weekly, `30` monthly, `90` quarterly.
    public let refreshIntervalDays: Int?

    /// Approximate download size (human-readable, e.g. "~15 MB").
    public let estimatedDownloadSize: String?

    public init(
        description: String,
        environment: String,
        command: [String],
        requiresNetwork: Bool = true,
        refreshIntervalDays: Int? = nil,
        estimatedDownloadSize: String? = nil
    ) {
        self.description = description
        self.environment = environment
        self.command = command
        self.requiresNetwork = requiresNetwork
        self.refreshIntervalDays = refreshIntervalDays
        self.estimatedDownloadSize = estimatedDownloadSize
    }
}

// MARK: - PluginPack

/// A curated set of bioinformatics tools for a specific workflow.
///
/// Each pack installs one isolated conda environment per tool (not a single
/// shared environment). The micromamba package cache is shared across all
/// environments, so tools that appear in multiple packs are downloaded once.
///
/// ## Post-Install Hooks
///
/// Some packs require reference data downloads after tool installation.
/// These are defined in ``postInstallHooks`` and run automatically after
/// all packages in the pack are installed. Hooks with a non-nil
/// ``PostInstallHook/refreshIntervalDays`` are re-run periodically.
public struct PluginPack: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let sfSymbol: String
    public let packages: [String]
    public let category: String
    public let postInstallHooks: [PostInstallHook]
    public let estimatedSizeMB: Int

    public init(id: String, name: String, description: String,
                sfSymbol: String, packages: [String], category: String,
                postInstallHooks: [PostInstallHook] = [],
                estimatedSizeMB: Int = 0) {
        self.id = id
        self.name = name
        self.description = description
        self.sfSymbol = sfSymbol
        self.packages = packages
        self.category = category
        self.postInstallHooks = postInstallHooks
        self.estimatedSizeMB = estimatedSizeMB
    }

    /// All 13 built-in plugin packs covering major bioinformatics workflows.
    ///
    /// Tools already bundled natively (samtools, bcftools, fastp, seqkit,
    /// cutadapt, pigz, BBTools, bgzip, tabix) are NOT included in any pack.
    /// They are always available as Tier 1 tools.
    ///
    /// Tools that appear in multiple packs share a single conda environment.
    /// The ``CondaManager/install(packages:environment:)`` method skips
    /// creation if the environment already exists.
    public static let builtIn: [PluginPack] = [
        // MARK: Quality Control
        PluginPack(
            id: "illumina-qc",
            name: "Illumina QC",
            description: "Quality control and reporting for Illumina short-read sequencing data",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["fastqc", "multiqc", "trimmomatic"],
            category: "Quality Control",
            estimatedSizeMB: 1000
        ),

        // MARK: Alignment
        PluginPack(
            id: "alignment",
            name: "Alignment",
            description: "Map short and long reads to reference genomes",
            sfSymbol: "arrow.left.and.right.text.vertical",
            packages: ["bwa-mem2", "minimap2", "bowtie2", "hisat2"],
            category: "Alignment",
            estimatedSizeMB: 220
        ),

        // MARK: Variant Calling
        PluginPack(
            id: "variant-calling",
            name: "Variant Calling",
            description: "Discover SNPs, indels, and structural variants from aligned reads",
            sfSymbol: "diamond.fill",
            packages: ["freebayes", "lofreq", "gatk4", "ivar"],
            category: "Variant Calling",
            estimatedSizeMB: 850
        ),

        // MARK: Assembly
        PluginPack(
            id: "assembly",
            name: "Genome Assembly",
            description: "De novo genome assembly from short and long reads",
            sfSymbol: "puzzlepiece.extension.fill",
            packages: ["spades", "megahit", "flye", "quast"],
            category: "Assembly",
            estimatedSizeMB: 950
        ),

        // MARK: Phylogenetics
        PluginPack(
            id: "phylogenetics",
            name: "Phylogenetics",
            description: "Multiple sequence alignment and phylogenetic tree construction",
            sfSymbol: "tree",
            packages: ["iqtree", "mafft", "muscle", "raxml-ng", "treetime"],
            category: "Phylogenetics",
            estimatedSizeMB: 400
        ),

        // MARK: Metagenomics
        PluginPack(
            id: "metagenomics",
            name: "Metagenomics",
            description: "Taxonomic classification and community profiling of metagenomic samples",
            sfSymbol: "leaf.fill",
            packages: ["kraken2", "bracken", "metaphlan", "esviritu"],
            category: "Metagenomics",
            estimatedSizeMB: 800
        ),

        // MARK: Long Read
        PluginPack(
            id: "long-read",
            name: "Long Read Analysis",
            description: "Oxford Nanopore and PacBio long-read alignment, assembly, and polishing",
            sfSymbol: "ruler",
            packages: ["minimap2", "flye", "medaka", "hifiasm", "nanoplot"],
            category: "Long Read",
            estimatedSizeMB: 700
        ),

        // MARK: Wastewater Surveillance
        PluginPack(
            id: "wastewater-surveillance",
            name: "Wastewater Surveillance",
            description: "SARS-CoV-2 and multi-pathogen lineage de-mixing from wastewater sequencing data",
            sfSymbol: "drop.triangle",
            packages: ["freyja", "ivar", "pangolin", "nextclade", "minimap2"],
            category: "Surveillance",
            postInstallHooks: [
                PostInstallHook(
                    description: "Download latest SARS-CoV-2 lineage barcodes",
                    environment: "freyja",
                    command: ["freyja", "update"],
                    requiresNetwork: true,
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~15 MB"
                ),
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    requiresNetwork: true,
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 1500
        ),

        // MARK: RNA-Seq
        PluginPack(
            id: "rna-seq",
            name: "RNA-Seq Analysis",
            description: "Spliced alignment and transcript quantification for bulk RNA sequencing",
            sfSymbol: "bolt.horizontal",
            packages: ["star", "salmon", "subread", "stringtie"],
            category: "Transcriptomics",
            estimatedSizeMB: 600
        ),

        // MARK: Single Cell
        PluginPack(
            id: "single-cell",
            name: "Single-Cell Analysis",
            description: "Preprocessing and analysis of droplet-based single-cell RNA-seq data",
            sfSymbol: "circle.grid.3x3",
            // STAR includes STARsolo mode for single-cell barcode-aware alignment
            packages: ["scanpy", "scvi-tools", "star"],
            category: "Single Cell",
            estimatedSizeMB: 1800
        ),

        // MARK: Amplicon Analysis
        PluginPack(
            id: "amplicon-analysis",
            name: "Amplicon Analysis",
            description: "Primer trimming, variant calling, and consensus generation for tiled-amplicon protocols",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["ivar", "pangolin", "nextclade"],
            category: "Amplicon",
            postInstallHooks: [
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    requiresNetwork: true,
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 550
        ),

        // MARK: Genome Annotation
        PluginPack(
            id: "genome-annotation",
            name: "Genome Annotation",
            description: "Gene prediction and functional annotation for prokaryotic and viral genomes",
            sfSymbol: "tag.fill",
            packages: ["prokka", "bakta", "snpeff"],
            category: "Annotation",
            postInstallHooks: [
                PostInstallHook(
                    description: "Download Bakta light annotation database",
                    environment: "bakta",
                    command: ["bakta_db", "download", "--type", "light"],
                    requiresNetwork: true,
                    refreshIntervalDays: 90,
                    estimatedDownloadSize: "~1.3 GB"
                ),
            ],
            estimatedSizeMB: 1200
        ),

        // MARK: Data Format Utilities
        PluginPack(
            id: "data-format-utils",
            name: "Data Format Utilities",
            description: "File conversion, indexing, and interval manipulation for bioinformatics formats",
            sfSymbol: "arrow.triangle.2.circlepath",
            packages: ["bedtools", "picard"],
            category: "Utilities",
            estimatedSizeMB: 650
        ),
    ]
}

// MARK: - CondaManager

/// Manages micromamba environments and bioconda package installation.
///
/// Provides the core infrastructure for the plugin system:
/// - Downloads and manages the micromamba binary
/// - Creates per-tool conda environments
/// - Installs/uninstalls packages from bioconda and conda-forge
/// - Discovers tool executables in conda environments
/// - Integrates with Nextflow/Snakemake conda profiles
///
/// All operations are async and report progress via callbacks.
///
/// ## Storage
///
/// All conda data is stored in `~/.lungfish/conda/`:
/// - `bin/micromamba` -- the micromamba binary
/// - `envs/<name>/` -- per-tool environments
/// - `pkgs/` -- package cache (shared across environments)
///
/// ## Usage
///
/// ```swift
/// let manager = CondaManager.shared
/// try await manager.ensureMicromamba()
/// try await manager.install(packages: ["samtools"], environment: "samtools")
/// let path = try await manager.toolPath(name: "samtools", environment: "samtools")
/// ```
public actor CondaManager {

    /// Shared singleton instance.
    public static let shared = CondaManager()

    /// Root directory for all conda data.
    public let rootPrefix: URL

    /// Path to the micromamba binary.
    public var micromambaPath: URL {
        rootPrefix.appendingPathComponent("bin/micromamba")
    }

    /// Default channels for bioconda packages.
    public let defaultChannels: [String] = ["bioconda", "conda-forge"]

    /// Download URL for micromamba (macOS arm64).
    private let micromambaDownloadURL = "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-osx-arm64"

    private init() {
        // Use ~/.lungfish/conda instead of ~/Library/Application Support/Lungfish/conda
        // because many bioinformatics tools break on paths containing spaces.
        // The "Application Support" space in the standard macOS location causes
        // samtools, bcftools, and other tools that use internal shell pipes to fail.
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.rootPrefix = home.appendingPathComponent(".lungfish/conda")
    }

    // MARK: - Micromamba Bootstrap

    /// Ensures micromamba is available, downloading it if necessary.
    ///
    /// - Parameter progress: Optional progress callback (0.0 to 1.0).
    /// - Returns: URL to the micromamba binary.
    @discardableResult
    public func ensureMicromamba(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let binDir = rootPrefix.appendingPathComponent("bin")

        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            logger.info("Micromamba already available at \(self.micromambaPath.path, privacy: .public)")
            return micromambaPath
        }

        logger.info("Downloading micromamba...")
        progress?(0.0, "Downloading micromamba\u{2026}")

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Download micromamba binary
        let (tempURL, response) = try await URLSession.shared.download(
            from: URL(string: micromambaDownloadURL)!
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw CondaError.micromambaDownloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move to final location
        if FileManager.default.fileExists(atPath: micromambaPath.path) {
            try FileManager.default.removeItem(at: micromambaPath)
        }
        try FileManager.default.moveItem(at: tempURL, to: micromambaPath)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: micromambaPath.path
        )

        // Verify it works
        let version = try await runMicromamba(["--version"])
        logger.info("Micromamba \(version.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public) installed successfully")
        progress?(1.0, "Micromamba ready")

        return micromambaPath
    }

    // MARK: - Environment Management

    /// Creates a new conda environment with the specified packages.
    ///
    /// - Parameters:
    ///   - name: Environment name (used as directory name).
    ///   - packages: Packages to install.
    ///   - channels: Channels to use (defaults to bioconda + conda-forge).
    ///   - progress: Optional progress callback.
    public func createEnvironment(
        name: String,
        packages: [String],
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await ensureMicromamba()

        let effectiveChannels = channels ?? defaultChannels
        logger.info("Creating environment '\(name, privacy: .public)' with packages: \(packages.joined(separator: ", "), privacy: .public)")
        progress?(0.1, "Creating environment '\(name)'\u{2026}")

        var args = ["create", "-n", name, "--yes"]
        for ch in effectiveChannels {
            args += ["-c", ch]
        }
        args += packages

        let output = try await runMicromamba(args)
        logger.debug("Environment creation output: \(output, privacy: .public)")
        progress?(1.0, "Environment '\(name)' ready")
    }

    /// Removes a conda environment and all its packages.
    public func removeEnvironment(name: String) async throws {
        try await ensureMicromamba()
        logger.info("Removing environment '\(name, privacy: .public)'")

        let envPath = rootPrefix.appendingPathComponent("envs/\(name)")
        if FileManager.default.fileExists(atPath: envPath.path) {
            try FileManager.default.removeItem(at: envPath)
            logger.info("Environment '\(name, privacy: .public)' removed")
        } else {
            throw CondaError.environmentNotFound(name)
        }
    }

    /// Lists all conda environments.
    public func listEnvironments() async throws -> [CondaEnvironment] {
        let envsDir = rootPrefix.appendingPathComponent("envs")
        guard FileManager.default.fileExists(atPath: envsDir.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: envsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }

            // Count installed packages by checking conda-meta
            let condaMeta = url.appendingPathComponent("conda-meta")
            let pkgCount = (try? FileManager.default.contentsOfDirectory(atPath: condaMeta.path)
                .filter { $0.hasSuffix(".json") }.count) ?? 0

            return CondaEnvironment(
                name: url.lastPathComponent,
                path: url,
                packageCount: pkgCount
            )
        }
    }

    // MARK: - Package Management

    /// Installs packages into an existing environment, creating it if needed.
    public func install(
        packages: [String],
        environment: String,
        channels: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await ensureMicromamba()

        let envPath = rootPrefix.appendingPathComponent("envs/\(environment)")
        let effectiveChannels = channels ?? defaultChannels

        if !FileManager.default.fileExists(atPath: envPath.path) {
            // Create new environment
            try await createEnvironment(
                name: environment,
                packages: packages,
                channels: effectiveChannels,
                progress: progress
            )
        } else {
            // Install into existing environment
            logger.info("Installing \(packages.joined(separator: ", "), privacy: .public) into '\(environment, privacy: .public)'")
            progress?(0.1, "Installing \(packages.joined(separator: ", "))\u{2026}")

            var args = ["install", "-n", environment, "--yes"]
            for ch in effectiveChannels {
                args += ["-c", ch]
            }
            args += packages

            let output = try await runMicromamba(args)
            logger.debug("Install output: \(output, privacy: .public)")
            progress?(1.0, "Installation complete")
        }
    }

    /// Uninstalls packages from an environment.
    public func uninstall(
        packages: [String],
        from environment: String
    ) async throws {
        try await ensureMicromamba()
        logger.info("Uninstalling \(packages.joined(separator: ", "), privacy: .public) from '\(environment, privacy: .public)'")

        let args = ["remove", "-n", environment, "--yes"] + packages
        _ = try await runMicromamba(args)
    }

    /// Lists installed packages in an environment.
    public func listInstalled(in environment: String) async throws -> [CondaPackageInfo] {
        // Scan conda-meta/*.json directly instead of running `micromamba list --json`
        // which hangs on large environments (198+ packages in freyja-env).
        let condaMetaDir = rootPrefix
            .appendingPathComponent("envs/\(environment)/conda-meta")

        guard FileManager.default.fileExists(atPath: condaMetaDir.path) else {
            throw CondaError.environmentNotFound(environment)
        }

        let metaFiles = try FileManager.default.contentsOfDirectory(
            at: condaMetaDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent != "history" }

        struct CondaMetaRecord: Codable {
            let name: String?
            let version: String?
            let channel: String?
            let build: String?
            let subdir: String?
        }

        var packages: [CondaPackageInfo] = []
        packages.reserveCapacity(metaFiles.count)

        for file in metaFiles {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(CondaMetaRecord.self, from: data),
                  let name = record.name,
                  let version = record.version else { continue }

            packages.append(CondaPackageInfo(
                name: name,
                version: version,
                channel: record.channel ?? "unknown",
                buildString: record.build ?? "",
                subdir: record.subdir ?? ""
            ))
        }

        return packages
    }

    /// Searches for packages across channels.
    public func search(
        query: String,
        channels: [String]? = nil
    ) async throws -> [CondaPackageInfo] {
        try await ensureMicromamba()

        let effectiveChannels = channels ?? defaultChannels
        var args = ["search", query, "--json"]
        for ch in effectiveChannels {
            args += ["-c", ch]
        }

        let output = try await runMicromamba(args)
        guard let data = output.data(using: .utf8) else { return [] }

        // Parse search results
        struct SearchResult: Codable {
            let result: SearchResultInner?
        }
        struct SearchResultInner: Codable {
            let pkgs: [SearchPkg]?
        }
        struct SearchPkg: Codable {
            let name: String?
            let version: String?
            let channel: String?
            let build: String?
            let subdir: String?
            let license: String?
            let size: Int64?
        }

        // Try to parse as search output
        if let result = try? JSONDecoder().decode(SearchResult.self, from: data),
           let pkgs = result.result?.pkgs {
            return pkgs.compactMap { pkg in
                guard let name = pkg.name, let version = pkg.version else { return nil }
                return CondaPackageInfo(
                    name: name,
                    version: version,
                    channel: pkg.channel ?? "bioconda",
                    buildString: pkg.build ?? "",
                    subdir: pkg.subdir ?? "",
                    license: pkg.license,
                    sizeBytes: pkg.size
                )
            }
        }

        return []
    }

    // MARK: - Tool Discovery

    /// Returns the path to a tool executable in a conda environment.
    public func toolPath(
        name: String,
        environment: String
    ) async throws -> URL {
        let binPath = rootPrefix
            .appendingPathComponent("envs/\(environment)/bin/\(name)")

        guard FileManager.default.isExecutableFile(atPath: binPath.path) else {
            throw CondaError.toolNotFound(tool: name, environment: environment)
        }

        return binPath
    }

    /// Checks whether a tool is installed in any conda environment.
    ///
    /// Searches all environments under the conda root prefix for an executable
    /// matching the given tool name. This is a lightweight filesystem check —
    /// no subprocess is spawned.
    ///
    /// - Parameter name: The tool executable name (e.g., "kraken2", "EsViritu").
    /// - Returns: `true` if the tool is found in any environment's `bin/` directory.
    public func isToolInstalled(_ name: String) async -> Bool {
        let envsDir = rootPrefix.appendingPathComponent("envs")
        guard let envDirs = try? FileManager.default.contentsOfDirectory(
            at: envsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for envDir in envDirs {
            let binPath = envDir.appendingPathComponent("bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: binPath.path) {
                return true
            }
        }
        return false
    }

    /// Runs a tool from a conda environment.
    ///
    /// Uses `micromamba run -n <env> <tool> [args...]` to ensure the correct
    /// environment is activated, including library paths and Python venvs.
    ///
    /// Pipe reading is performed concurrently with the subprocess using
    /// `readabilityHandler` to avoid deadlocks when the process produces
    /// more than 64 KB of output. The actor thread is never blocked --
    /// the method suspends via `CheckedContinuation` until the process
    /// terminates or the timeout expires.
    ///
    /// - Parameters:
    ///   - name: The tool executable name (e.g., "kraken2").
    ///   - arguments: Command-line arguments to pass to the tool.
    ///   - environment: The conda environment name containing the tool.
    ///   - workingDirectory: Optional working directory for the process.
    ///   - timeout: Maximum execution time in seconds (default: 3600).
    ///   - stderrHandler: Optional callback that receives stderr lines in
    ///     real-time as they are written by the subprocess. Useful for parsing
    ///     progress output from tools like kraken2 that report progress to
    ///     stderr. The full stderr is still accumulated and returned in the
    ///     result tuple regardless of whether this handler is set.
    /// - Returns: A tuple of (stdout, stderr, exitCode).
    /// - Throws: ``CondaError`` on tool-not-found, timeout, or launch failure.
    public func runTool(
        name: String,
        arguments: [String] = [],
        environment: String,
        workingDirectory: URL? = nil,
        environmentVariables: [String: String]? = nil,
        timeout: TimeInterval = 3600,
        stderrHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await ensureMicromamba()

        let args = ["run", "-n", environment, name] + arguments
        logger.info("Running conda tool: micromamba \(args.joined(separator: " "), privacy: .public)")

        let executablePath = micromambaPath
        let rootPath = rootPrefix.path

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executablePath
            process.arguments = args
            var env: [String: String] = [
                "MAMBA_ROOT_PREFIX": rootPath,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            if let extraVars = environmentVariables {
                env.merge(extraVars) { _, new in new }
            }
            process.environment = env
            if let wd = workingDirectory {
                process.currentDirectoryURL = wd
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Use nonisolated(unsafe) for mutable buffers accessed from
            // readabilityHandler callbacks and the termination handler.
            // These closures are serialized by Process: readabilityHandler
            // fires on the pipe's dispatch source queue, and the termination
            // handler fires after the process exits (after all pipe data has
            // been written). The asyncAfter delay ensures all pending
            // readabilityHandler calls have drained before we read the buffers.
            nonisolated(unsafe) let stdoutBuffer = NSMutableData()
            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                    // Forward lines to the stderrHandler if provided.
                    if let handler = stderrHandler,
                       let text = String(data: data, encoding: .utf8) {
                        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                            handler(String(line))
                        }
                    }
                }
            }

            // Timeout timer: terminates the process if it runs too long.
            // nonisolated(unsafe) because DispatchWorkItem is not Sendable,
            // but we only cancel it from the terminationHandler or catch
            // block, never concurrently with its execution.
            nonisolated(unsafe) let timeoutItem = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                logger.warning("Tool '\(name, privacy: .public)' timed out after \(Int(timeout))s, terminating")
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )

            process.terminationHandler = { terminatedProcess in
                // Cancel the timeout timer since the process finished.
                timeoutItem.cancel()

                // Small delay to let any remaining readabilityHandler
                // callbacks drain before we read the final buffer contents.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    // Nil out handlers to break retain cycles.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    let stdout = String(data: stdoutBuffer as Data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer as Data, encoding: .utf8) ?? ""

                    // Check if this was a timeout (SIGTERM = exit 15 or 143).
                    if terminatedProcess.terminationReason == .uncaughtSignal
                        && (terminatedProcess.terminationStatus == 15
                            || terminatedProcess.terminationStatus == 143) {
                        continuation.resume(
                            throwing: CondaError.timeout(tool: name, seconds: timeout)
                        )
                    } else {
                        continuation.resume(
                            returning: (stdout, stderr, terminatedProcess.terminationStatus)
                        )
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Nextflow Integration

    /// Returns environment variables for Nextflow conda integration.
    public func nextflowCondaConfig() -> [String: String] {
        [
            "NXF_CONDA_CACHEDIR": rootPrefix.appendingPathComponent("envs").path,
            "NXF_CONDA_ENABLED": "true",
            "MAMBA_ROOT_PREFIX": rootPrefix.path,
        ]
    }

    /// Generates a Nextflow config snippet for conda profile.
    public func nextflowCondaConfigString() -> String {
        """
        conda {
            enabled = true
            useMicromamba = true
            cacheDir = '\(rootPrefix.appendingPathComponent("envs").path)'
        }

        env {
            MAMBA_ROOT_PREFIX = '\(rootPrefix.path)'
            PATH = '\(rootPrefix.appendingPathComponent("bin").path):$PATH'
        }
        """
    }

    // MARK: - Private Helpers

    /// Runs micromamba with the given arguments and returns stdout.
    ///
    /// Pipe reading is performed concurrently with the subprocess using
    /// `readabilityHandler` to avoid deadlocks when micromamba produces
    /// more than 64 KB of output (e.g. environment creation with many
    /// packages). The actor thread is never blocked.
    private func runMicromamba(_ arguments: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: micromambaPath.path) else {
            throw CondaError.micromambaNotFound
        }

        let executablePath = micromambaPath
        let rootPath = rootPrefix.path

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executablePath
            process.arguments = arguments
            process.environment = [
                "MAMBA_ROOT_PREFIX": rootPath,
                "MAMBA_NO_BANNER": "1",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            nonisolated(unsafe) let stdoutBuffer = NSMutableData()
            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { terminatedProcess in
                // Small delay to let any remaining readabilityHandler
                // callbacks drain before we read the final buffer contents.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    let stdout = String(data: stdoutBuffer as Data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer as Data, encoding: .utf8) ?? ""

                    if terminatedProcess.terminationStatus != 0 {
                        logger.error("micromamba failed (exit \(terminatedProcess.terminationStatus)): \(stderr, privacy: .public)")
                        continuation.resume(
                            throwing: CondaError.packageInstallFailed(stderr.isEmpty ? stdout : stderr)
                        )
                    } else {
                        continuation.resume(returning: stdout)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
