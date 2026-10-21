// TaxonomyExtractionPipeline.swift - Extracts reads by taxonomic classification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "TaxonomyExtraction")

// MARK: - TaxonomyExtractionPipeline

/// Actor that extracts reads classified to specific taxa from FASTQ file(s).
///
/// The extraction flow:
/// 1. Parse the Kraken2 per-read classification output to build a set of
///    read IDs assigned to the target tax IDs.
/// 2. If ``TaxonomyExtractionConfig/includeChildren`` is `true`, collect all
///    descendant tax IDs from the ``TaxonTree`` before filtering.
/// 3. For each source FASTQ file, read using buffered I/O (handling both plain
///    and gzip-compressed input), writing matching reads to the corresponding
///    output file.
///
/// The caller records provenance with
/// ``recordProvenance(config:resolvedTaxIds:outputURLs:extractedCount:runtime:command:)``
/// and names the command the record carries.
///
/// ## Paired-End Support
///
/// When ``TaxonomyExtractionConfig/sourceFiles`` contains two files (R1, R2),
/// the pipeline builds the read ID set from the classification output (which
/// was generated from both files), then filters each file independently using
/// the same set. This preserves pair ordering -- if read X appears in both R1
/// and R2, it is extracted from both.
///
/// ## Progress Reporting
///
/// Progress is reported via a `@Sendable (Double, String) -> Void` callback:
///
/// | Range        | Phase |
/// |-------------|-------|
/// | 0.0 -- 0.20 | Parsing classification output |
/// | 0.20 -- 0.30 | Building read ID set |
/// | 0.30 -- 0.95 | Filtering FASTQ(s) |
///
/// ## Thread Safety
///
/// All mutable state is isolated to this actor.
public actor TaxonomyExtractionPipeline {

    /// Creates an extraction pipeline.
    public init() {}

    /// The extraction `config` asks for: one output
    /// per source file of `config`, in order, nil for a source that holds
    /// none of the reads, with the tax IDs matched and the records written.
    /// Each index of `matePairStarts` is an R1 file whose R2 file follows
    /// it. That pair is read in step (``extractMatePairInStep(r1:r2:readIDs:to:)``)
    /// and its output, each R1 record followed by its R2 record, takes the
    /// R1 file's place, with nil in the R2 file's place.
    func extractEachSource(
        config: TaxonomyExtractionConfig,
        tree: TaxonTree,
        matePairStarts: [Int] = [],
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (outputs: [URL?], taxIds: Set<Int>, readCount: Int) {
        // Validate source/output count parity.
        guard config.sourceFiles.count == config.outputFiles.count else {
            throw TaxonomyExtractionError.sourceOutputCountMismatch(
                sources: config.sourceFiles.count,
                outputs: config.outputFiles.count
            )
        }

        // Phase 1: Parse classification output (0.0 -- 0.20)
        progress?(0.0, "Reading classification output...")

        let fm = FileManager.default
        guard fm.fileExists(atPath: config.classificationOutput.path) else {
            throw TaxonomyExtractionError.classificationOutputNotFound(config.classificationOutput)
        }
        for source in config.sourceFiles {
            guard fm.fileExists(atPath: source.path) else {
                throw TaxonomyExtractionError.sourceFileNotFound(source)
            }
        }

        // Build the complete set of target tax IDs
        let targetTaxIds: Set<Int>
        if config.includeChildren {
            targetTaxIds = collectDescendantTaxIds(config.taxIds, tree: tree)
        } else {
            targetTaxIds = config.taxIds
        }

        let taxIdCount = targetTaxIds.count
        logger.info("Extraction targeting \(taxIdCount, privacy: .public) tax IDs")
        progress?(0.10, "Filtering \(taxIdCount) tax IDs...")

        // Phase 2: Build read ID set from classification output (0.10 -- 0.30)
        // kraken2 --paired names every fragment by its R1 read with one final
        // /1 or /2 dropped, so the IDs of a paired run are fragment names
        // already and are matched as such, never trimmed a second time.
        let pairedRun = KrakenResultReadSources.classifiedPairs(in: config.classificationOutput)
        let matchingReadIds = try buildReadIdSet(
            classificationURL: config.classificationOutput,
            targetTaxIds: targetTaxIds,
            keepReadPairs: config.keepReadPairs && !pairedRun,
            progress: progress
        )

        if matchingReadIds.isEmpty {
            throw TaxonomyExtractionError.noMatchingReads
        }

        let matchCount = matchingReadIds.count
        logger.info("Found \(matchCount, privacy: .public) matching reads")
        progress?(0.30, "Extracting \(matchCount) reads...")

        // Phase 3: Filter each FASTQ file using ReadExtractionService (0.30 -- 0.95)
        // ReadExtractionService delegates to seqkit grep, which is 10-50x faster than
        // line-by-line Swift FASTQ parsing because it uses optimized C I/O and handles .gz natively.
        try Task.checkCancellation()

        let outputs = try await extractReadIDs(
            matchingReadIds,
            from: config.sourceFiles,
            matching: config.keepReadPairs || pairedRun ? .fragmentName : .firstWord,
            matePairStarts: Set(matePairStarts),
            outputDirectory: config.outputFile.deletingLastPathComponent(),
            baseName: config.outputFile.deletingPathExtension().lastPathComponent,
            progress: progress
        )
        return (outputs.urls, targetTaxIds, outputs.readCount)
    }

    /// Runs seqkit grep with the read IDs over each source file, one output
    /// per source in order. One source runs as it always has. Several sources
    /// run one at a time, and a source holding none of the reads gives nil,
    /// so the R1 and R2 files of a taxon whose reads were all merged do not
    /// fail its merged file (D7a). A pair of files that starts at an index of
    /// `matePairStarts` is read in step instead, as kraken2 read it.
    /// `matching` is the fragment-name rule when mates are kept together or
    /// kraken2 named fragments, so a mate named `X/1` matches `X` (D7c).
    private func extractReadIDs(
        _ readIDs: Set<String>,
        from sources: [URL],
        matching: ReadIDMatching,
        matePairStarts: Set<Int>,
        outputDirectory: URL,
        baseName: String,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (urls: [URL?], readCount: Int) {
        let service = ReadExtractionService(toolRunner: NativeToolRunner.shared)
        func config(_ files: [URL], _ name: String) -> ReadIDExtractionConfig {
            ReadIDExtractionConfig(
                sourceFASTQs: files,
                readIDs: readIDs,
                keepReadPairs: matching == .fragmentName,
                outputDirectory: outputDirectory,
                outputBaseName: name
            )
        }
        guard matePairStarts.isEmpty else {
            return try await extractWithMatePairs(
                readIDs, from: sources, matePairStarts: matePairStarts, outputDirectory: outputDirectory, baseName: baseName,
                extractOne: { source, name, index in
                    try await service.extractByReadIDs(config: config([source], name), matching: matching) { fraction, message in
                        progress?(0.30 + (Double(index) + fraction) * 0.65 / Double(sources.count), message)
                    }
                }
            )
        }
        guard sources.count > 1 else {
            let result = try await service.extractByReadIDs(config: config(sources, baseName), matching: matching) { fraction, message in
                // Map service progress (0..1) into our pipeline range (0.30..0.95)
                progress?(0.30 + fraction * 0.65, message)
            }
            return (result.fastqURLs, result.readCount)
        }
        var urls: [URL?] = []
        var readCount = 0
        let share = 0.65 / Double(sources.count)
        for (index, source) in sources.enumerated() {
            let name = "\(baseName)_R\(index + 1)"
            do {
                let result = try await service.extractByReadIDs(config: config([source], name), matching: matching) { fraction, message in
                    progress?(0.30 + (Double(index) + fraction) * share, message)
                }
                urls.append(result.fastqURLs.first)
                readCount += result.readCount
            } catch ExtractionError.emptyExtraction {
                // seqkit leaves an empty output behind.
                let empty = outputDirectory.appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(name)).fastq.gz")
                try? FileManager.default.removeItem(at: empty)
                urls.append(nil)
            }
        }
        guard readCount > 0 else { throw ExtractionError.emptyExtraction }
        return (urls, readCount)
    }


    // MARK: - Descendant Collection

    /// Collects all descendant tax IDs for the given set of tax IDs.
    ///
    /// For each tax ID in the input set, this method finds the corresponding
    /// node in the taxonomy tree and collects the tax IDs of all descendants.
    ///
    /// - Parameters:
    ///   - taxIds: The starting set of tax IDs.
    ///   - tree: The taxonomy tree.
    /// - Returns: A set containing the input tax IDs and all descendant tax IDs.
    public func collectDescendantTaxIds(_ taxIds: Set<Int>, tree: TaxonTree) -> Set<Int> {
        var result = taxIds
        for taxId in taxIds {
            guard let node = tree.node(taxId: taxId) else { continue }
            for descendant in node.allDescendants() {
                result.insert(descendant.taxId)
            }
        }
        return result
    }

    // MARK: - Read ID Building

    /// Parses the Kraken2 per-read output to find read IDs matching target taxa.
    ///
    /// Uses line-by-line buffered reading to avoid loading the entire file into
    /// memory for large datasets. A gzip file is inflated in this process one
    /// chunk at a time (`InProcessGzipReader`), so no child process runs.
    ///
    /// - Parameters:
    ///   - classificationURL: Path to the Kraken2 per-read output file.
    ///   - targetTaxIds: The set of taxonomy IDs to match.
    ///   - progress: Optional progress callback.
    /// - Returns: A set of read IDs assigned to any of the target taxa.
    /// - Throws: ``TaxonomyExtractionError`` on file read failure.
    private func buildReadIdSet(
        classificationURL: URL,
        targetTaxIds: Set<Int>,
        keepReadPairs: Bool = true,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> Set<String> {
        let indexURL = KrakenIndexDatabase.indexURL(for: classificationURL)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let index = try KrakenIndexDatabase(url: indexURL)
                defer { index.close() }
                if index.canResolve(taxIds: targetTaxIds) {
                    let readIds = try index.readIds(forTaxIds: targetTaxIds)
                    progress?(0.30, "Loaded \(readIds.count) read IDs from Kraken2 index")
                    return normalizeReadIds(readIds, keepReadPairs: keepReadPairs)
                }
            } catch {
                logger.warning(
                    "Kraken index query failed at \(indexURL.path, privacy: .private(mask: .hash)); falling back to raw classification output: \(String(describing: error), privacy: .private(mask: .hash))"
                )
            }
        }

        guard FileManager.default.fileExists(atPath: classificationURL.path) else {
            throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
        }

        let isGzipped = ["gz", "gzip"].contains(classificationURL.pathExtension.lowercased())

        // Get file size for progress estimation
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: classificationURL.path
        )[.size] as? Int64) ?? 0

        var matchingReadIds = Set<String>()
        var bytesRead: Int64 = 0
        var residual = Data()
        let bufferSize = 1_048_576 // 1 MB read chunks

        /// Scans one chunk of the text, plain or inflated, with the lines the chunk before left unfinished.
        func consume(_ chunk: Data) {
            bytesRead += Int64(chunk.count)

            // Combine residual from previous chunk with current chunk
            var data = residual + chunk
            residual = Data()

            // Find the last newline -- everything after it is residual for next iteration
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                if lastNewline < data.endIndex - 1 {
                    residual = data[(lastNewline + 1)...]
                    data = data[...lastNewline]
                }
            } else if !chunk.isEmpty {
                // No newline found -- accumulate and wait for the next chunk
                residual = data
                return
            }

            // Process lines
            if let text = String(data: data, encoding: .utf8) {
                collectMatchingReadIds(
                    from: text,
                    targetTaxIds: targetTaxIds,
                    keepReadPairs: keepReadPairs,
                    into: &matchingReadIds
                )
            }

            // Report progress
            if fileSize > 0 {
                let fraction = 0.10 + 0.20 * (Double(bytesRead) / Double(fileSize))
                progress?(min(fraction, 0.30), "Scanning classification: \(matchingReadIds.count) matches...")
            }
        }

        if isGzipped {
            // Inflated in this process, so no child runs. A file that is not gzip, ends early or fails its CRC-32
            // ends in the error that a nonzero exit status of `gzip -dc` gave.
            do {
                try InProcessGzipReader.forEachChunk(of: classificationURL, chunkSize: bufferSize, consume)
            } catch {
                throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
            }
        } else {
            guard let handle = FileHandle(forReadingAtPath: classificationURL.path) else {
                throw TaxonomyExtractionError.classificationOutputNotFound(classificationURL)
            }
            while true {
                let chunk = handle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                consume(chunk)
            }
            handle.closeFile()
        }

        // Process remaining residual
        if !residual.isEmpty, let text = String(data: residual, encoding: .utf8) {
            collectMatchingReadIds(
                from: text,
                targetTaxIds: targetTaxIds,
                keepReadPairs: keepReadPairs,
                into: &matchingReadIds
            )
        }

        return matchingReadIds
    }

    private func normalizeReadIds(_ readIds: Set<String>, keepReadPairs: Bool) -> Set<String> {
        guard keepReadPairs else { return readIds }
        return Set(readIds.map { readId in
            if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                return String(readId.dropLast(2))
            }
            return readId
        })
    }

    private func collectMatchingReadIds(
        from text: String,
        targetTaxIds: Set<Int>,
        keepReadPairs: Bool,
        into matchingReadIds: inout Set<String>
    ) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Kraken2 output format: C/U \t readId \t taxId \t length \t kmerHits
            let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }

            let status = columns[0].trimmingCharacters(in: .whitespaces)
            guard status == "C" || status == "U" else { continue }

            let taxIdStr = columns[2].trimmingCharacters(in: .whitespaces)
            guard let taxId = Int(taxIdStr), targetTaxIds.contains(taxId) else { continue }
            guard status == "C" || taxId == 0 else { continue }

            var readId = String(columns[1].trimmingCharacters(in: .whitespaces))
            if keepReadPairs, readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                readId = String(readId.dropLast(2))
            }
            matchingReadIds.insert(readId)
        }
    }

    // MARK: - Provenance

    /// Records provenance for the extraction operation. `command` is the command the record names, the
    /// one `extract taxa-collection` gives for a collection file.
    func recordProvenance(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>,
        outputURLs: [URL],
        extractedCount: Int,
        runtime: TimeInterval,
        command: [String]
    ) async throws {
        let recorder = ProvenanceRecorder.shared
        let runID = await recorder.beginRun(
            name: "Taxonomy Read Extraction",
            parameters: extractionProvenanceParameters(
                config: config,
                resolvedTaxIds: resolvedTaxIds,
                outputURLs: outputURLs,
                extractedCount: extractedCount
            )
        )

        var inputs = config.sourceFiles.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
        } + [
            ProvenanceRecorder.fileRecord(url: config.classificationOutput, format: .text, role: .input),
        ]
        if let taxonomyReport = config.taxonomyReport {
            inputs.append(ProvenanceRecorder.fileRecord(url: taxonomyReport, format: .text, role: .input))
        }
        let outputs = outputURLs.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .output)
        }

        await recorder.recordStep(
            runID: runID,
            toolName: "TaxonomyExtractionPipeline",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: runtime
        )

        await recorder.completeRun(runID, status: .completed)

        let outputDir = outputURLs.first?.deletingLastPathComponent()
            ?? config.outputFile.deletingLastPathComponent()
        try await recorder.save(runID: runID, to: outputDir)
        try await writeFocusedOutputSidecars(
            recorder: recorder,
            runID: runID,
            outputs: outputs
        )
    }

    private func writeFocusedOutputSidecars(
        recorder: ProvenanceRecorder,
        runID: UUID,
        outputs: [FileRecord]
    ) async throws {
        // The record the save above wrote, which the recorder keeps among its recently saved runs.
        guard let envelope = await recorder.canonicalEnvelope(for: runID) else {
            throw ProvenanceError.runNotFound(runID)
        }
        let writer = ProvenanceWriter()
        for output in outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            let focusedEnvelope = envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output))
            try writer.write(
                focusedEnvelope,
                toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
            )
        }
    }

    private func extractionProvenanceParameters(
        config: TaxonomyExtractionConfig,
        resolvedTaxIds: Set<Int>,
        outputURLs: [URL],
        extractedCount: Int
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "taxIds": .array(config.taxIds.sorted().map { .integer($0) }),
            "resolvedTaxIds": .array(resolvedTaxIds.sorted().map { .integer($0) }),
            "includeChildren": .boolean(config.includeChildren),
            "keepReadPairs": .boolean(config.keepReadPairs),
            "extractedReads": .integer(extractedCount),
            "pairedEnd": .boolean(config.isPairedEnd),
            "sourceFiles": .array(config.sourceFiles.map { .string($0.path) }),
            "requestedOutputFiles": .array(config.outputFiles.map { .string($0.path) }),
            "actualOutputFiles": .array(outputURLs.map { .string($0.path) }),
            "classificationOutput": .string(config.classificationOutput.path),
        ]
        if let taxonomyReport = config.taxonomyReport {
            parameters["taxonomyReport"] = .string(taxonomyReport.path)
        }
        return parameters
    }
}

// MARK: - InProcessGzipReader

/// Inflates a gzip file in this process, as `gzip -dc` did for the pipeline, with no child process.
///
/// Every member is read in order, so a BGZF file or files joined with `cat` give one text. The CRC-32 and the
/// length of each member are checked. A file that is not gzip, data that ends early, a trailer that does not match
/// and bytes after the last member all throw, as each nonzero exit status of `gzip -dc` did. Apple Compression
/// inflates the raw DEFLATE data of a member one chunk at a time, so memory holds a few chunks however long the
/// text is.
///
/// Apple Compression reports every input byte as consumed when a DEFLATE stream ends, so it does not say where
/// the 8-byte trailer (the CRC-32, then the length modulo 2^32, both little-endian) starts. The trailer is the
/// place in the last bytes handed over where the CRC-32 and the length of the decoded member stand and the next
/// member or the end of the file follows. `GzipPrefixDecoder` in LungfishIO finds a member boundary by the length
/// alone.
private final class InProcessGzipReader {

    private enum Failure: Error {
        case notGzip, truncated, corrupt
    }

    /// The input handed to the decoder in one call, which bounds the bytes searched for a trailer.
    private static let feedSize = 65_536

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private let handle: FileHandle
    private let chunkSize: Int
    /// Compressed bytes read and not yet dropped. `position` is the next one to take.
    private var buffer: [UInt8] = []
    private var position = 0
    private var fileEnded = false

    private init(handle: FileHandle, chunkSize: Int) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    /// Hands the decoded text of the file at `url` to `body` in chunks of at most `chunkSize` bytes.
    static func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) -> Void) throws {
        let reader = InProcessGzipReader(handle: try FileHandle(forReadingFrom: url), chunkSize: chunkSize)
        defer { try? reader.handle.close() }
        var members = 0
        while true {
            reader.compact()
            if reader.position == reader.buffer.count {
                guard try reader.readMore() else {
                    // The end of the file after a member ends the text. A file with no member at all is empty.
                    if members > 0 { return }
                    throw Failure.truncated
                }
            }
            try reader.decodeMember(body)
            members += 1
        }
    }

    /// Drops the bytes before `position`.
    private func compact() {
        guard position > 0 else { return }
        buffer.removeSubrange(0..<position)
        position = 0
    }

    /// Appends the next piece of the file. False at the end of the file.
    private func readMore() throws -> Bool {
        guard !fileEnded else { return false }
        guard let piece = try handle.read(upToCount: chunkSize), !piece.isEmpty else {
            fileEnded = true
            return false
        }
        buffer.append(contentsOf: piece)
        return true
    }

    /// Makes `count` bytes available from `position`.
    private func need(_ count: Int) throws {
        while buffer.count - position < count {
            guard try readMore() else { throw Failure.truncated }
        }
    }

    /// Whether a gzip member starts at `index`, or the file ends there.
    private func startsMember(at index: Int) -> Bool {
        if index == buffer.count { return fileEnded }
        return index + 3 <= buffer.count && buffer[index] == 0x1F && buffer[index + 1] == 0x8B && buffer[index + 2] == 8
    }

    /// Decodes the member that starts at `position` and leaves `position` at the byte after its trailer.
    private func decodeMember(_ body: (Data) -> Void) throws {
        try need(10)
        guard buffer[position] == 0x1F, buffer[position + 1] == 0x8B, buffer[position + 2] == 8 else {
            throw Failure.notGzip
        }
        let flags = buffer[position + 3]
        position += 10
        if flags & 0x04 != 0 {
            try need(2)
            let extraLength = Int(buffer[position]) | Int(buffer[position + 1]) << 8
            position += 2
            try need(extraLength)
            position += extraLength
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            repeat {
                try need(1)
                position += 1
            } while buffer[position - 1] != 0
        }
        if flags & 0x02 != 0 {
            try need(2)
            position += 2
        }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt
        }
        defer { compression_stream_destroy(stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }

        var crc: UInt32 = 0xFFFF_FFFF
        var decodedLength = 0
        var feedStart = position
        var feedEnd = position
        var ended = false
        while !ended {
            if position == buffer.count {
                // Everything handed over so far is inflated, and none of it can hold the trailer.
                buffer.removeAll(keepingCapacity: true)
                position = 0
                guard try readMore() else { throw Failure.truncated }
            }
            feedStart = position
            feedEnd = min(buffer.count, position + Self.feedSize)
            try buffer.withUnsafeBufferPointer { source in
                stream.pointee.src_ptr = source.baseAddress! + feedStart
                stream.pointee.src_size = feedEnd - feedStart
                while true {
                    stream.pointee.dst_ptr = output
                    stream.pointee.dst_size = chunkSize
                    let status = compression_stream_process(stream, 0)
                    let produced = chunkSize - stream.pointee.dst_size
                    if produced > 0 {
                        crc = Self.update(crc, with: output, count: produced)
                        decodedLength += produced
                        body(Data(bytes: output, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END {
                        ended = true
                        return
                    }
                    guard status == COMPRESSION_STATUS_OK else { throw Failure.corrupt }
                    // The decoder keeps input of its own, so it gives output on a later call even when the output
                    // buffer was not full, and it reports the end of the stream on such a call. It wants more input
                    // only when a call gives nothing.
                    if produced == 0 {
                        if stream.pointee.src_size == 0 { return }
                        throw Failure.corrupt
                    }
                }
            }
            position = feedEnd
        }

        // The trailer starts in the last bytes handed over or right after them. Read far enough past them to see
        // the 8 bytes of a trailer and the start of what follows.
        while buffer.count < feedEnd + 11 {
            guard try readMore() else { break }
        }
        let expectedCRC = ~crc
        let expectedLength = UInt32(truncatingIfNeeded: decodedLength)
        let lastStart = min(feedEnd, buffer.count - 8)
        var start = feedStart
        while start <= lastStart {
            if Self.littleEndian32(buffer, at: start) == expectedCRC,
               Self.littleEndian32(buffer, at: start + 4) == expectedLength,
               startsMember(at: start + 8) {
                position = start + 8
                return
            }
            start += 1
        }
        throw Failure.corrupt
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    /// The running CRC-32 (not yet inverted) after `count` more bytes.
    private static func update(_ crc: UInt32, with bytes: UnsafePointer<UInt8>, count: Int) -> UInt32 {
        var value = crc
        crcTable.withUnsafeBufferPointer { table in
            for index in 0..<count {
                value = table[Int((value ^ UInt32(bytes[index])) & 0xFF)] ^ (value >> 8)
            }
        }
        return value
    }
}
