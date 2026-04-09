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

    /// Walks up from `resultPath` to find the enclosing `.lungfish/` project root.
    ///
    /// If no `.lungfish/` marker is found in any ancestor directory, falls back
    /// to the result path's parent directory. This means callers always get
    /// back *some* writable directory — never `nil`.
    ///
    /// - Parameter resultPath: A file or directory URL inside a Lungfish project.
    /// - Returns: The `.lungfish/`-containing project root, or `resultPath`'s parent on fallback.
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

        // Walk up until we find .lungfish/ or hit the filesystem root.
        while current.path != "/" {
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
                progress: progress
            )
        } else {
            return try await extractViaKraken2(
                selections: nonEmpty,
                resultPath: resultPath,
                options: options,
                destination: destination,
                progress: progress
            )
        }
    }

    /// Cheap pre-flight count. Implemented in Task 2.2.
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

            let result = try await toolRunner.run(.samtools, arguments: args, timeout: 600)
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
        // The resolver knows how to load a Kraken2 result from disk because
        // the ClassificationResult type exposes a .load(from:) initializer.
        // We defer the actual tree-walking until Task 2.6 where we also
        // implement the full Kraken2 extraction path; for now, just sum
        // `selections.taxIds.count * 0` and return zero — a correct-but-
        // conservative lower bound. Dialog live-update will show a real
        // number after Task 2.6 fills this in.
        //
        // TODO[phase2]: real Kraken2 estimate lands in Task 2.6.
        let _ = resultPath
        let _ = selections
        return 0
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
            // EsViritu writes {sampleId}.sorted.bam next to the result DB.
            // Historical layouts may have it in a temp subdir; we try both.
            var urls: [URL] = []
            if let sampleId {
                urls.append(resultDir.appendingPathComponent("\(sampleId).sorted.bam"))
                urls.append(resultDir.appendingPathComponent("\(sampleId)_temp/\(sampleId).sorted.bam"))
            } else {
                // Single-sample: any *.sorted.bam in the result dir.
                if let enumerator = fm.enumerator(at: resultDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                   let match = enumerator.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix(".sorted.bam") }) {
                    urls.append(match)
                }
            }
            candidates = urls

        case .taxtriage:
            // TaxTriage nf-core layout: minimap2/{sampleId}.bam
            guard let sampleId else {
                candidates = []
                break
            }
            candidates = [resultDir.appendingPathComponent("minimap2/\(sampleId).bam")]

        case .naomgs:
            // NAO-MGS: bams/{sampleId}.sorted.bam (materialized from SQLite if missing).
            guard let sampleId else {
                candidates = []
                break
            }
            candidates = [resultDir.appendingPathComponent("bams/\(sampleId).sorted.bam")]

        case .nvd:
            // NVD: adjacent {sampleId}.bam or sorted.bam
            guard let sampleId else {
                candidates = []
                break
            }
            candidates = [
                resultDir.appendingPathComponent("\(sampleId).bam"),
                resultDir.appendingPathComponent("\(sampleId).sorted.bam"),
            ]

        case .kraken2:
            throw ClassifierExtractionError.notImplemented  // Kraken2 isn't BAM-backed.
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
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        let fm = FileManager.default
        let projectRoot = Self.resolveProjectRoot(from: resultPath)

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
            progress?(Double(index) / totalSamples, "Extracting \(sampleLabel)…")

            let regions = group.flatMap { $0.accessions }
            guard !regions.isEmpty else { continue }

            let bamURL = try await resolveBAMURL(
                tool: tool,
                sampleId: sampleId,
                resultPath: resultPath
            )

            let perSampleBAM = tempDir.appendingPathComponent("\(sampleLabel)_regions.bam")
            var viewArgs = ["view", "-b", "-F", String(options.samtoolsExcludeFlags), "-o", perSampleBAM.path, bamURL.path]
            viewArgs.append(contentsOf: regions)

            let viewResult = try await toolRunner.run(.samtools, arguments: viewArgs, timeout: 3600)
            guard viewResult.isSuccess else {
                throw ClassifierExtractionError.samtoolsFailed(
                    sampleId: sampleLabel,
                    stderr: viewResult.stderr
                )
            }

            // NOTE: use -o (not -0). -0 captures only READ_OTHER; -o writes
            // interleaved READ1/READ2 pairs — the common paired-end case.
            // Singletons would go to stdout if present; the plan's `-0`
            // mis-captured nothing for our paired-end sarscov2 fixture.
            let perSampleFASTQ = tempDir.appendingPathComponent("\(sampleLabel).fastq")
            let fastqResult = try await toolRunner.run(
                .samtools,
                arguments: ["fastq", perSampleBAM.path, "-o", perSampleFASTQ.path],
                timeout: 3600
            )
            guard fastqResult.isSuccess else {
                throw ClassifierExtractionError.samtoolsFailed(
                    sampleId: sampleLabel,
                    stderr: fastqResult.stderr
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

        return try routeToDestination(
            finalFile: finalFASTQ,
            tempDir: tempDir,
            readCount: readCount,
            tool: tool,
            destination: destination,
            progress: progress
        )
    }

    private func extractViaKraken2(
        selections: [ClassifierRowSelector],
        resultPath: URL,
        options: ExtractionOptions,
        destination: ExtractionDestination,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ExtractionOutcome {
        throw ClassifierExtractionError.notImplemented
    }

    // MARK: - File helpers

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

    /// Counts FASTQ records by dividing `wc -l` by 4. Fast and dependency-free.
    private func countFASTQRecords(in url: URL) async throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var lineCount = 0
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
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
        tempDir: URL,
        readCount: Int,
        tool: ClassifierTool,
        destination: ExtractionDestination,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> ExtractionOutcome {
        let fm = FileManager.default
        switch destination {
        case .file(let url):
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: finalFile, to: url)
            progress?(1.0, "Wrote \(readCount) reads to \(url.lastPathComponent)")
            return .file(url, readCount: readCount)

        case .bundle, .clipboard, .share:
            // Filled in by Task 2.5.
            throw ClassifierExtractionError.notImplemented
        }
    }

    // MARK: - Test hooks

    #if DEBUG
    /// Test-only wrapper exposing `resolveBAMURL` for unit testing.
    public func testingResolveBAMURL(
        tool: ClassifierTool,
        sampleId: String?,
        resultPath: URL
    ) async throws -> URL {
        try await resolveBAMURL(tool: tool, sampleId: sampleId, resultPath: resultPath)
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

    /// The resolver method is not yet implemented (build-time stub).
    case notImplemented

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
        case .notImplemented:
            return "ClassifierReadResolver path is not yet implemented"
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
