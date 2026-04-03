// ExtractReadsCommand.swift - CLI command for universal read extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Resolves the `ExtractionResult` ambiguity between LungfishWorkflow and LungfishCore.
private typealias ReadExtractionResult = LungfishWorkflow.ExtractionResult

/// Extract reads from FASTQ, BAM, or database sources using one of three strategies.
///
/// Supports three mutually exclusive extraction modes:
///
/// - **By read IDs** (`--by-id`): Extracts reads from FASTQ files by matching read IDs
///   listed in a text file. Supports paired-end data.
/// - **By BAM region** (`--by-region`): Extracts reads from a sorted, indexed BAM file
///   for one or more genomic regions.
/// - **By database query** (`--by-db`): Extracts reads stored in an NAO-MGS SQLite
///   database, filtered by taxonomy ID and/or accession.
///
/// ## Examples
///
/// ```
/// # Extract by read IDs
/// lungfish extract reads --by-id --ids read_ids.txt --source input.fastq -o output.fastq
///
/// # Extract by BAM region
/// lungfish extract reads --by-region --bam aligned.bam --region NC_005831.2 -o output.fastq
///
/// # Extract from database
/// lungfish extract reads --by-db --database results.db --sample S1 --taxid 12345 -o output.fastq
/// ```
struct ExtractReadsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Extract reads from FASTQ, BAM, or database sources",
        discussion: """
        Extract reads using one of three strategies. Exactly one of --by-id,
        --by-region, or --by-db must be specified.

        By Read IDs (--by-id):
          Extracts reads from FASTQ files matching read IDs in a text file.
          Use --source (repeatable) for paired-end inputs and --keep-read-pairs
          to include both mates when either matches.

        By BAM Region (--by-region):
          Extracts reads from a sorted, indexed BAM file for one or more
          genomic regions. Requires samtools.

        By Database (--by-db):
          Queries an NAO-MGS SQLite database for reads matching taxonomy IDs
          and/or accessions. No external tools required.
        """
    )

    // MARK: - Strategy Flags (mutually exclusive)

    @Flag(name: .customLong("by-id"), help: "Extract reads by read ID from FASTQ files")
    var byId: Bool = false

    @Flag(name: .customLong("by-region"), help: "Extract reads by genomic region from a BAM file")
    var byRegion: Bool = false

    @Flag(name: .customLong("by-db"), help: "Extract reads from an NAO-MGS SQLite database")
    var byDb: Bool = false

    // MARK: - By-ID Options

    @Option(name: .customLong("ids"), help: "Path to read ID file (one ID per line, for --by-id)")
    var idsFile: String?

    @Option(name: .customLong("source"), help: "Source FASTQ file(s). Repeat for paired-end. (for --by-id)")
    var sourceFiles: [String] = []

    @Flag(name: .customLong("keep-read-pairs"), help: "Include both mates when either matches (for --by-id)")
    var keepReadPairs: Bool = false

    @Flag(name: .customLong("no-keep-read-pairs"), help: "Extract only exact read IDs without pairing (for --by-id)")
    var noKeepReadPairs: Bool = false

    // MARK: - By-Region Options

    @Option(name: .customLong("bam"), help: "BAM file path (for --by-region)")
    var bamFile: String?

    @Option(name: .customLong("region"), help: "Genomic region to extract (repeatable, for --by-region)")
    var regions: [String] = []

    // MARK: - By-DB Options

    @Option(name: .customLong("database"), help: "SQLite database path (for --by-db)")
    var databaseFile: String?

    @Option(name: .customLong("sample"), help: "Sample ID (for --by-db)")
    var sample: String?

    @Option(name: .customLong("taxid"), help: "Taxonomy ID (repeatable, for --by-db)")
    var taxIds: [String] = []

    @Option(name: .customLong("accession"), help: "Accession filter (repeatable, for --by-db)")
    var accessions: [String] = []

    @Option(name: .customLong("max-reads"), help: "Maximum reads to extract (for --by-db)")
    var maxReads: Int?

    // MARK: - Common Options

    @Option(name: .shortAndLong, help: "Output FASTQ file path")
    var output: String

    @Flag(name: .customLong("bundle"), help: "Wrap output in a .lungfishfastq bundle")
    var createBundle: Bool = false

    @Option(name: .customLong("bundle-name"), help: "Custom bundle display name (implies --bundle)")
    var bundleName: String?

    @OptionGroup var globalOptions: GlobalOptions

    // MARK: - Validation

    func validate() throws {
        // Exactly one strategy must be selected
        let strategyCount = [byId, byRegion, byDb].filter { $0 }.count
        guard strategyCount == 1 else {
            throw ValidationError("Exactly one of --by-id, --by-region, or --by-db must be specified")
        }

        if byId {
            guard idsFile != nil else {
                throw ValidationError("--ids is required with --by-id")
            }
            guard !sourceFiles.isEmpty else {
                throw ValidationError("At least one --source file is required with --by-id")
            }
            if keepReadPairs && noKeepReadPairs {
                throw ValidationError("--keep-read-pairs and --no-keep-read-pairs are mutually exclusive")
            }
        }

        if byRegion {
            guard bamFile != nil else {
                throw ValidationError("--bam is required with --by-region")
            }
            guard !regions.isEmpty else {
                throw ValidationError("At least one --region is required with --by-region")
            }
        }

        if byDb {
            guard databaseFile != nil else {
                throw ValidationError("--database is required with --by-db")
            }
            guard !taxIds.isEmpty || !accessions.isEmpty else {
                throw ValidationError("At least one --taxid or --accession is required with --by-db")
            }
        }
    }

    // MARK: - Execution

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let fm = FileManager.default
        let service = ReadExtractionService()

        let outputURL = URL(fileURLWithPath: output)
        let outputDir = outputURL.deletingLastPathComponent()
        let outputBase = outputURL.deletingPathExtension().lastPathComponent

        // Create output directory if needed
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let result: ReadExtractionResult

        if byId {
            result = try await runByReadID(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase
            )
        } else if byRegion {
            result = try await runByBAMRegion(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase
            )
        } else {
            result = try await runByDatabase(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase
            )
        }

        // Bundle wrapping
        if createBundle || bundleName != nil {
            let metadata = ExtractionMetadata(
                sourceDescription: bundleName ?? outputBase,
                toolName: strategyLabel,
                parameters: strategyParameters
            )

            let bundleURL = try await service.createBundle(
                from: result,
                metadata: metadata,
                in: outputDir
            )

            print("")
            print(formatter.success("Created bundle: \(bundleURL.lastPathComponent)"))
        }

        // Print summary
        print("")
        print(formatter.header("Extraction Summary"))
        print(formatter.keyValueTable([
            ("Strategy", strategyLabel),
            ("Reads extracted", "\(result.readCount)"),
            ("Paired-end", result.pairedEnd ? "yes" : "no"),
            ("Output files", result.fastqURLs.map { $0.lastPathComponent }.joined(separator: ", ")),
        ]))
        for url in result.fastqURLs {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            print("  \(formatter.path(url.path)) (\(formatReadsBytes(size)))")
        }
        print("")
        print(formatter.success("Extraction complete"))
    }

    // MARK: - Strategy Implementations

    private func runByReadID(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        // Read the IDs file
        let idsURL = URL(fileURLWithPath: idsFile!)
        guard fm.fileExists(atPath: idsURL.path) else {
            print(formatter.error("Read ID file not found: \(idsFile!)"))
            throw ExitCode.failure
        }
        let idsContent = try String(contentsOf: idsURL, encoding: .utf8)
        let readIDs = Set(
            idsContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        guard !readIDs.isEmpty else {
            print(formatter.error("Read ID file is empty"))
            throw ExitCode.failure
        }

        // Validate source files
        let sourceURLs = sourceFiles.map { URL(fileURLWithPath: $0) }
        for url in sourceURLs {
            guard fm.fileExists(atPath: url.path) else {
                print(formatter.error("Source file not found: \(url.path)"))
                throw ExitCode.failure
            }
        }

        let shouldKeepPairs = keepReadPairs || (!noKeepReadPairs && sourceURLs.count > 1)

        let config = ReadIDExtractionConfig(
            sourceFASTQs: sourceURLs,
            readIDs: readIDs,
            keepReadPairs: shouldKeepPairs,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        print(formatter.header("Read ID Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("Source files", sourceURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Read IDs", "\(readIDs.count)"),
            ("Keep read pairs", shouldKeepPairs ? "yes" : "no"),
        ]))
        print("")

        return try await service.extractByReadIDs(config: config) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
    }

    private func runByBAMRegion(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let bamURL = URL(fileURLWithPath: bamFile!)
        guard fm.fileExists(atPath: bamURL.path) else {
            print(formatter.error("BAM file not found: \(bamFile!)"))
            throw ExitCode.failure
        }

        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: regions,
            fallbackToAll: false,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        print(formatter.header("BAM Region Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("BAM file", bamURL.lastPathComponent),
            ("Regions", regions.joined(separator: ", ")),
        ]))
        print("")

        return try await service.extractByBAMRegion(config: config) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
    }

    private func runByDatabase(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let dbURL = URL(fileURLWithPath: databaseFile!)
        guard fm.fileExists(atPath: dbURL.path) else {
            print(formatter.error("Database file not found: \(databaseFile!)"))
            throw ExitCode.failure
        }

        // Parse tax IDs
        let parsedTaxIds: Set<Int> = Set(taxIds.flatMap { arg in
            arg.split(separator: ",").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
        })

        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: sample,
            taxIds: parsedTaxIds,
            accessions: Set(accessions),
            maxReads: maxReads,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        print(formatter.header("Database Extraction"))
        print("")
        var tableRows: [(String, String)] = [
            ("Database", dbURL.lastPathComponent),
        ]
        if let s = sample { tableRows.append(("Sample", s)) }
        if !parsedTaxIds.isEmpty {
            tableRows.append(("Tax IDs", parsedTaxIds.sorted().map(String.init).joined(separator: ", ")))
        }
        if !accessions.isEmpty {
            tableRows.append(("Accessions", accessions.joined(separator: ", ")))
        }
        if let max = maxReads {
            tableRows.append(("Max reads", "\(max)"))
        }
        print(formatter.keyValueTable(tableRows))
        print("")

        return try await service.extractFromDatabase(config: config) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
    }

    // MARK: - Helpers

    private var strategyLabel: String {
        if byId { return "Read ID" }
        if byRegion { return "BAM Region" }
        return "Database"
    }

    private var strategyParameters: [String: String] {
        var params: [String: String] = ["strategy": strategyLabel]
        if byId {
            params["idsFile"] = idsFile
            params["sources"] = sourceFiles.joined(separator: ", ")
        } else if byRegion {
            params["bamFile"] = bamFile
            params["regions"] = regions.joined(separator: ", ")
        } else {
            params["database"] = databaseFile
            if let s = sample { params["sample"] = s }
            if !taxIds.isEmpty { params["taxIds"] = taxIds.joined(separator: ", ") }
            if !accessions.isEmpty { params["accessions"] = accessions.joined(separator: ", ") }
        }
        return params
    }
}

// MARK: - Formatting Helper

/// Formats a byte count as a human-readable string.
///
/// Module-level free function to avoid `@MainActor` isolation issues in
/// `@Sendable` closures per the project convention in MEMORY.md.
private func formatReadsBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}
