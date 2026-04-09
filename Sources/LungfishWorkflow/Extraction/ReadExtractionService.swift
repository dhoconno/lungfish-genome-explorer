// ReadExtractionService.swift - Central actor for universal read extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ReadExtractionService")

// MARK: - ReadExtractionService

/// Central actor providing three read extraction strategies and bundle creation.
///
/// Each strategy extracts reads from a different source type:
/// - **Read IDs** — extracts reads by name from FASTQ files via `seqkit grep`.
/// - **BAM region** — extracts reads from a BAM file by genomic region via `samtools`.
/// - **Database** — extracts reads stored in an NAO-MGS SQLite database.
///
/// After extraction, ``createBundle(from:sourceName:selectionDescription:metadata:in:)`` packages the output
/// into a `.lungfishfastq` bundle with provenance metadata.
///
/// ## Thread Safety
///
/// `ReadExtractionService` is an actor — all method calls are serialised and
/// safe from any isolation domain.
public actor ReadExtractionService {

    // MARK: - Properties

    private let toolRunner: NativeToolRunner

    // MARK: - Initialization

    /// Creates a new extraction service.
    ///
    /// - Parameter toolRunner: The tool runner to use for subprocess execution.
    ///   Defaults to ``NativeToolRunner/shared``.
    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    // MARK: - Extract by Read IDs

    /// Extracts reads from FASTQ files by matching read IDs via `seqkit grep`.
    ///
    /// For each source FASTQ in the config, runs `seqkit grep` with the read ID
    /// set written to a temporary file. Paired-end data produces two output files.
    ///
    /// - Parameters:
    ///   - config: Configuration specifying source FASTQs, read IDs, and output location.
    ///   - progress: Optional callback reporting progress as `(fraction, message)`.
    /// - Returns: An ``ExtractionResult`` with output FASTQ URL(s) and read count.
    /// - Throws: ``ExtractionError`` on validation failure, tool errors, or empty output.
    public func extractByReadIDs(
        config: ReadIDExtractionConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionResult {
        // Validate inputs
        guard !config.sourceFASTQs.isEmpty else {
            throw ExtractionError.noSourceFASTQ
        }
        guard !config.readIDs.isEmpty else {
            throw ExtractionError.emptyReadIDSet
        }

        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        // Write read IDs to a temporary file for seqkit grep -f
        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-extract-",
            contextURL: config.outputDirectory
        )
        defer { try? fm.removeItem(at: tempDir) }

        let readIDFile = tempDir.appendingPathComponent("read_ids.txt")
        let readIDContent = config.readIDs.sorted().joined(separator: "\n")
        try readIDContent.write(to: readIDFile, atomically: true, encoding: .utf8)

        progress?(0.1, "Wrote \(config.readIDs.count) read IDs to filter file")

        // Process each source FASTQ
        var outputURLs: [URL] = []
        let totalSources = config.sourceFASTQs.count

        for (index, sourceURL) in config.sourceFASTQs.enumerated() {
            try Task.checkCancellation()

            let suffix: String
            if totalSources == 1 {
                suffix = ""
            } else {
                suffix = "_R\(index + 1)"
            }
            let sanitizedBaseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
            let outputName = "\(sanitizedBaseName)\(suffix).fastq.gz"
            let outputURL = config.outputDirectory.appendingPathComponent(outputName)

            let baseFraction = 0.1 + 0.7 * Double(index) / Double(totalSources)
            progress?(baseFraction, "Extracting reads from \(sourceURL.lastPathComponent)...")

            let args = [
                "grep",
                "-f", readIDFile.path,
                sourceURL.path,
                "-o", outputURL.path,
                "--threads", "4"
            ]

            // Note: we do NOT use -n (match by full name) because FASTQ headers
            // often have descriptions after the ID (e.g., "@READ1 instrument:run/1").
            // The default seqkit behavior matches by ID (first whitespace-separated
            // token), which correctly matches read IDs like "SRR123.456" against
            // headers like "@SRR123.456 description/1". The keepReadPairs logic is
            // handled upstream in buildReadIdSet by stripping /1 /2 suffixes.

            let result = try await toolRunner.run(.seqkit, arguments: args, timeout: 7200)

            guard result.isSuccess else {
                throw ExtractionError.seqkitFailed(result.stderr)
            }

            // Verify the output file exists and is non-empty
            guard fm.fileExists(atPath: outputURL.path) else {
                throw ExtractionError.emptyExtraction
            }
            let attrs = try fm.attributesOfItem(atPath: outputURL.path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            if fileSize == 0 {
                throw ExtractionError.emptyExtraction
            }

            outputURLs.append(outputURL)
        }

        progress?(0.8, "Counting extracted reads...")

        // Count reads in the first output file
        let readCount = try await countReads(in: outputURLs[0])

        guard readCount > 0 else {
            throw ExtractionError.emptyExtraction
        }

        progress?(1.0, "Extracted \(readCount) reads")
        logger.info("Read ID extraction complete: \(readCount) reads from \(config.readIDs.count) IDs")

        return ExtractionResult(
            fastqURLs: outputURLs,
            readCount: readCount,
            pairedEnd: config.isPairedEnd
        )
    }

    // MARK: - Extract by BAM Region

    /// Extracts reads from a BAM file by genomic region via `samtools`.
    ///
    /// The method reads the BAM header, matches the requested regions against
    /// reference names using ``BAMRegionMatcher``, then extracts matching reads
    /// to FASTQ format.
    ///
    /// - Parameters:
    ///   - config: Configuration specifying the BAM file, regions, and output location.
    ///   - progress: Optional callback reporting progress as `(fraction, message)`.
    /// - Returns: An ``ExtractionResult`` with the output FASTQ URL and read count.
    /// - Throws: ``ExtractionError`` on validation failure, tool errors, or empty output.
    public func extractByBAMRegion(
        config: BAMRegionExtractionConfig,
        flagFilter: Int = 0x400,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionResult {
        let fm = FileManager.default

        // Validate BAM file exists
        guard fm.fileExists(atPath: config.bamURL.path) else {
            throw ExtractionError.bamFileNotFound(config.bamURL)
        }

        // Check for BAM index
        let baiPath1 = config.bamURL.path + ".bai"
        let baiPath2 = config.bamURL.deletingPathExtension().path + ".bai"
        let csiPath = config.bamURL.path + ".csi"
        let hasIndex = fm.fileExists(atPath: baiPath1)
            || fm.fileExists(atPath: baiPath2)
            || fm.fileExists(atPath: csiPath)

        guard hasIndex else {
            throw ExtractionError.bamNotIndexed(config.bamURL)
        }

        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        progress?(0.1, "Reading BAM header...")

        // Read BAM references and match regions
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: config.bamURL,
            runner: toolRunner
        )

        logger.info("BAM contains \(bamRefs.count) references: \(bamRefs.prefix(5).joined(separator: ", "))\(bamRefs.count > 5 ? "..." : "")")

        let matchResult: RegionMatchResult
        let useFallback: Bool

        if config.regions.isEmpty {
            if config.fallbackToAll {
                useFallback = true
                matchResult = RegionMatchResult(
                    matchedRegions: bamRefs,
                    unmatchedRegions: [],
                    strategy: .fallbackAll,
                    bamReferenceNames: bamRefs
                )
            } else {
                throw ExtractionError.noMatchingRegions([])
            }
        } else {
            matchResult = BAMRegionMatcher.match(
                regions: config.regions,
                againstReferences: bamRefs
            )

            switch matchResult.strategy {
            case .fallbackAll:
                if config.fallbackToAll {
                    useFallback = true
                    logger.warning("No regions matched BAM references; falling back to all reads")
                } else {
                    throw ExtractionError.noMatchingRegions(config.regions)
                }
            case .noBAM:
                throw ExtractionError.noMatchingRegions(config.regions)
            default:
                useFallback = false
                if !matchResult.unmatchedRegions.isEmpty {
                    logger.warning(
                        "Some regions did not match: \(matchResult.unmatchedRegions.joined(separator: ", "), privacy: .public)"
                    )
                }
            }
        }

        progress?(0.3, "Extracting reads from BAM...")

        let sanitizedBaseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
        let outputName = "\(sanitizedBaseName).fastq"
        let outputURL = config.outputDirectory.appendingPathComponent(outputName)

        if useFallback {
            if config.deduplicateReads {
                // Deduplicate fallback: samtools view -b -F 1024 -> temp BAM -> samtools fastq
                let fallbackTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "lungfish-bam-dedup-",
                    contextURL: config.outputDirectory
                )
                defer { try? fm.removeItem(at: fallbackTempDir) }

                let dedupBAM = fallbackTempDir.appendingPathComponent("dedup.bam")
                let dedupViewResult = try await toolRunner.run(
                    .samtools,
                    arguments: ["view", "-b", "-F", String(flagFilter), "-o", dedupBAM.path, config.bamURL.path],
                    timeout: 7200
                )
                guard dedupViewResult.isSuccess else {
                    throw ExtractionError.samtoolsFailed(dedupViewResult.stderr)
                }
                try await convertBAMToFASTQSingleFile(inputBAM: dedupBAM, outputFASTQ: outputURL)
            } else {
                // Extract all reads from source BAM.
                try await convertBAMToFASTQSingleFile(inputBAM: config.bamURL, outputFASTQ: outputURL)
            }
        } else {
            // First extract matching regions to a temporary BAM
            let tempDir = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-bam-extract-",
                contextURL: config.outputDirectory
            )
            defer { try? fm.removeItem(at: tempDir) }

            let tempBAM = tempDir.appendingPathComponent("extracted.bam")

            // samtools view -b [-F 1024] -o extracted.bam bam.bam region1 region2 ...
            var viewArgs = ["view", "-b"]
            if config.deduplicateReads {
                viewArgs.append(contentsOf: ["-F", String(flagFilter)])
            }
            viewArgs.append(contentsOf: ["-o", tempBAM.path, config.bamURL.path])
            viewArgs.append(contentsOf: matchResult.matchedRegions)

            let viewResult = try await toolRunner.run(
                .samtools,
                arguments: viewArgs,
                timeout: 7200
            )
            guard viewResult.isSuccess else {
                throw ExtractionError.samtoolsFailed(viewResult.stderr)
            }

            // Check if the intermediate BAM is empty (just a header, typically ~70 bytes).
            // This happens when the region matched a reference name but no reads aligned there.
            let tempBAMSize = (try? fm.attributesOfItem(atPath: tempBAM.path)[.size] as? Int64) ?? 0

            if tempBAMSize < 100 {
                logger.warning("Region extraction produced empty BAM (\(tempBAMSize) bytes). Trying fallback: extract all reads.")
                // Fall through to full extraction — convert all reads in the source BAM
                try await convertBAMToFASTQSingleFile(inputBAM: config.bamURL, outputFASTQ: outputURL)
            } else {
                progress?(0.6, "Converting BAM to FASTQ...")

                try await convertBAMToFASTQSingleFile(inputBAM: tempBAM, outputFASTQ: outputURL)
            }
        }

        // Verify non-empty output
        guard fm.fileExists(atPath: outputURL.path) else {
            throw ExtractionError.emptyExtraction
        }
        let attrs = try fm.attributesOfItem(atPath: outputURL.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        if fileSize == 0 {
            throw ExtractionError.emptyExtraction
        }

        progress?(0.8, "Counting extracted reads...")

        let readCount = try await countReads(in: outputURL)

        guard readCount > 0 else {
            throw ExtractionError.emptyExtraction
        }

        progress?(1.0, "Extracted \(readCount) reads from BAM")
        logger.info(
            "BAM region extraction complete: \(readCount) reads, strategy=\(matchResult.strategy.rawValue, privacy: .public)"
        )

        return ExtractionResult(
            fastqURLs: [outputURL],
            readCount: readCount,
            pairedEnd: false
        )
    }

    // MARK: - Extract from Database

    /// Extracts reads from an NAO-MGS SQLite database by tax ID and/or accession.
    ///
    /// Queries the `virus_hits` table directly for read sequences and quality scores,
    /// then writes them as a FASTQ file. This avoids requiring the original source
    /// FASTQ when the database already stores complete read data.
    ///
    /// - Parameters:
    ///   - config: Configuration specifying the database, filters, and output location.
    ///   - progress: Optional callback reporting progress as `(fraction, message)`.
    /// - Returns: An ``ExtractionResult`` with the output FASTQ URL and read count.
    /// - Throws: ``ExtractionError`` on database errors, validation failure, or empty output.
    public func extractFromDatabase(
        config: DatabaseExtractionConfig,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: config.databaseURL.path) else {
            throw ExtractionError.databaseQueryFailed("Database file not found: \(config.databaseURL.lastPathComponent)")
        }

        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        progress?(0.1, "Opening database...")

        // Open the database and query reads
        let database: NaoMgsDatabase
        do {
            database = try NaoMgsDatabase(at: config.databaseURL)
        } catch {
            throw ExtractionError.databaseQueryFailed("Failed to open database: \(error.localizedDescription)")
        }

        progress?(0.2, "Querying reads from database...")

        // Determine which sample to query — use config.sampleId or find the first sample
        let sampleId: String
        if let configSample = config.sampleId {
            sampleId = configSample
        } else {
            let samples = try database.fetchSamples()
            guard let first = samples.first else {
                throw ExtractionError.databaseQueryFailed("No samples found in database")
            }
            sampleId = first.sample
        }

        // Collect reads from the database matching tax IDs and/or accessions
        var allReads: [(seqId: String, sequence: String, quality: String)] = []
        var seenReadIDs = Set<String>()
        let maxReads = config.maxReads ?? Int.max

        // Query by tax IDs
        if !config.taxIds.isEmpty {
            for taxId in config.taxIds {
                if allReads.count >= maxReads { break }

                do {
                    // Get accession summaries for this taxon so we can fetch reads per accession
                    let accSummaries = try database.fetchAccessionSummaries(
                        sample: sampleId,
                        taxId: taxId
                    )

                    for summary in accSummaries {
                        if allReads.count >= maxReads { break }

                        let remaining = maxReads - allReads.count
                        let reads = try database.fetchReadsForAccession(
                            sample: sampleId,
                            taxId: taxId,
                            accession: summary.accession,
                            maxReads: remaining
                        )

                        for read in reads {
                            guard allReads.count < maxReads else { break }
                            if seenReadIDs.insert(read.name).inserted {
                                // Reconstruct quality string from UInt8 array
                                let qualStr = String(read.qualities.map { Character(Unicode.Scalar(UInt32($0) + 33) ?? Unicode.Scalar(33)) })
                                allReads.append((seqId: read.name, sequence: read.sequence, quality: qualStr))
                            }
                        }
                    }
                } catch {
                    logger.warning("Failed to query tax ID \(taxId): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Query by accessions (if specified and we haven't hit the limit)
        if !config.accessions.isEmpty && allReads.count < maxReads {
            // For accession-based queries, we need to find which taxIds contain these accessions.
            // Fetch taxon summaries, then check which have matching accessions.
            let taxonRows = try database.fetchTaxonSummaryRows(samples: [sampleId])

            for row in taxonRows {
                if allReads.count >= maxReads { break }

                for accession in config.accessions {
                    if allReads.count >= maxReads { break }

                    let remaining = maxReads - allReads.count
                    do {
                        let reads = try database.fetchReadsForAccession(
                            sample: sampleId,
                            taxId: row.taxId,
                            accession: accession,
                            maxReads: remaining
                        )

                        for read in reads {
                            guard allReads.count < maxReads else { break }
                            if seenReadIDs.insert(read.name).inserted {
                                let qualStr = String(read.qualities.map { Character(Unicode.Scalar(UInt32($0) + 33) ?? Unicode.Scalar(33)) })
                                allReads.append((seqId: read.name, sequence: read.sequence, quality: qualStr))
                            }
                        }
                    } catch {
                        // Accession may not exist under this taxon — silently skip
                        continue
                    }
                }
            }
        }

        guard !allReads.isEmpty else {
            throw ExtractionError.emptyExtraction
        }

        progress?(0.6, "Writing \(allReads.count) reads to FASTQ...")

        // Write reads to FASTQ file
        let sanitizedBaseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
        let outputName = "\(sanitizedBaseName).fastq"
        let outputURL = config.outputDirectory.appendingPathComponent(outputName)

        var fastqContent = ""
        fastqContent.reserveCapacity(allReads.count * 300) // rough estimate
        for read in allReads {
            fastqContent += "@\(read.seqId)\n"
            fastqContent += "\(read.sequence)\n"
            fastqContent += "+\n"
            fastqContent += "\(read.quality)\n"
        }

        try fastqContent.write(to: outputURL, atomically: true, encoding: .utf8)

        progress?(1.0, "Extracted \(allReads.count) reads from database")
        logger.info("Database extraction complete: \(allReads.count) reads from \(config.databaseURL.lastPathComponent, privacy: .public)")

        return ExtractionResult(
            fastqURLs: [outputURL],
            readCount: allReads.count,
            pairedEnd: false
        )
    }

    // MARK: - Bundle Creation

    /// Packages extracted FASTQ file(s) into a `.lungfishfastq` bundle with provenance metadata.
    ///
    /// The bundle is created in ``outputDirectory`` with a name derived from the
    /// source and selection descriptors via ``ExtractionBundleNaming``.
    ///
    /// - Parameters:
    ///   - result: The extraction result containing FASTQ file URLs.
    ///   - metadata: Provenance metadata to write into the bundle.
    ///   - outputDirectory: The directory in which to create the bundle.
    /// - Returns: The URL of the created `.lungfishfastq` bundle directory.
    /// - Throws: ``ExtractionError/bundleCreationFailed(_:)`` on filesystem errors.
    /// - Parameters:
    ///   - result: The extraction result containing FASTQ file(s).
    ///   - sourceName: Human-readable source name (e.g., "SRR35520572") for bundle naming.
    ///   - selectionDescription: What was selected (e.g., "Human_coronavirus_OC43") for bundle naming.
    ///   - metadata: Provenance metadata for the extraction.
    ///   - outputDirectory: Parent directory where the bundle will be created.
    public func createBundle(
        from result: ExtractionResult,
        sourceName: String,
        selectionDescription: String,
        metadata: ExtractionMetadata,
        in outputDirectory: URL
    ) throws -> URL {
        let fm = FileManager.default

        // Build bundle name: {sourceName}_{selectionDescription}_extract
        let bundleName = ExtractionBundleNaming.bundleName(
            source: sourceName,
            selection: selectionDescription
        )
        let bundleDirName = "\(bundleName).\(FASTQBundle.directoryExtension)"
        let bundleURL = outputDirectory.appendingPathComponent(bundleDirName)

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } catch {
            throw ExtractionError.bundleCreationFailed(
                "Could not create bundle directory: \(error.localizedDescription)"
            )
        }

        // Move FASTQ files into the bundle
        for fastqURL in result.fastqURLs {
            let destURL = bundleURL.appendingPathComponent(fastqURL.lastPathComponent)
            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: fastqURL, to: destURL)
            } catch {
                throw ExtractionError.bundleCreationFailed(
                    "Could not move \(fastqURL.lastPathComponent) into bundle: \(error.localizedDescription)"
                )
            }
        }

        // Write extraction-metadata.json (provenance)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metadataData = try encoder.encode(metadata)
            let metadataURL = bundleURL.appendingPathComponent("extraction-metadata.json")
            try metadataData.write(to: metadataURL)
        } catch {
            throw ExtractionError.bundleCreationFailed(
                "Could not write extraction metadata: \(error.localizedDescription)"
            )
        }

        // Write PersistedFASTQMetadata for the primary FASTQ
        if let primaryFASTQ = result.fastqURLs.first {
            let movedPrimaryName = primaryFASTQ.lastPathComponent
            let movedPrimaryURL = bundleURL.appendingPathComponent(movedPrimaryName)

            var persistedMeta = PersistedFASTQMetadata()
            persistedMeta.downloadSource = "read-extraction"
            persistedMeta.downloadDate = metadata.extractionDate
            FASTQMetadataStore.save(persistedMeta, for: movedPrimaryURL)
        }

        logger.info("Created extraction bundle: \(bundleDirName, privacy: .public)")
        return bundleURL
    }

    // MARK: - Private Helpers

    /// Converts a BAM file into a single FASTQ by collecting all read classes.
    ///
    /// `samtools fastq -o` only writes READ1/READ2 and can silently drop unpaired
    /// READ_OTHER records (common in single-end metagenomics BAMs). We route
    /// READ_OTHER/READ1/READ2/singletons to separate temporary files and merge them.
    private func convertBAMToFASTQSingleFile(inputBAM: URL, outputFASTQ: URL) async throws {
        let fm = FileManager.default
        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-fastq-merge-",
            contextURL: outputFASTQ.deletingLastPathComponent()
        )
        defer { try? fm.removeItem(at: tempDir) }

        let otherURL = tempDir.appendingPathComponent("reads_other.fastq")
        let r1URL = tempDir.appendingPathComponent("reads_r1.fastq")
        let r2URL = tempDir.appendingPathComponent("reads_r2.fastq")
        let singletonURL = tempDir.appendingPathComponent("reads_singletons.fastq")

        let fastqResult = try await toolRunner.run(
            .samtools,
            arguments: [
                "fastq",
                "-0", otherURL.path,
                "-1", r1URL.path,
                "-2", r2URL.path,
                "-s", singletonURL.path,
                inputBAM.path,
            ],
            timeout: 7200
        )
        guard fastqResult.isSuccess else {
            throw ExtractionError.samtoolsFailed(fastqResult.stderr)
        }

        if fm.fileExists(atPath: outputFASTQ.path) {
            try fm.removeItem(at: outputFASTQ)
        }
        fm.createFile(atPath: outputFASTQ.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: outputFASTQ)
        defer { try? outHandle.close() }

        let orderedParts = [otherURL, singletonURL, r1URL, r2URL]
        for partURL in orderedParts {
            guard fm.fileExists(atPath: partURL.path) else { continue }
            let attrs = try fm.attributesOfItem(atPath: partURL.path)
            let size = attrs[.size] as? UInt64 ?? 0
            guard size > 0 else { continue }

            let inHandle = try FileHandle(forReadingFrom: partURL)
            defer { try? inHandle.close() }

            while true {
                let chunk = inHandle.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                outHandle.write(chunk)
            }
        }

        let mergedSize = (try? fm.attributesOfItem(atPath: outputFASTQ.path)[.size] as? UInt64) ?? 0
        if mergedSize == 0 {
            logger.warning("samtools fastq sidecar outputs were empty; retrying via stdout capture")
            let stdoutResult = try await toolRunner.run(
                .samtools,
                arguments: ["fastq", inputBAM.path],
                timeout: 7200
            )
            guard stdoutResult.isSuccess else {
                throw ExtractionError.samtoolsFailed(stdoutResult.stderr)
            }
            try stdoutResult.stdout.write(to: outputFASTQ, atomically: true, encoding: .utf8)
        }
    }

    /// Counts reads in a FASTQ file via `seqkit stats -T`.
    ///
    /// Parses the tab-separated output to extract the `num_seqs` column.
    ///
    /// - Parameter url: URL of the FASTQ file.
    /// - Returns: The number of reads in the file.
    private func countReads(in url: URL) async throws -> Int {
        let result = try await toolRunner.run(
            .seqkit,
            arguments: ["stats", "-T", url.path],
            timeout: 600
        )

        guard result.isSuccess else {
            logger.warning("seqkit stats failed: \(result.stderr, privacy: .public)")
            return 0
        }

        // Parse tab-separated output: file\tformat\ttype\tnum_seqs\t...
        let lines = result.stdout.components(separatedBy: "\n")
        guard lines.count >= 2 else { return 0 }

        let headerFields = lines[0].components(separatedBy: "\t")
        let dataFields = lines[1].components(separatedBy: "\t")

        // Find the num_seqs column index
        if let numSeqsIndex = headerFields.firstIndex(of: "num_seqs"),
           numSeqsIndex < dataFields.count {
            let rawValue = dataFields[numSeqsIndex].replacingOccurrences(of: ",", with: "")
            return Int(rawValue) ?? 0
        }

        return 0
    }
}
