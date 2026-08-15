// ClassifierReadResolver.swift — Unified classifier read extraction actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(
    subsystem: "com.lungfish.workflow",
    category: "ClassifierReadResolver"
)

// MARK: - ClassifierReadResolver

/// Unified extraction actor that takes a tool + row selection + destination
/// and produces an ``ExtractionOutcome``.
///
/// The resolver is the single point through which all classifier read
/// extraction must pass. It replaces four prior parallel implementations
/// (EsViritu / TaxTriage / NAO-MGS hand-rolled `extractByBAMRegion` callers,
/// Kraken2 `TaxonomyExtractionSheet` wizard) so that:
///
/// 1. A single samtools flag filter (`-F 0x404` by default) matches the
///    `MarkdupService.countReads` "Unique Reads" figure shown in the UI.
/// 2. Changes to the extraction pipeline have exactly one place to land.
/// 3. The CLI `--by-classifier` strategy and the GUI extraction dialog share
///    the same backend byte-for-byte (see `ClassifierCLIRoundTripTests`).
///
/// ## Dispatch
///
/// The public API takes a `ClassifierTool` and branches on `usesBAMDispatch`:
///
/// - BAM-backed tools (EsViritu, TaxTriage, NAO-MGS, NVD) run
///   `samtools view -F <flags> -b <bam> <regions...>` to a temp BAM, then
///   `samtools fastq` to a per-sample FASTQ, and concatenate per-sample
///   outputs before routing to the destination.
/// - Kraken2 wraps the existing `TaxonomyExtractionPipeline.extract` with
///   `includeChildren: true` always, then routes its output to the destination.
///
/// ## Thread safety
///
/// `ClassifierReadResolver` is an actor — all method calls are serialised.
public actor ClassifierReadResolver {

    // MARK: - Properties

    private let toolRunner: NativeToolRunner

    // MARK: - Initialization

    /// Creates a resolver using the shared native tool runner.
    public init(toolRunner: NativeToolRunner = .shared) {
        self.toolRunner = toolRunner
    }

    // MARK: - Static helpers

    /// Walks up from `resultPath` to find the enclosing Lungfish project root.
    ///
    /// A Lungfish project is a directory with the `.lungfish` file extension
    /// (e.g. `MyProject.lungfish/`). The method also checks for a `.lungfish/`
    /// subdirectory as a legacy marker for test fixtures.
    ///
    /// If no project root is found in any ancestor, falls back to the result
    /// path's parent directory. This means callers always get back *some*
    /// writable directory — never `nil`.
    ///
    /// - Parameter resultPath: A file or directory URL inside a Lungfish project.
    /// - Returns: The project root directory, or `resultPath`'s parent on fallback.
    public static func resolveProjectRoot(from resultPath: URL) -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: resultPath.path, isDirectory: &isDirectory)

        // Start from the directory containing resultPath (unless resultPath is a directory).
        var current: URL
        if exists && isDirectory.boolValue {
            current = resultPath.standardizedFileURL
        } else {
            current = resultPath.deletingLastPathComponent().standardizedFileURL
        }

        let fallback = current

        // Walk up until we find a .lungfish project directory or hit the filesystem root.
        while current.path != "/" {
            // Check 1: directory itself has .lungfish extension (production projects).
            if current.pathExtension == "lungfish" {
                return current
            }
            // Check 2: contains a .lungfish/ subdirectory (test fixtures / legacy).
            let marker = current.appendingPathComponent(".lungfish")
            if fm.fileExists(atPath: marker.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }  // can't go higher
            current = parent
        }

        return fallback
    }

    // MARK: - Public API

    /// Runs an extraction and routes the result to the requested destination.
    public func resolveAndExtract(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions,
        destination: ExtractionDestination,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ExtractionOutcome {
        let startedAt = Date()
        let nonEmpty = selections.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            throw ClassifierExtractionError.zeroReadsExtracted
        }

        progress?(0.0, "Preparing \(tool.displayName) extraction…")

        if tool.usesBAMDispatch {
            return try await extractViaBAM(
                tool: tool,
                selections: nonEmpty,
                resultPath: resultPath,
                options: options,
                destination: destination,
                startedAt: startedAt,
                progress: progress
            )
        } else {
            return try await extractViaKraken2(
                selections: nonEmpty,
                resultPath: resultPath,
                options: options,
                destination: destination,
                startedAt: startedAt,
                progress: progress
            )
        }
    }

    /// Cheap pre-flight count for the selected classifier rows.
    public func estimateReadCount(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions
    ) async throws -> Int {
        // Early return: no selections means nothing to count.
        let nonEmpty = selections.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }

        if tool.usesBAMDispatch {
            return try await estimateBAMReadCount(
                tool: tool,
                resultPath: resultPath,
                selections: nonEmpty,
                options: options
            )
        } else {
            return try await estimateKraken2ReadCount(
                resultPath: resultPath,
                selections: nonEmpty
            )
        }
    }

    // MARK: - Private BAM dispatch

    /// Sums `samtools view -c -F <flags> <bam> <regions...>` across samples.
    private func estimateBAMReadCount(
        tool: ClassifierTool,
        resultPath: URL,
        selections: [ClassifierRowSelector],
        options: ExtractionOptions
    ) async throws -> Int {
        let groupedBySample = groupBySample(selections)
        var total = 0
        for (sampleId, group) in groupedBySample {
            let regions = group.flatMap { $0.accessions }
            guard !regions.isEmpty else { continue }

            let bamURL = try await resolveBAMURL(
                tool: tool,
                sampleId: sampleId,
                resultPath: resultPath
            )

            var args = ["view", "-c", "-F", String(options.samtoolsExcludeFlags), bamURL.path]
            args.append(contentsOf: regions)

            // Unified 3600s timeout matches extractViaBAM; a pre-flight estimate
            // should never impose a tighter bound than the operation it previews.
            let result = try await toolRunner.run(.samtools, arguments: args, timeout: 3600)
            guard result.isSuccess else {
                throw ClassifierExtractionError.samtoolsFailed(
                    sampleId: sampleId ?? "(single)",
                    stderr: result.stderr
                )
            }

            // samtools view -c writes a single integer to stdout.
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(trimmed) {
                total += n
            }
        }
        return total
    }

    /// Kraken2 estimate: sum of `readsClade` across selected taxa, pulled from
    /// the on-disk taxonomy tree rather than running samtools.
    private func estimateKraken2ReadCount(
        resultPath: URL,
        selections: [ClassifierRowSelector]
    ) async throws -> Int {
        var total = 0
        for (sampleId, group) in groupBySample(selections) {
            let sampleResultPath = sampleId.map {
                resultPath.appendingPathComponent($0, isDirectory: true)
            } ?? resultPath

            let classResult: ClassificationResult
            do {
                classResult = try ClassificationResult.load(from: sampleResultPath)
            } catch {
                // Keep the estimate best-effort per sample: one unavailable
                // result contributes zero without discarding successful samples.
                let sampleLabel = sampleId ?? "(single)"
                logger.warning(
                    "estimateKraken2ReadCount: sample \(sampleLabel, privacy: .private(mask: .hash)) at \(sampleResultPath.path, privacy: .private(mask: .hash)) failed to load: \(String(describing: error), privacy: .private(mask: .hash)); contributing 0"
                )
                continue
            }

            let targetIds = Set(group.flatMap { $0.taxIds })
            for node in classResult.tree.allNodes() where targetIds.contains(node.taxId) {
                // clade count already includes descendant reads; spec says
                // includeChildren is always true for Kraken2.
                total += node.readsClade
            }
        }
        return total
    }

    // MARK: - Private helpers

    /// Groups selectors by `sampleId`, treating `nil` as a single implicit sample.
    private func groupBySample(
        _ selections: [ClassifierRowSelector]
    ) -> [(String?, [ClassifierRowSelector])] {
        var bySample: [String?: [ClassifierRowSelector]] = [:]
        var order: [String?] = []
        for sel in selections {
            if bySample[sel.sampleId] == nil {
                order.append(sel.sampleId)
            }
            bySample[sel.sampleId, default: []].append(sel)
        }
        return order.map { ($0, bySample[$0] ?? []) }
    }

    /// Resolves the per-sample BAM URL for a classifier tool.
    ///
    /// Each tool stores its BAM differently; this function centralizes the
    /// knowledge. When `sampleId` is `nil` (single-sample result views) we
    /// look for a single BAM file using the tool's default naming convention.
    private func resolveBAMURL(
        tool: ClassifierTool,
        sampleId: String?,
        resultPath: URL
    ) async throws -> URL {
        let fm = FileManager.default
        let resultDir = resultPath.hasDirectoryPath
            ? resultPath
            : resultPath.deletingLastPathComponent()

        let sample = sampleId ?? "(single)"

        // Build the candidate URL list in the order we want to try them.
        let candidates: [URL]
        switch tool {
        case .esviritu:
            // EsViritu BAM locations vary by pipeline version:
            //   Current: {sampleId}/bams/{sampleId}.third.filt.sorted.bam
            //   Legacy:  {sampleId}.sorted.bam (next to the result DB)
            //   Legacy:  {sampleId}_temp/{sampleId}.sorted.bam
            // We also scan the sample's bams/ subdirectory for any *.sorted.bam
            // to handle unexpected naming variations.
            var urls: [URL] = []
            if let sampleId {
                // Current layout: per-sample subdir with bams/ child
                let bamsDir = resultDir.appendingPathComponent("\(sampleId)/bams")
                if fm.fileExists(atPath: bamsDir.path) {
                    // Prefer the specific pattern first, then scan for any .sorted.bam
                    urls.append(bamsDir.appendingPathComponent("\(sampleId).third.filt.sorted.bam"))
                    if let contents = try? fm.contentsOfDirectory(at: bamsDir, includingPropertiesForKeys: nil) {
                        for file in contents where file.lastPathComponent.hasSuffix(".sorted.bam") && !urls.contains(file) {
                            urls.append(file)
                        }
                    }
                }
                // Legacy flat layouts
                urls.append(resultDir.appendingPathComponent("\(sampleId).sorted.bam"))
                urls.append(resultDir.appendingPathComponent("\(sampleId)_temp/\(sampleId).sorted.bam"))
            } else {
                // Single-sample: scan recursively for any *.sorted.bam
                if let enumerator = fm.enumerator(at: resultDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                   let match = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix(".sorted.bam") }) {
                    urls.append(match)
                }
            }
            candidates = urls

        case .taxtriage:
            // TaxTriage nf-core layout stores BAMs in minimap2/ with naming
            // patterns that vary by pipeline version:
            //   Current: minimap2/{sampleId}.{sampleId}.dwnld.references.bam
            //   Legacy:  minimap2/{sampleId}.bam
            // We try the exact legacy name first, then scan minimap2/ for any
            // BAM whose filename starts with the sampleId.
            guard let sampleId else {
                candidates = []
                break
            }
            var urls: [URL] = []
            urls.append(resultDir.appendingPathComponent("minimap2/\(sampleId).bam"))
            let minimap2Dir = resultDir.appendingPathComponent("minimap2")
            if fm.fileExists(atPath: minimap2Dir.path) {
                if let contents = try? fm.contentsOfDirectory(at: minimap2Dir, includingPropertiesForKeys: nil) {
                    for file in contents where file.lastPathComponent.hasPrefix(sampleId)
                        && file.lastPathComponent.hasSuffix(".bam")
                        && !file.lastPathComponent.hasSuffix(".bam.bai")
                        && !urls.contains(file) {
                        urls.append(file)
                    }
                }
            }
            candidates = urls

        case .naomgs:
            // NAO-MGS: prefer the BAM pointer stored in hits.sqlite, then fall back
            // to legacy filename conventions for pre-pointer imports.
            guard let sampleId else {
                candidates = []
                break
            }
            var urls: [URL] = []
            let dbURL = resultDir.appendingPathComponent("hits.sqlite")
            if fm.fileExists(atPath: dbURL.path),
               let database = try? NaoMgsDatabase(at: dbURL),
               let bamRelative = try? database.fetchTaxonSummaryRows(samples: [sampleId])
                    .compactMap(\.bamPath)
                    .first(where: { !$0.isEmpty }) {
                urls.append(resultDir.appendingPathComponent(bamRelative))
            }
            urls.append(resultDir.appendingPathComponent("bams/\(sampleId).bam"))
            urls.append(resultDir.appendingPathComponent("bams/\(sampleId).sorted.bam"))
            candidates = urls

        case .nvd:
            // NVD: BAM path stored in hits.sqlite under bam/{sampleId}.filtered.bam
            guard let sampleId else {
                candidates = []
                break
            }
            var urls: [URL] = []
            let dbURL = resultDir.appendingPathComponent("hits.sqlite")
            if fm.fileExists(atPath: dbURL.path),
               let database = try? NvdDatabase(at: dbURL),
               let bamRelative = try? database.bamPath(forSample: sampleId),
               !bamRelative.isEmpty {
                urls.append(resultDir.appendingPathComponent(bamRelative))
            }
            urls.append(resultDir.appendingPathComponent("bam/\(sampleId).filtered.bam"))
            urls.append(resultDir.appendingPathComponent("bam/\(sampleId).filtered.sorted.bam"))
            candidates = urls

        case .kraken2:
            throw ClassifierExtractionError.unsupportedBAMTool(tool)
        }

        for url in candidates {
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        throw ClassifierExtractionError.bamNotFound(sampleId: sample)
    }

    // MARK: - BAM-backed extraction

    private func extractViaBAM(
        tool: ClassifierTool,
        selections: [ClassifierRowSelector],
        resultPath: URL,
        options: ExtractionOptions,
        destination: ExtractionDestination,
        startedAt: Date,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        let fm = FileManager.default
        let projectRoot = Self.resolveProjectRoot(from: resultPath)
        var provenanceSourceURLs = existingUniqueURLs([resultPath])

        let tempDir = try ProjectTempDirectory.create(
            prefix: "classifier-extract-\(tool.rawValue)-",
            in: projectRoot
        )
        defer { try? fm.removeItem(at: tempDir) }

        let grouped = groupBySample(selections)
        guard !grouped.isEmpty else {
            throw ClassifierExtractionError.zeroReadsExtracted
        }

        // Step 1: per-sample samtools view -b -F <flags> -> per-sample BAM -> per-sample FASTQ.
        var perSampleFASTQs: [URL] = []
        let totalSamples = Double(grouped.count)

        for (index, (sampleId, group)) in grouped.enumerated() {
            try Task.checkCancellation()
            let sampleLabel = sampleId ?? "sample"
            // Index-prefixed stem so that nil / "sample" / duplicate labels
            // never collide in a shared tempDir. The human-friendly label is
            // still used for progress messages and error reporting.
            let stem = "\(index)_\(sampleLabel)"
            progress?(Double(index) / totalSamples, "Extracting \(sampleLabel)…")

            let regions = group.flatMap { $0.accessions }
            guard !regions.isEmpty else { continue }

            // Merge read-name allowlists across all selectors in this sample group.
            // When present, only reads whose QNAME appears in the allowlist are kept.
            // This prevents NAO-MGS extractions from returning reads belonging to
            // other taxa that happen to share the same reference accessions.
            let mergedAllowlist: Set<String>? = {
                let lists = group.compactMap(\.readNameAllowlist)
                guard !lists.isEmpty else { return nil }
                return lists.reduce(into: Set<String>()) { $0.formUnion($1) }
            }()

            let bamURL = try await resolveBAMURL(
                tool: tool,
                sampleId: sampleId,
                resultPath: resultPath
            )
            provenanceSourceURLs.append(bamURL)

            let perSampleBAM = tempDir.appendingPathComponent("\(stem)_regions.bam")
            var viewArgs = ["view", "-b", "-F", String(options.samtoolsExcludeFlags)]

            // Write read-name allowlist to a file for `samtools view -N`.
            if let allowlist = mergedAllowlist, !allowlist.isEmpty {
                let nameListFile = tempDir.appendingPathComponent("\(stem)_readnames.txt")
                try allowlist.sorted().joined(separator: "\n").write(to: nameListFile, atomically: true, encoding: .utf8)
                viewArgs.append(contentsOf: ["-N", nameListFile.path])
            }

            viewArgs.append(contentsOf: ["-o", perSampleBAM.path, bamURL.path])
            viewArgs.append(contentsOf: regions)

            let viewResult = try await toolRunner.run(.samtools, arguments: viewArgs, timeout: 3600)
            guard viewResult.isSuccess else {
                throw ClassifierExtractionError.samtoolsFailed(
                    sampleId: sampleLabel,
                    stderr: viewResult.stderr
                )
            }

            // Route every read class to a sidecar and merge. The shared helper
            // in BAMToFASTQConverter.swift handles the -0/-1/-2/-s split plus
            // stdout fallback, shared with ReadExtractionService. The flag
            // filter passed here MUST match the one used for both
            // `samtools view -c` (estimate) and `samtools view -b` (above), or
            // the per-BAM read count will diverge from `MarkdupService.countReads`
            // on any alignment containing secondary/supplementary records.
            // This is spec invariant I4.
            let perSampleFASTQ = tempDir.appendingPathComponent("\(stem).fastq")
            do {
                try await convertBAMToSingleFASTQ(
                    inputBAM: perSampleBAM,
                    outputFASTQ: perSampleFASTQ,
                    tempDir: tempDir,
                    sidecarPrefix: stem,
                    flagFilter: options.samtoolsExcludeFlags,
                    timeout: 3600,
                    toolRunner: toolRunner
                )
            } catch BAMToFASTQConversionError.samtoolsFailed(let stderr) {
                throw ClassifierExtractionError.samtoolsFailed(
                    sampleId: sampleLabel,
                    stderr: stderr
                )
            }

            if fm.fileExists(atPath: perSampleFASTQ.path) {
                let size = (try? fm.attributesOfItem(atPath: perSampleFASTQ.path)[.size] as? UInt64) ?? 0
                if size > 0 {
                    perSampleFASTQs.append(perSampleFASTQ)
                }
            }
        }

        // Step 2: concatenate per-sample FASTQs into one temp file.
        let concatenated = tempDir.appendingPathComponent("concatenated.fastq")
        try concatenateFiles(perSampleFASTQs, into: concatenated)

        let readCount = try await countFASTQRecords(in: concatenated)
        if readCount == 0 {
            throw ClassifierExtractionError.zeroReadsExtracted
        }

        progress?(0.9, "Formatting output…")

        // Step 3: handle format conversion and destination routing.
        let finalFASTQ: URL
        if options.format == .fasta {
            finalFASTQ = tempDir.appendingPathComponent("concatenated.fasta")
            try convertFASTQToFASTA(input: concatenated, output: finalFASTQ)
        } else {
            finalFASTQ = concatenated
        }

        return try await routeToDestination(
            finalFile: finalFASTQ,
            readCount: readCount,
            destination: destination,
            options: options,
            provenanceSourceURLs: existingUniqueURLs(provenanceSourceURLs),
            extractionStartedAt: startedAt,
            progress: progress
        )
    }

    // MARK: - Kraken2 dispatch

    private func extractViaKraken2(
        selections: [ClassifierRowSelector],
        resultPath: URL,
        options: ExtractionOptions,
        destination: ExtractionDestination,
        startedAt: Date,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        // Collect tax IDs from the (possibly multi-row) selection.
        let allTaxIds = Set(selections.flatMap { $0.taxIds })
        guard !allTaxIds.isEmpty else {
            throw ClassifierExtractionError.zeroReadsExtracted
        }

        // Locate a writable temp directory under the enclosing project.
        let projectRoot = Self.resolveProjectRoot(from: resultPath)
        let tempDir = try ProjectTempDirectory.create(
            prefix: "kraken2-extract-",
            in: projectRoot
        )
        let cleanTempDir = tempDir  // capture for defer
        defer { try? FileManager.default.removeItem(at: cleanTempDir) }

        // Build the list of per-sample result paths to process.
        // In batch mode, each selector carries a sampleId and the resultPath
        // is the batch root directory containing per-sample subdirectories.
        // In single-sample mode, sampleId is nil and resultPath points directly
        // at the sample's classification output directory.
        let sampleJobs: [(sampleId: String?, sampleResultPath: URL)]
        let sampleIds = selections.compactMap(\.sampleId)
        if !sampleIds.isEmpty {
            // Batch mode: resultPath is the batch root. Each sample's results
            // live in a subdirectory named after the sampleId.
            sampleJobs = sampleIds.map { sid in
                (sampleId: sid, sampleResultPath: resultPath.appendingPathComponent(sid))
            }
        } else {
            // Single-sample mode: resultPath is the classification output dir.
            sampleJobs = [(sampleId: nil, sampleResultPath: resultPath)]
        }

        var allProducedURLs: [URL] = []
        var provenanceSourceURLs = existingUniqueURLs([resultPath])

        for (jobIndex, job) in sampleJobs.enumerated() {
            try Task.checkCancellation()

            let sampleLabel = job.sampleId ?? "sample"
            let baseFraction = Double(jobIndex) / Double(sampleJobs.count)
            let sampleWeight = 1.0 / Double(sampleJobs.count)

            progress?(baseFraction * 0.8, "Loading \(sampleLabel) classification…")

            // Load this sample's ClassificationResult.
            let classResult: ClassificationResult
            do {
                classResult = try ClassificationResult.load(from: job.sampleResultPath)
            } catch {
                logger.warning("Skipping sample \(sampleLabel, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            provenanceSourceURLs.append(job.sampleResultPath)
            provenanceSourceURLs.append(classResult.outputURL)

            // Resolve the source FASTQ(s) for this sample.
            let sourceFASTQs: [URL]
            do {
                sourceFASTQs = try resolveKraken2SourceFASTQs(classResult: classResult)
            } catch {
                logger.warning("Skipping sample \(sampleLabel, privacy: .public) — source FASTQ not found: \(error.localizedDescription, privacy: .public)")
                continue
            }
            provenanceSourceURLs.append(contentsOf: sourceFASTQs)

            // Build per-sample output paths in the shared temp dir.
            let stem = "\(jobIndex)_\(sampleLabel)"
            let outputFiles: [URL]
            if sourceFASTQs.count == 1 {
                outputFiles = [tempDir.appendingPathComponent("\(stem).fastq")]
            } else {
                outputFiles = sourceFASTQs.enumerated().map { idx, _ in
                    tempDir.appendingPathComponent("\(stem)_R\(idx + 1).fastq")
                }
            }

            let config = TaxonomyExtractionConfig(
                taxIds: allTaxIds,
                includeChildren: true,
                sourceFiles: sourceFASTQs,
                outputFiles: outputFiles,
                classificationOutput: classResult.outputURL,
                taxonomyReport: classResult.reportURL,
                keepReadPairs: true
            )

            progress?(baseFraction * 0.8 + 0.1 * sampleWeight, "Extracting \(sampleLabel)…")

            let pipeline = TaxonomyExtractionPipeline()
            let producedURLs = try await pipeline.extract(
                config: config,
                tree: classResult.tree,
                progress: { fraction, message in
                    progress?(baseFraction * 0.8 + fraction * 0.7 * sampleWeight, "\(sampleLabel): \(message)")
                }
            )

            // Decompress .fastq.gz output from seqkit.
            let decompressed = try await decompressGzippedFiles(producedURLs)
            allProducedURLs.append(contentsOf: decompressed)
        }

        guard !allProducedURLs.isEmpty else {
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        // Concatenate all per-sample outputs into a single FASTQ.
        let concatenated = tempDir.appendingPathComponent("kraken2-concat.fastq")
        try concatenateFiles(allProducedURLs, into: concatenated)
        try Task.checkCancellation()

        let readCount = try await countFASTQRecords(in: concatenated)
        if readCount == 0 {
            throw ClassifierExtractionError.zeroReadsExtracted
        }
        try Task.checkCancellation()

        // Format conversion.
        let finalFile: URL
        if options.format == .fasta {
            finalFile = tempDir.appendingPathComponent("kraken2-concat.fasta")
            try convertFASTQToFASTA(input: concatenated, output: finalFile)
            try Task.checkCancellation()
        } else {
            finalFile = concatenated
        }

        progress?(0.9, "Routing to destination…")
        return try await routeToDestination(
            finalFile: finalFile,
            readCount: readCount,
            destination: destination,
            options: options,
            provenanceSourceURLs: existingUniqueURLs(provenanceSourceURLs),
            extractionStartedAt: startedAt,
            progress: progress
        )
    }

    /// Resolves the Kraken2 source FASTQ(s) for extraction.
    ///
    /// Tries (in order):
    /// 1. `config.originalInputFiles` if non-nil (preserved before
    ///    materialization). If the resulting URL is a bundle, uses the
    ///    `FASTQBundle.resolvePrimaryFASTQURL` resolver.
    /// 2. Walking up from `config.outputDirectory` to find the enclosing
    ///    `.lungfishfastq` bundle.
    /// 3. Falls back to `config.inputFiles` directly.
    private func resolveKraken2SourceFASTQs(
        classResult: ClassificationResult
    ) throws -> [URL] {
        let fm = FileManager.default
        let config = classResult.config

        // 1. originalInputFiles
        if let originals = config.originalInputFiles,
           let first = originals.first,
           fm.fileExists(atPath: first.path) {
            if FASTQBundle.isBundleURL(first),
               let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: first) {
                return [resolved]
            }
            return originals
        }

        // 2. Walk up from outputDirectory to find the enclosing bundle.
        //    outputDirectory = bundle.lungfishfastq/derivatives/classification-xxx/
        let derivativesDir = config.outputDirectory.deletingLastPathComponent()
        let bundleDir = derivativesDir.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(bundleDir),
           let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: bundleDir) {
            return [resolved]
        }

        // 3. Fall back to config.inputFiles if they exist.
        if let first = config.inputFiles.first, fm.fileExists(atPath: first.path) {
            return config.inputFiles
        }

        throw ClassifierExtractionError.kraken2SourceMissing
    }

    // MARK: - File helpers

    /// Decompresses any `.gz` files in the list, returning URLs to uncompressed files.
    /// Non-`.gz` files are passed through unchanged. Uses `pigz -d -c` (parallel
    /// decompression to stdout) via `NativeToolRunner.runWithFileOutput`, matching
    /// the pattern established in `FASTQBatchImporter`.
    private func decompressGzippedFiles(_ urls: [URL]) async throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            guard url.pathExtension == "gz" else {
                result.append(url)
                continue
            }
            let decompressed = url.deletingPathExtension() // strips .gz -> .fastq
            // If the decompressed file already exists (e.g. from a prior run), use it.
            if fm.fileExists(atPath: decompressed.path) {
                result.append(decompressed)
                continue
            }
            let pigzResult = try await toolRunner.runWithFileOutput(
                .pigz,
                arguments: ["-d", "-c", url.path],
                outputFile: decompressed
            )
            guard pigzResult.isSuccess,
                  fm.fileExists(atPath: decompressed.path) else {
                logger.warning("pigz decompression failed for \(url.lastPathComponent, privacy: .public): \(pigzResult.stderr.suffix(200), privacy: .public)")
                result.append(url)
                continue
            }
            result.append(decompressed)
        }
        return result
    }

    private func concatenateFiles(_ sources: [URL], into destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? outHandle.close() }
        for src in sources {
            let inHandle = try FileHandle(forReadingFrom: src)
            defer { try? inHandle.close() }
            while true {
                let chunk = inHandle.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                outHandle.write(chunk)
            }
        }
    }

    private func existingUniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                continue
            }
            result.append(standardized)
        }
        return result
    }

    /// Counts FASTQ records by dividing `wc -l` by 4. Fast and dependency-free.
    ///
    /// Tracks whether the file's final byte was a newline: a well-formed FASTQ file ends
    /// each of its 4-line records (including the last) with `\n`, so counting only `\n`
    /// bytes undercounts by one full record if the last quality line lacks a trailing
    /// newline (e.g. an upstream tool omits the final LF, or a partial/truncated write) --
    /// the last record is still fully present and usable, just not newline-terminated
    /// (R3-R3ML-10).
    private func countFASTQRecords(in url: URL) async throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineCount = 0
        var sawAnyBytes = false
        var lastByteWasNewline = false
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            sawAnyBytes = true
            lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            lastByteWasNewline = chunk.last == 0x0A
        }
        if sawAnyBytes && !lastByteWasNewline {
            lineCount += 1
        }
        return lineCount / 4
    }

    /// FASTQ → FASTA line-by-line conversion. Drops quality lines.
    private func convertFASTQToFASTA(input: URL, output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        fm.createFile(atPath: output.path, contents: nil)

        let inHandle = try FileHandle(forReadingFrom: input)
        defer { try? inHandle.close() }
        let outHandle = try FileHandle(forWritingTo: output)
        defer { try? outHandle.close() }

        // Stream line-by-line. We use a simple buffered line reader.
        let reader = LineReader(handle: inHandle)
        var lineIndex = 0
        while let line = reader.nextLine() {
            let mod = lineIndex % 4
            if mod == 0 {
                // Header line: convert leading @ to >
                if line.first == 0x40 /* @ */ {
                    var converted = Data([0x3E /* > */])
                    converted.append(line.dropFirst())
                    converted.append(0x0A)
                    outHandle.write(converted)
                } else {
                    var converted = line
                    converted.append(0x0A)
                    outHandle.write(converted)
                }
            } else if mod == 1 {
                var seq = line
                seq.append(0x0A)
                outHandle.write(seq)
            }
            // mod == 2 (+) and mod == 3 (quality) are discarded.
            lineIndex += 1
        }
    }

    // MARK: - Destination routing

    private func routeToDestination(
        finalFile: URL,
        readCount: Int,
        destination: ExtractionDestination,
        options: ExtractionOptions,
        provenanceSourceURLs: [URL],
        extractionStartedAt: Date,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        let fm = FileManager.default
        switch destination {
        case .file(let url):
            let destinationURL = url.standardizedFileURL
            let sourceURL = finalFile.standardizedFileURL
            if destinationURL == sourceURL {
                try writeStandaloneFileProvenanceIfNeeded(
                    outputURL: destinationURL,
                    outputFormat: options.format.fileFormat,
                    readCount: readCount,
                    options: options,
                    sourceURLs: provenanceSourceURLs,
                    extractionStartedAt: extractionStartedAt
                )
                progress?(1.0, "Wrote \(readCount) reads to \(destinationURL.lastPathComponent)")
                return .file(destinationURL, readCount: readCount)
            }
            if fm.fileExists(atPath: destinationURL.path) {
                do {
                    try fm.removeItem(at: destinationURL)
                } catch CocoaError.fileNoSuchFile {
                    // Another actor/process already removed the stale destination.
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    // Mirror the CocoaError handling above when bridging obscures the enum.
                }
            }
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Materialize a stable caller-owned file and leave temp-dir ownership
            // with the extraction scratch space. This avoids rename/remove races
            // on transient destinations and keeps the `.file` contract simple.
            try fm.copyItem(at: sourceURL, to: destinationURL)
            try writeStandaloneFileProvenanceIfNeeded(
                outputURL: destinationURL,
                outputFormat: options.format.fileFormat,
                readCount: readCount,
                options: options,
                sourceURLs: provenanceSourceURLs,
                extractionStartedAt: extractionStartedAt
            )
            progress?(1.0, "Wrote \(readCount) reads to \(destinationURL.lastPathComponent)")
            return .file(destinationURL, readCount: readCount)

        case .bundle(let projectRoot, let displayName, let metadata):
            // Reuse the existing ReadExtractionService bundle creator. Note: createBundle
            // is actor-isolated on ReadExtractionService, so we must `await` the call
            // even though the method itself is not declared `async`.
            let service = ReadExtractionService()
            let outputFormat = finalFile.pathExtension.lowercased() == "fasta" ? "fasta" : "fastq"
            let bundleMetadata = metadata.mergingParameters([
                "classifierExtractionOutputLayout": "single_file",
                "classifierExtractionOutputPairingMode": "single_end",
                "classifierExtractionOutputFormat": outputFormat,
                "classifierExtractionReadCountUnit": "reads",
            ])
            .recordingSourceURLs(provenanceSourceURLs)
            // Classifier extraction intentionally normalizes BAM-backed and
            // Kraken2 selections into one output file before bundling. Any
            // upstream mate layout has already been flattened, so the bundle
            // must be marked single-end rather than carrying an inferred
            // paired-end flag that no longer matches the stored payload.
            let result = ExtractionResult(
                fastqURLs: [finalFile],
                readCount: readCount,
                pairedEnd: false
            )
            let bundleURL = try await service.createBundle(
                from: result,
                sourceName: displayName,
                selectionDescription: "extract",
                metadata: bundleMetadata,
                in: projectRoot
            )
            progress?(1.0, "Created bundle \(bundleURL.lastPathComponent)")
            return .bundle(bundleURL, readCount: readCount)

        case .clipboard(_, let cap):
            if readCount > cap {
                throw ClassifierExtractionError.clipboardCapExceeded(
                    requested: readCount,
                    cap: cap
                )
            }
            let data = try Data(contentsOf: finalFile)
            let payload = String(decoding: data, as: UTF8.self)
            progress?(1.0, "Prepared \(data.count) bytes for clipboard")
            return .clipboard(payload: payload, byteCount: data.count, readCount: readCount)

        case .share(let shareDir):
            let sharesSubdir = shareDir.appendingPathComponent("shares/\(UUID().uuidString)")
            try fm.createDirectory(at: sharesSubdir, withIntermediateDirectories: true)
            let stableURL = sharesSubdir.appendingPathComponent(finalFile.lastPathComponent)
            if fm.fileExists(atPath: stableURL.path) {
                try fm.removeItem(at: stableURL)
            }
            try fm.moveItem(at: finalFile, to: stableURL)
            try writeStandaloneFileProvenanceIfNeeded(
                outputURL: stableURL,
                outputFormat: options.format.fileFormat,
                readCount: readCount,
                options: options,
                sourceURLs: provenanceSourceURLs,
                extractionStartedAt: extractionStartedAt
            )
            progress?(1.0, "Prepared file for sharing")
            return .share(stableURL, readCount: readCount)
        }
    }

    private func writeStandaloneFileProvenanceIfNeeded(
        outputURL: URL,
        outputFormat: FileFormat,
        readCount: Int,
        options: ExtractionOptions,
        sourceURLs: [URL],
        extractionStartedAt: Date
    ) throws {
        guard let fileProvenance = options.fileProvenance else {
            return
        }
        let provenance = fileProvenance.mergingResolved([
            "outputPath": .file(outputURL),
            "outputFormat": .string(options.format.rawValue),
            "readCount": .integer(readCount),
            "sourceCount": .integer(sourceURLs.count),
        ])
        var explicitOptions = provenance.explicitOptions
        if explicitOptions["outputPath"] == nil {
            explicitOptions["outputPath"] = .file(outputURL)
        }
        let argv = provenance.argv.contains(outputURL.path)
            ? provenance.argv
            : provenance.argv + ["--output", outputURL.path]
        try ScientificFileExportProvenance.write(.init(
            workflowName: provenance.workflowName,
            toolName: provenance.toolName,
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            outputFormat: outputFormat,
            argv: argv,
            explicitOptions: explicitOptions,
            defaults: provenance.defaults,
            resolved: provenance.resolved,
            startedAt: extractionStartedAt
        ))
    }

    // MARK: - Test hooks

    // `resolveBAMURL` is private because it is an internal dispatch helper, not
    // part of the resolver's public contract. Unit tests under
    // `ClassifierReadResolverTests.testResolveBAMURL_*` still need to exercise
    // each tool's BAM layout without going through the full extract pipeline,
    // so we expose a debug-only `testingResolveBAMURL` wrapper that is compiled
    // out of release builds.
    #if DEBUG
    /// Test-only wrapper exposing `resolveBAMURL` for unit testing.
    public func testingResolveBAMURL(
        tool: ClassifierTool,
        sampleId: String?,
        resultPath: URL
    ) async throws -> URL {
        try await resolveBAMURL(tool: tool, sampleId: sampleId, resultPath: resultPath)
    }

    /// Test-only wrapper exposing `countFASTQRecords` for unit testing (R3-R3ML-10).
    public func testingCountFASTQRecords(in url: URL) async throws -> Int {
        try await countFASTQRecords(in: url)
    }
    #endif
}

// MARK: - ClassifierExtractionError

/// Errors produced by `ClassifierReadResolver`.
///
/// Distinct from the lower-level `ExtractionError` so callers can differentiate
/// resolver-scoped failures (BAM-not-found-for-sample, missing Kraken2 output,
/// etc.) from primitive samtools/seqkit failures.
public enum ClassifierExtractionError: Error, LocalizedError, Sendable {

    /// The requested tool does not expose BAM-backed reads.
    case unsupportedBAMTool(ClassifierTool)

    /// No BAM file could be found for the given sample ID.
    case bamNotFound(sampleId: String)

    /// The Kraken2 per-read classified output file was missing or unreadable.
    case kraken2OutputMissing(URL)

    /// The Kraken2 taxonomy tree could not be loaded from disk.
    case kraken2TreeMissing(URL)

    /// The Kraken2 source FASTQ could not be located on disk.
    case kraken2SourceMissing

    /// A per-sample samtools invocation failed.
    case samtoolsFailed(sampleId: String, stderr: String)

    /// An extracted clipboard payload exceeded the requested cap.
    case clipboardCapExceeded(requested: Int, cap: Int)

    /// Destination directory not writable.
    case destinationNotWritable(URL)

    /// FASTQ → FASTA conversion failed while reading an input record.
    case fastaConversionFailed(String)

    /// Zero reads were extracted despite a non-empty pre-flight estimate.
    case zeroReadsExtracted

    /// The underlying extraction was cancelled.
    case cancelled

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .unsupportedBAMTool(let tool):
            return "\(tool.displayName) does not expose BAM-backed reads. Use the classifier extraction path for \(tool.displayName) instead."
        case .bamNotFound(let sampleId):
            return "No BAM file found for sample '\(sampleId)'. The classifier result may be corrupted or imported without the underlying alignment data."
        case .kraken2OutputMissing(let url):
            return "Kraken2 per-read classification output not found: \(url.lastPathComponent)"
        case .kraken2TreeMissing(let url):
            return "Kraken2 taxonomy tree not found: \(url.lastPathComponent)"
        case .kraken2SourceMissing:
            return "Kraken2 source FASTQ could not be located. The source file may have been moved or deleted."
        case .samtoolsFailed(let sampleId, let stderr):
            return "samtools view failed for sample '\(sampleId)': \(stderr)"
        case .clipboardCapExceeded(let requested, let cap):
            return "Selection contains \(requested) reads, which exceeds the clipboard cap of \(cap). Choose Save to File, Save as Bundle, or Share instead."
        case .destinationNotWritable(let url):
            return "Destination is not writable: \(url.path)"
        case .fastaConversionFailed(let reason):
            return "FASTQ → FASTA conversion failed: \(reason)"
        case .zeroReadsExtracted:
            return "The selection produced zero reads. Try adjusting the flag filter or selecting different rows."
        case .cancelled:
            return "Extraction was cancelled"
        }
    }
}

// MARK: - LineReader (private helper)

/// A minimal line reader for FASTQ → FASTA streaming. Not a general-purpose
/// line reader — it assumes LF line endings.
fileprivate final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize = 1 << 20

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex..<buffer.index(after: newlineIndex))
                return line
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            buffer.append(chunk)
        }
    }
}
