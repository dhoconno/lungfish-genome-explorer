// BlastCommand.swift - CLI command for BLAST verification of classified reads
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Parent command grouping BLAST-related subcommands.
///
/// Currently contains a single `verify` subcommand that submits classified
/// reads to NCBI BLAST for independent verification of Kraken2 assignments.
///
/// ## Examples
///
/// ```
/// lungfish blast verify --kreport class.kreport --source reads.fastq \
///     --kraken-output class.kraken --taxid 562
///
/// lungfish blast verify --kreport class.kreport --source reads.fastq \
///     --kraken-output class.kraken --taxid 562 --reads 30
/// ```
struct BlastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blast",
        abstract: "BLAST verification of classified reads",
        discussion: """
        Submit classified reads to NCBI BLAST for independent verification.
        This cross-checks Kraken2 taxonomic assignments against the NCBI
        nucleotide database.
        """,
        subcommands: [
            VerifySubcommand.self,
        ],
        defaultSubcommand: VerifySubcommand.self
    )
}

// MARK: - VerifySubcommand

extension BlastCommand {

    /// Verify a taxon's classification by BLASTing matching reads against NCBI.
    ///
    /// This subcommand:
    /// 1. Parses the kreport to build a taxonomy tree
    /// 2. Scans the Kraken2 per-read output for reads classified to the target taxon
    /// 3. Subsamples reads from the source FASTQ
    /// 4. Submits the subsample to NCBI BLAST
    /// 5. Waits for results and prints a verification summary
    ///
    /// ## Examples
    ///
    /// ```
    /// # Verify E. coli classification with default 20 reads
    /// lungfish blast verify --kreport class.kreport --source reads.fastq \
    ///     --kraken-output class.kraken --taxid 562
    ///
    /// # Verify with 30 reads
    /// lungfish blast verify --kreport class.kreport --source reads.fastq \
    ///     --kraken-output class.kraken --taxid 562 --reads 30
    /// ```
    struct VerifySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Verify a taxon classification via NCBI BLAST",
            discussion: """
            Submit a subsample of reads classified to the target taxon to NCBI
            BLAST and report how many are independently verified. Requires the
            kreport file (for tree building), the per-read Kraken2 output (for
            read ID extraction), and the source FASTQ (for sequence retrieval).
            """
        )

        // MARK: - Options

        @Option(name: .customLong("kreport"), help: "Kraken2 report file (.kreport)")
        var kreportFile: String

        @Option(name: .customLong("source"), help: "Source FASTQ file")
        var sourceFile: String

        @Option(name: .customLong("kraken-output"), help: "Kraken2 per-read output file (.kraken)")
        var krakenOutput: String

        @Option(name: .customLong("taxid"), help: "Taxonomy ID to verify")
        var taxId: Int

        @Option(name: .customLong("reads"), help: "Number of reads to submit (default: 20)")
        var readCount: Int = 20

        @Flag(name: .customLong("include-children"), help: "Include reads classified to descendant taxa")
        var includeChildren: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        // MARK: - Validation

        func validate() throws {
            guard readCount >= 1, readCount <= 100 else {
                throw ValidationError("--reads must be between 1 and 100")
            }
        }

        // MARK: - Execution

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let fm = FileManager.default

            // Resolve file paths
            let kreportURL = URL(fileURLWithPath: kreportFile)
            let sourceURL = URL(fileURLWithPath: sourceFile)
            let krakenOutputURL = URL(fileURLWithPath: krakenOutput)

            // Verify files exist
            guard fm.fileExists(atPath: kreportURL.path) else {
                print(formatter.error("Kreport file not found: \(kreportFile)"))
                throw ExitCode.failure
            }
            guard fm.fileExists(atPath: sourceURL.path) else {
                print(formatter.error("Source FASTQ not found: \(sourceFile)"))
                throw ExitCode.failure
            }
            guard fm.fileExists(atPath: krakenOutputURL.path) else {
                print(formatter.error("Kraken output not found: \(krakenOutput)"))
                throw ExitCode.failure
            }

            // Phase 1: Parse kreport and find the target taxon
            if !globalOptions.quiet {
                print(formatter.header("BLAST Verification"))
                print("")
            }

            let tree = try KreportParser.parse(url: kreportURL)

            guard let targetNode = tree.node(taxId: taxId) else {
                print(formatter.error("Taxon ID \(taxId) not found in kreport"))
                throw ExitCode.failure
            }

            if !globalOptions.quiet {
                print(formatter.keyValueTable([
                    ("Taxon", "\(targetNode.name) (txid\(taxId))"),
                    ("Rank", targetNode.rank.displayName),
                    ("Clade reads", "\(targetNode.readsClade)"),
                    ("Source FASTQ", sourceURL.lastPathComponent),
                    ("Reads to submit", "\(readCount)"),
                    ("Include children", includeChildren ? "yes" : "no"),
                ]))
                print("")
            }

            // Phase 2: Collect target tax IDs
            let targetTaxIds: Set<Int>
            if includeChildren {
                targetTaxIds = blastCollectDescendantTaxIds(Set([taxId]), tree: tree)
            } else {
                targetTaxIds = Set([taxId])
            }

            // Phase 3: Scan kraken output for matching read IDs
            if !globalOptions.quiet {
                print(formatter.info("Scanning classification output for matching reads..."))
            }

            let matchingReadIds = try blastScanKrakenOutput(
                url: krakenOutputURL,
                targetTaxIds: targetTaxIds
            )

            guard !matchingReadIds.isEmpty else {
                print(formatter.warning("No reads found for taxon \(taxId) in classification output"))
                throw ExitCode.failure
            }

            if !globalOptions.quiet {
                print(formatter.info("Found \(matchingReadIds.count) matching reads"))
            }

            // Phase 4: Extract sequences from FASTQ
            if !globalOptions.quiet {
                print(formatter.info("Extracting sequences from FASTQ..."))
            }

            let allReads = try blastExtractSequences(
                from: sourceURL,
                matchingIds: matchingReadIds
            )

            guard !allReads.isEmpty else {
                print(formatter.warning("No matching reads found in source FASTQ"))
                throw ExitCode.failure
            }

            // Phase 5: Subsample
            let strategy: SubsampleStrategy
            if readCount <= 10 {
                strategy = .longestFirst(count: readCount)
            } else {
                let longestCount = max(3, readCount / 4)
                strategy = .mixed(longest: longestCount, random: readCount - longestCount)
            }

            let subsampled = BlastService.shared.subsampleReads(
                from: allReads,
                strategy: strategy
            )

            if !globalOptions.quiet {
                print(formatter.info("Subsampled \(subsampled.count) reads (\(allReads.count) available)"))
            }

            // Phase 6: Submit to BLAST
            if !globalOptions.quiet {
                print(formatter.info("Submitting to NCBI BLAST..."))
                print("")
            }

            let request = BlastVerificationRequest(
                taxonName: targetNode.name,
                taxId: taxId,
                sequences: subsampled
            )

            let result = try await BlastService.shared.verify(
                request: request
            ) { fraction, message in
                if !globalOptions.quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                    fflush(stdout)
                }
            }

            // Phase 7: Print results

            print("")
            print("")
            print(formatter.header("Verification Results"))
            print("")
            print(formatter.keyValueTable([
                ("Taxon", "\(result.taxonName) (txid\(result.taxId))"),
                ("Supporting", "\(result.supportingCount)/\(result.totalReads) (top hit matches taxon)"),
                ("Contradicting", "\(result.contradictingCount)/\(result.totalReads) (top hit differs)"),
                ("Inconclusive", "\(result.inconclusiveCount) (no significant hit)"),
                ("Ambiguous", "\(result.ambiguousCount)"),
                ("Unverified", "\(result.unverifiedCount)"),
                ("Errors", "\(result.errorCount)"),
                ("Confidence", result.confidence.rawValue.capitalized),
                ("BLAST RID", result.rid),
                ("Program", result.blastProgram),
                ("Database", result.database),
            ]))
            print("")

            // Per-read details
            if globalOptions.effectiveVerbosity >= 1 {
                print(formatter.header("Per-Read Results"))
                print("")
                for readResult in result.readResults {
                    let verdictStr: String
                    switch readResult.verdict {
                    case .verified:
                        verdictStr = formatter.colored("PASS", .green)
                    case .ambiguous:
                        verdictStr = formatter.colored("AMBG", .yellow)
                    case .unverified:
                        verdictStr = formatter.colored("FAIL", .red)
                    case .error:
                        verdictStr = formatter.colored("ERR ", .brightBlack)
                    }

                    let organism = readResult.topHitOrganism ?? "(no hit)"
                    let identity = readResult.percentIdentity.map { String(format: "%.1f%%", $0) } ?? "--"
                    print("  \(verdictStr) \(readResult.id)  \(organism)  \(identity)")
                }
                print("")
            }

            // NCBI results URL
            if !result.rid.isEmpty {
                let ncbiURL = "https://blast.ncbi.nlm.nih.gov/Blast.cgi?CMD=Get&RID=\(result.rid)&FORMAT_TYPE=HTML"
                print(formatter.dim("View full results: \(ncbiURL)"))
            }
            print("")

            let confidenceLabel: String
            switch result.confidence {
            case .supported:    confidenceLabel = "SUPPORTED"
            case .mixed:        confidenceLabel = "MIXED"
            case .unsupported:  confidenceLabel = "UNSUPPORTED"
            case .inconclusive: confidenceLabel = "INCONCLUSIVE"
            }

            let supportInfo = "\(result.supportingCount) supporting, \(result.contradictingCount) contradicting"
            switch result.confidence {
            case .supported:
                print(formatter.success("Verification: \(confidenceLabel) (\(supportInfo))"))
            case .mixed:
                print(formatter.warning("Verification: \(confidenceLabel) (\(supportInfo))"))
            case .unsupported:
                print(formatter.colored("Verification: \(confidenceLabel) (\(supportInfo))", .red))
            case .inconclusive:
                print(formatter.dim("Verification: \(confidenceLabel) (no significant hits)"))
            }
        }
    }
}

// MARK: - Helper Functions

/// Collects all descendant taxonomy IDs for the given set of root IDs.
///
/// Performs a breadth-first traversal of the taxonomy tree starting from
/// each root node, collecting all encountered tax IDs.
///
/// Module-level free function to avoid name collisions with other modules.
///
/// - Parameters:
///   - rootIds: The starting taxonomy IDs.
///   - tree: The taxonomy tree to traverse.
/// - Returns: A set containing all root IDs and their descendants.
private func blastCollectDescendantTaxIds(_ rootIds: Set<Int>, tree: TaxonTree) -> Set<Int> {
    var result = rootIds
    var queue: [TaxonNode] = []

    for taxId in rootIds {
        if let node = tree.node(taxId: taxId) {
            queue.append(contentsOf: node.children)
        }
    }

    while !queue.isEmpty {
        let node = queue.removeFirst()
        result.insert(node.taxId)
        queue.append(contentsOf: node.children)
    }

    return result
}

/// Scans a Kraken2 per-read output file for reads classified to target taxa.
///
/// The Kraken2 output format is tab-separated with columns:
/// `C/U  readId  taxId  length  kmerHits`
///
/// Only classified reads (`C`) with a matching tax ID are included.
///
/// - Parameters:
///   - url: Path to the Kraken2 per-read output file.
///   - targetTaxIds: The set of taxonomy IDs to match.
/// - Returns: A set of matching read IDs.
/// - Throws: If the file cannot be read.
private func blastScanKrakenOutput(
    url: URL,
    targetTaxIds: Set<Int>
) throws -> Set<String> {
    guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
        throw CLIError.inputFileNotFound(path: url.path)
    }
    defer { fileHandle.closeFile() }

    var matchingReadIds = Set<String>()
    var residual = Data()
    let bufferSize = 1_048_576 // 1 MB chunks

    while true {
        let chunk = fileHandle.readData(ofLength: bufferSize)
        if chunk.isEmpty { break }

        var data = residual + chunk
        residual = Data()

        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            if lastNewline < data.endIndex - 1 {
                residual = data[(lastNewline + 1)...]
                data = data[...lastNewline]
            }
        } else if !chunk.isEmpty {
            residual = data
            continue
        }

        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard columns.count >= 3 else { continue }

                let status = columns[0].trimmingCharacters(in: .whitespaces)
                guard status == "C" else { continue }

                let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
                guard let lineTaxId = Int(taxIdStr), targetTaxIds.contains(lineTaxId) else { continue }

                var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
                if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                    readId = String(readId.dropLast(2))
                }
                matchingReadIds.insert(readId)
            }
        }
    }

    // Process remaining residual
    if !residual.isEmpty, let text = String(data: residual, encoding: .utf8) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let status = columns[0].trimmingCharacters(in: .whitespaces)
            guard status == "C" else { continue }
            let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
            guard let lineTaxId = Int(taxIdStr), targetTaxIds.contains(lineTaxId) else { continue }
            var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
            if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                readId = String(readId.dropLast(2))
            }
            matchingReadIds.insert(readId)
        }
    }

    return matchingReadIds
}

/// Extracts sequences from a FASTQ file for reads matching the given IDs.
///
/// Reads the FASTQ file in 4-line record chunks, collecting the sequence
/// line for each record whose header ID matches the set.
///
/// - Parameters:
///   - sourceURL: Path to the source FASTQ file (plain text).
///   - matchingIds: Set of read IDs to extract.
/// - Returns: Array of (id, sequence) tuples for matching reads.
/// - Throws: If the file cannot be read.
private func blastExtractSequences(
    from sourceURL: URL,
    matchingIds: Set<String>
) throws -> [(id: String, sequence: String)] {
    guard let fileHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
        throw CLIError.inputFileNotFound(path: sourceURL.path)
    }
    defer { fileHandle.closeFile() }

    var results: [(id: String, sequence: String)] = []
    var residual = ""
    let bufferSize = 4_194_304 // 4 MB chunks

    while true {
        let chunk = fileHandle.readData(ofLength: bufferSize)
        if chunk.isEmpty { break }

        guard let text = String(data: chunk, encoding: .utf8) else { continue }
        let combined = residual + text
        residual = ""

        // Split into lines, keeping the last partial line as residual
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !combined.hasSuffix("\n") {
            residual = lines.removeLast()
        }

        // Process FASTQ records (4 lines each)
        var i = 0
        while i + 3 < lines.count {
            let header = lines[i]
            let sequence = lines[i + 1]
            // lines[i + 2] is the "+" separator
            // lines[i + 3] is quality scores
            i += 4

            guard header.hasPrefix("@") else { continue }

            // Extract read ID from header: @readId optional_description
            let headerBody = header.dropFirst() // remove @
            let readId: String
            if let spaceIdx = headerBody.firstIndex(of: " ") {
                readId = String(headerBody[headerBody.startIndex..<spaceIdx])
            } else {
                readId = String(headerBody)
            }

            // Strip paired-end suffix
            var normalizedId = readId
            if normalizedId.hasSuffix("/1") || normalizedId.hasSuffix("/2") {
                normalizedId = String(normalizedId.dropLast(2))
            }

            if matchingIds.contains(normalizedId) {
                results.append((id: normalizedId, sequence: sequence))
            }
        }

        // Any unprocessed lines go to residual
        if i < lines.count {
            let remaining = lines[i...].joined(separator: "\n")
            residual = remaining + (residual.isEmpty ? "" : "\n" + residual)
        }
    }

    return results
}
