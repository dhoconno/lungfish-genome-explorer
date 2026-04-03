// CondaExtractCommand.swift - CLI command for taxonomy-based read extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Extract reads by taxonomy from a Kraken2 classification output.
///
/// Filters FASTQ reads classified to specific taxa, using the per-read
/// Kraken2 output file to determine which reads match. Supports both
/// single-end and paired-end inputs.
///
/// ## Examples
///
/// ```
/// # Extract E. coli reads
/// lungfish conda extract --kraken-output class.kraken --source reads.fastq \
///     --taxid 562 --output ecoli.fastq
///
/// # Extract a clade (include children) with a kreport for tree building
/// lungfish conda extract --kraken-output class.kraken --source reads.fastq \
///     --taxid 1224 --include-children --kreport class.kreport --output proteo.fastq
///
/// # Paired-end extraction
/// lungfish conda extract --kraken-output class.kraken \
///     --source R1.fastq --source R2.fastq \
///     --taxid 562 --output R1_ecoli.fastq --output R2_ecoli.fastq
/// ```
struct ExtractSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Extract reads by taxonomy from Kraken2 classification output",
        discussion: """
        Filter FASTQ reads that were classified to specific taxa by Kraken2.
        Requires the per-read output file (--output from kraken2) and the
        source FASTQ(s). When --include-children is set, a kreport file is
        needed to build the taxonomy tree for descendant lookup.
        """
    )

    // MARK: - Options

    @Option(name: .customLong("kraken-output"), help: "Kraken2 per-read output file (.kraken)")
    var krakenOutput: String

    @Option(name: .customLong("source"), help: "Source FASTQ file(s). Repeat for paired-end.")
    var sourceFiles: [String]

    @Option(name: .customLong("output"), help: "Output FASTQ file(s). Must match source count.")
    var outputFiles: [String]

    @Option(name: .customLong("taxid"), help: "Taxonomy ID(s) to extract (comma-separated or repeated)")
    var taxIds: [String]

    @Flag(name: .customLong("include-children"), help: "Include reads classified to descendant taxa")
    var includeChildren: Bool = false

    @Option(name: .customLong("kreport"), help: "Kreport file for taxonomy tree (required with --include-children)")
    var kreportFile: String?

    @Flag(name: .customLong("no-read-pairs"), help: "Extract only exact read IDs (don't pair /1 and /2 mates)")
    var noReadPairs: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    // MARK: - Validation

    func validate() throws {
        guard !sourceFiles.isEmpty else {
            throw ValidationError("At least one --source file is required")
        }
        guard sourceFiles.count == outputFiles.count else {
            throw ValidationError("Number of --source files (\(sourceFiles.count)) must match --output files (\(outputFiles.count))")
        }
        guard !taxIds.isEmpty else {
            throw ValidationError("At least one --taxid is required")
        }
        if includeChildren && kreportFile == nil {
            throw ValidationError("--kreport is required when using --include-children")
        }
    }

    // MARK: - Execution

    func run() async throws {
        FileHandle.standardError.write(Data("WARNING: 'lungfish conda extract' is deprecated. Use 'lungfish extract reads --by-id' instead.\n".utf8))

        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Parse tax IDs (support both comma-separated and repeated flags)
        let parsedTaxIds: Set<Int> = Set(taxIds.flatMap { arg in
            arg.split(separator: ",").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
        })

        guard !parsedTaxIds.isEmpty else {
            print(formatter.error("No valid taxonomy IDs provided"))
            throw ExitCode.failure
        }

        // Resolve file paths
        let sourceURLs = sourceFiles.map { URL(fileURLWithPath: $0) }
        let outputURLs = outputFiles.map { URL(fileURLWithPath: $0) }
        let krakenOutputURL = URL(fileURLWithPath: krakenOutput)

        // Verify source files exist
        let fm = FileManager.default
        for url in sourceURLs {
            guard fm.fileExists(atPath: url.path) else {
                print(formatter.error("Source file not found: \(url.path)"))
                throw ExitCode.failure
            }
        }
        guard fm.fileExists(atPath: krakenOutputURL.path) else {
            print(formatter.error("Kraken output file not found: \(krakenOutput)"))
            throw ExitCode.failure
        }

        // Build taxonomy tree if needed for descendant lookup
        let tree: TaxonTree
        if includeChildren, let kreport = kreportFile {
            let kreportURL = URL(fileURLWithPath: kreport)
            guard fm.fileExists(atPath: kreportURL.path) else {
                print(formatter.error("Kreport file not found: \(kreport)"))
                throw ExitCode.failure
            }
            tree = try KreportParser.parse(url: kreportURL)
        } else {
            // Create a minimal empty tree -- not needed without include-children
            tree = TaxonTree(root: TaxonNode(
                taxId: 1, name: "root", rank: .root, depth: 0,
                readsDirect: 0, readsClade: 0,
                fractionClade: 0, fractionDirect: 0, parentTaxId: nil
            ), unclassifiedNode: nil, totalReads: 0)
        }

        // Build config
        let config = TaxonomyExtractionConfig(
            taxIds: parsedTaxIds,
            includeChildren: includeChildren,
            sourceFiles: sourceURLs,
            outputFiles: outputURLs,
            classificationOutput: krakenOutputURL,
            keepReadPairs: !noReadPairs
        )

        // Print configuration
        print(formatter.header("Taxonomy Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("Source files", sourceURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Output files", outputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Tax IDs", parsedTaxIds.sorted().map(String.init).joined(separator: ", ")),
            ("Include children", includeChildren ? "yes" : "no"),
            ("Keep read pairs", config.keepReadPairs ? "yes" : "no"),
            ("Kraken output", krakenOutputURL.lastPathComponent),
        ]))
        print("")

        // Run extraction
        let pipeline = TaxonomyExtractionPipeline()
        let results: [URL] = try await pipeline.extract(
            config: config,
            tree: tree
        ) { fraction, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }

        print("")
        print("")

        // Print results
        print(formatter.header("Output Files"))
        for url in results {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let sizeStr = formatExtractBytes(size)
            print("  \(formatter.path(url.path)) (\(sizeStr))")
        }
        print("")
        print(formatter.success("Extraction complete"))
    }
}

// MARK: - Formatting Helper

/// Formats a byte count as a human-readable string.
///
/// Module-level free function to avoid `@MainActor` isolation issues in
/// `@Sendable` closures per the project convention in MEMORY.md.
private func formatExtractBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}
