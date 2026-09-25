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
    /// 3. Draws a seeded, unbiased random sample of those fragments and, for
    ///    paired reads, reads the mate whose k-mers hit the taxon from the
    ///    source FASTQ (plain or gzip)
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

        @Option(
            name: .customLong("seed"),
            help: "Random seed for choosing which fragments to submit (default: 0)"
        )
        var seed: UInt64 = 0

        @Option(
            name: .customLong("max-concurrent"),
            help: "Maximum in-flight BLAST submissions for this process (default: 1)"
        )
        var maxConcurrent: Int = 1

        @Flag(name: .customLong("include-children"), help: "Include reads classified to descendant taxa")
        var includeChildren: Bool = false

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional BLAST URL API parameters as KEY=VALUE tokens (for example WORD_SIZE=11)"
        )
        var extraArgs: String = ""

        @OptionGroup var globalOptions: GlobalOptions

        // MARK: - Validation

        func validate() throws {
            guard readCount >= 1, readCount <= 100 else {
                throw ValidationError("--reads must be between 1 and 100")
            }
            guard maxConcurrent >= 1 else {
                throw ValidationError("--max-concurrent must be at least 1")
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
                throw CLIExitCode.inputError.exitCode
            }
            guard fm.fileExists(atPath: sourceURL.path) else {
                print(formatter.error("Source FASTQ not found: \(sourceFile)"))
                throw CLIExitCode.inputError.exitCode
            }
            guard fm.fileExists(atPath: krakenOutputURL.path) else {
                print(formatter.error("Kraken output not found: \(krakenOutput)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Phase 1: Parse kreport and find the target taxon
            if !globalOptions.quiet && globalOptions.outputFormat != .json {
                print(formatter.header("BLAST Verification"))
                print("")
            }

            let tree = try KreportParser.parse(url: kreportURL)

            guard let targetNode = tree.node(taxId: taxId) else {
                print(formatter.error("Taxon ID \(taxId) not found in kreport"))
                throw CLIExitCode.inputError.exitCode
            }

            if !globalOptions.quiet && globalOptions.outputFormat != .json {
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

            // Phase 3-5: Scan the Kraken output, draw an unbiased seeded
            // sample of fragments, and for each paired fragment pick the mate
            // whose k-mers carry the taxon's evidence. This is the same code
            // path the app's BLAST Verify button uses.
            let jsonOutput = globalOptions.outputFormat == .json
            let chatty = !globalOptions.quiet && !jsonOutput
            if chatty {
                print(formatter.info("Sampling \(readCount) fragments classified to the target taxa..."))
            }

            let acceptedNames = targetTaxIds.compactMap { tree.node(taxId: $0)?.name }.sorted()
            let service = BlastService.shared
            let built: BlastVerificationRequest
            do {
                built = try await service.buildVerificationRequest(
                    taxonName: targetNode.name,
                    taxId: taxId,
                    targetTaxIds: targetTaxIds,
                    classificationOutputURL: krakenOutputURL,
                    sourceURL: sourceURL,
                    readCount: readCount,
                    acceptedTaxonNames: acceptedNames,
                    seed: seed
                )
            } catch BlastServiceError.noSequences {
                print(formatter.warning("No reads for taxon \(taxId) could be read from the classification output and source FASTQ"))
                throw CLIExitCode.inputError.exitCode
            }

            if chatty {
                let mate2 = built.sequenceMates.values.filter { $0 == 2 }.count
                print(formatter.info("Selected \(built.sequences.count) reads (\(mate2) submitted as mate 2)"))
            }

            // Phase 6: Submit to BLAST
            if chatty {
                print(formatter.info("Submitting to NCBI BLAST..."))
                print("")
            }

            let request = BlastVerificationRequest(
                taxonName: built.taxonName,
                taxId: built.taxId,
                sequences: built.sequences,
                extraArgs: extraArgs,
                maxConcurrentSubmissions: maxConcurrent,
                sequenceMates: built.sequenceMates,
                acceptedTaxIds: built.acceptedTaxIds,
                acceptedTaxonNames: built.acceptedTaxonNames
            )
            _ = request.blastURLAPIExtraParameters

            let result = try await service.verify(
                request: request
            ) { fraction, message in
                if chatty {
                    print("\r\(formatter.info(message))", terminator: "")
                    fflush(stdout)
                }
            }

            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let summary = BlastVerifyCLISummary(result: result)
                let data = try encoder.encode(summary)
                print(String(decoding: data, as: UTF8.self))
                return
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

        func makeVerificationRequestForTesting(
            taxonName: String,
            sequences: [(id: String, sequence: String)]
        ) throws -> BlastVerificationRequest {
            BlastVerificationRequest(
                taxonName: taxonName,
                taxId: taxId,
                sequences: sequences,
                extraArgs: extraArgs,
                maxConcurrentSubmissions: maxConcurrent
            )
        }

        func extraParametersForTesting() throws -> [String: String] {
            try BlastVerificationRequest.parseBlastURLAPIExtraParameters(extraArgs)
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
func blastScanKrakenOutput(
    url: URL,
    targetTaxIds: Set<Int>
) throws -> Set<String> {
    let stream = try blastOpenKrakenOutputStream(url: url)
    let fileHandle = stream.fileHandle

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

    try stream.finish()
    return matchingReadIds
}

private struct BlastKrakenOutputStream {
    let fileHandle: FileHandle
    let process: Process?
    let stderr: Pipe?

    func finish() throws {
        fileHandle.closeFile()
        guard let process else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrText = stderr.map {
                String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } ?? ""
            throw CLIError.conversionFailed(
                reason: "Failed to decompress Kraken output: \(stderrText)"
            )
        }
    }
}

private func blastOpenKrakenOutputStream(url: URL) throws -> BlastKrakenOutputStream {
    if url.pathExtension.lowercased() == "gz" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return BlastKrakenOutputStream(
            fileHandle: stdout.fileHandleForReading,
            process: process,
            stderr: stderr
        )
    }

    guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
        throw CLIError.inputFileNotFound(path: url.path)
    }
    return BlastKrakenOutputStream(fileHandle: fileHandle, process: nil, stderr: nil)
}

/// JSON shape printed by `lungfish blast verify --format json`.
///
/// Carries the summary counts the text output shows plus the full per-read
/// results, including which mate of each paired fragment was submitted.
struct BlastVerifyCLISummary: Encodable {
    let taxonName: String
    let taxId: Int
    let totalReads: Int
    let supporting: Int
    let contradicting: Int
    let inconclusive: Int
    let verified: Int
    let ambiguous: Int
    let unverified: Int
    let errors: Int
    let confidence: String
    let rid: String
    let program: String
    let database: String
    let readResults: [BlastReadResult]

    init(result: BlastVerificationResult) {
        taxonName = result.taxonName
        taxId = result.taxId
        totalReads = result.totalReads
        supporting = result.supportingCount
        contradicting = result.contradictingCount
        inconclusive = result.inconclusiveCount
        verified = result.verifiedCount
        ambiguous = result.ambiguousCount
        unverified = result.unverifiedCount
        errors = result.errorCount
        confidence = result.confidence.rawValue
        rid = result.rid
        program = result.blastProgram
        database = result.database
        readResults = result.readResults
    }
}
