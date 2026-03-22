// ExactBarcodeDemux.swift - Swift-native exact barcode demultiplexer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ExactBarcodeDemux")

// MARK: - Configuration

/// Configuration for the exact barcode demultiplexing engine.
///
/// This engine performs exact string matching (zero mismatches) for asymmetric
/// PacBio-style barcodes that may appear anywhere within long reads. It searches
/// four orientation patterns per sample to handle reads in any strand orientation,
/// including ONT reads that sequence through SMRTbell adapters.
public struct ExactBarcodeDemuxConfig: Sendable {
    /// Input FASTQ file URLs (gzipped or uncompressed).
    /// For multi-file bundles (ONT chunks), pass all chunk URLs in order.
    /// For single-file bundles, pass a single-element array.
    public let inputURLs: [URL]

    /// Per-sample barcode pair definitions.
    public let sampleBarcodes: [SampleBarcodePair]

    /// Minimum insert length (bp) required between the left and right barcode hits.
    /// Reads shorter than `2 * barcodeLength + minimumInsert` are skipped.
    /// Default: 2000.
    public let minimumInsert: Int

    /// Maximum number of preview records to retain per sample.
    public let previewLimit: Int

    /// A sample's forward and reverse barcode sequences.
    public struct SampleBarcodePair: Sendable {
        public let sampleName: String
        public let forwardSequence: String
        public let reverseSequence: String

        public init(sampleName: String, forwardSequence: String, reverseSequence: String) {
            self.sampleName = sampleName
            self.forwardSequence = forwardSequence.uppercased()
            self.reverseSequence = reverseSequence.uppercased()
        }
    }

    public init(
        inputURLs: [URL],
        sampleBarcodes: [SampleBarcodePair],
        minimumInsert: Int = 2000,
        previewLimit: Int = 1000
    ) {
        self.inputURLs = inputURLs
        self.sampleBarcodes = sampleBarcodes
        self.minimumInsert = minimumInsert
        self.previewLimit = previewLimit
    }

    /// Convenience initializer for single-file input.
    public init(
        inputURL: URL,
        sampleBarcodes: [SampleBarcodePair],
        minimumInsert: Int = 2000,
        previewLimit: Int = 1000
    ) {
        self.inputURLs = [inputURL]
        self.sampleBarcodes = sampleBarcodes
        self.minimumInsert = minimumInsert
        self.previewLimit = previewLimit
    }
}

// MARK: - Result Types

/// Lightweight FASTQ record stored as raw lines (avoids quality parsing overhead).
public struct FASTQRawRecord: Sendable {
    /// Full header line including '@' prefix.
    public let header: String
    /// Nucleotide sequence.
    public let sequence: String
    /// Separator line (typically "+").
    public let separator: String
    /// Quality score string.
    public let quality: String

    /// Read ID extracted from header (without '@', without description).
    public var readID: String {
        let h = header.hasPrefix("@") ? String(header.dropFirst()) : header
        if let spaceIndex = h.firstIndex(of: " ") {
            return String(h[h.startIndex..<spaceIndex])
        }
        return h
    }

    /// Number of bases in this record.
    public var baseCount: Int { sequence.count }

    /// Formats the record as a 4-line FASTQ entry (with trailing newline).
    public var fastqString: String {
        "\(header)\n\(sequence)\n\(separator)\n\(quality)\n"
    }
}

/// Per-sample result from the exact barcode demux engine.
public struct ExactBarcodeSampleResult: Sendable {
    /// Sample name (sanitized for filesystem use).
    public let sampleName: String
    /// Forward barcode sequence used for matching.
    public let forwardBarcodeSeq: String
    /// Reverse barcode sequence used for matching.
    public let reverseBarcodeSeq: String
    /// Ordered read IDs that matched this sample.
    public let readIDs: [String]
    /// First N preview records (for preview.fastq).
    public let previewRecords: [FASTQRawRecord]
    /// Total reads assigned to this sample.
    public let readCount: Int
    /// Total bases assigned to this sample.
    public let baseCount: Int64
    /// Minimum read length.
    public let minReadLength: Int
    /// Maximum read length.
    public let maxReadLength: Int
    /// Read length histogram for N50/median computation.
    public let readLengthHistogram: [Int: Int]
}

/// Aggregate result from exact barcode demultiplexing.
public struct ExactBarcodeDemuxResult: Sendable {
    /// Total reads processed (including skipped short reads).
    public let totalReads: Int
    /// Total reads assigned to any sample.
    public let assignedReads: Int
    /// Per-sample results (only samples with >= 1 read).
    public let sampleResults: [ExactBarcodeSampleResult]
    /// Read IDs not assigned to any sample.
    public let unassignedReadIDs: [String]
    /// Preview records for unassigned reads.
    public let unassignedPreview: [FASTQRawRecord]
    /// Total unassigned reads.
    public let unassignedReadCount: Int
    /// Total unassigned bases.
    public let unassignedBaseCount: Int64
    /// Min read length for unassigned.
    public let unassignedMinReadLength: Int
    /// Max read length for unassigned.
    public let unassignedMaxReadLength: Int
}

// MARK: - Engine

/// Exact barcode demultiplexing engine for asymmetric PacBio-style barcodes.
///
/// For each sample's barcode pair (fwd, rev), searches four orientation patterns:
/// - Pattern 1: `fwd ... rc(rev)` — standard orientation
/// - Pattern 2: `rev ... rc(fwd)` — reverse complement read
/// - Pattern 3: `fwd ... rev` — both forward (ONT through SMRTbell adapter)
/// - Pattern 4: `rc(rev) ... rc(fwd)` — both reverse complement
///
/// Matching is exact (zero mismatches) with a minimum insert distance between
/// left and right barcode hits. Reads are assigned to the first matching sample.
public enum ExactBarcodeDemux {

    /// Runs exact barcode demultiplexing.
    ///
    /// Streams through the input FASTQ once, collecting per-sample read IDs,
    /// preview records, and statistics. No intermediate FASTQ files are written.
    ///
    /// - Parameters:
    ///   - config: Demux configuration with input file and sample barcodes.
    ///   - progress: Progress callback `(fraction, message)`.
    /// - Returns: Demux result with per-sample virtual bundle data.
    public static func run(
        config: ExactBarcodeDemuxConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ExactBarcodeDemuxResult {
        guard !config.inputURLs.isEmpty else {
            return ExactBarcodeDemuxResult(
                totalReads: 0, assignedReads: 0, sampleResults: [],
                unassignedReadIDs: [], unassignedPreview: [],
                unassignedReadCount: 0, unassignedBaseCount: 0,
                unassignedMinReadLength: 0, unassignedMaxReadLength: 0
            )
        }

        let rc = PlatformAdapters.reverseComplement

        // Estimate total bytes for progress reporting
        let totalInputBytes = config.inputURLs.reduce(Int64(0)) { $0 + $1.fileSizeBytes }

        // Build lookup table: leftBarcode → [(rightBarcode, sampleIndex)]
        var leftToRight: [String: [(rightBarcode: String, sampleIndex: Int)]] = [:]

        // All barcodes should be the same length for PacBio kits.
        // Use the first barcode's length; if mixed, take the max.
        let barcodeLength = config.sampleBarcodes.map {
            max($0.forwardSequence.count, $0.reverseSequence.count)
        }.max() ?? 0

        for (index, sample) in config.sampleBarcodes.enumerated() {
            let fwd = sample.forwardSequence
            let rev = sample.reverseSequence
            let rcFwd = rc(fwd)
            let rcRev = rc(rev)

            // Pattern 1: fwd ... rc(rev)
            leftToRight[fwd, default: []].append((rightBarcode: rcRev, sampleIndex: index))
            // Pattern 2: rev ... rc(fwd)
            leftToRight[rev, default: []].append((rightBarcode: rcFwd, sampleIndex: index))
            // Pattern 3: fwd ... rev (both forward orientation)
            leftToRight[fwd, default: []].append((rightBarcode: rev, sampleIndex: index))
            // Pattern 4: rc(rev) ... rc(fwd) (both RC orientation)
            leftToRight[rcRev, default: []].append((rightBarcode: rcFwd, sampleIndex: index))
        }

        // Per-sample accumulators
        let sampleCount = config.sampleBarcodes.count
        var sampleReadIDs: [[String]] = Array(repeating: [], count: sampleCount)
        var samplePreviews: [[FASTQRawRecord]] = Array(repeating: [], count: sampleCount)
        var sampleReadCounts: [Int] = Array(repeating: 0, count: sampleCount)
        var sampleBaseCounts: [Int64] = Array(repeating: 0, count: sampleCount)
        var sampleMinLength: [Int] = Array(repeating: Int.max, count: sampleCount)
        var sampleMaxLength: [Int] = Array(repeating: 0, count: sampleCount)
        var sampleLengthHistograms: [[Int: Int]] = Array(repeating: [:], count: sampleCount)

        // Unassigned accumulators
        var unassignedReadIDs: [String] = []
        var unassignedPreview: [FASTQRawRecord] = []
        var unassignedReadCount = 0
        var unassignedBaseCount: Int64 = 0
        var unassignedMinLength = Int.max
        var unassignedMaxLength = 0

        var totalReads = 0
        var assignedReads = 0
        let minimumInsert = config.minimumInsert
        let previewLimit = config.previewLimit

        // Minimum read length to even attempt matching
        let minimumReadLength = 2 * barcodeLength + minimumInsert

        progress(0.0, "Starting exact barcode demultiplexing...")

        // Stream FASTQ records (4 lines at a time) across all input files.
        // Filter empty lines from GzipInputStream which yields trailing empties
        // from split(separator: "\n", omittingEmptySubsequences: false).
        let lines = URL.multiFileLinesAutoDecompressing(config.inputURLs)
        var lineBuffer: [String] = []
        lineBuffer.reserveCapacity(4)

        for try await line in lines {
            if line.isEmpty && lineBuffer.isEmpty { continue }
            lineBuffer.append(line)
            guard lineBuffer.count == 4 else { continue }

            let record = FASTQRawRecord(
                header: lineBuffer[0],
                sequence: lineBuffer[1],
                separator: lineBuffer[2],
                quality: lineBuffer[3]
            )
            lineBuffer.removeAll(keepingCapacity: true)

            totalReads += 1

            if totalReads % 100_000 == 0 {
                // Estimate progress from average read size × reads processed vs total input bytes
                let estimatedFraction: Double
                if totalInputBytes > 0 {
                    let avgBytesPerRead = Double(record.baseCount + 50) * 1.1 // ~10% overhead for headers/quality/newlines
                    let estimatedBytesProcessed = avgBytesPerRead * Double(totalReads)
                    estimatedFraction = min(0.90, estimatedBytesProcessed / Double(totalInputBytes))
                } else {
                    estimatedFraction = 0.0
                }
                progress(estimatedFraction, "Processed \(totalReads) reads, \(assignedReads) assigned...")
            }

            let seq = record.sequence
            let seqLen = seq.count

            // Skip reads too short to contain barcodes + insert
            if seqLen < minimumReadLength {
                unassignedReadIDs.append(record.readID)
                if unassignedPreview.count < previewLimit {
                    unassignedPreview.append(record)
                }
                unassignedReadCount += 1
                unassignedBaseCount += Int64(record.baseCount)
                unassignedMinLength = min(unassignedMinLength, seqLen)
                unassignedMaxLength = max(unassignedMaxLength, seqLen)
                continue
            }

            // Search for matching barcode pair
            var matched = false
            for (leftBC, targets) in leftToRight {
                if matched { break }

                // Find the left barcode anywhere in the read
                guard let leftRange = seq.range(of: leftBC) else { continue }
                let leftEnd = seq.distance(from: seq.startIndex, to: leftRange.upperBound)

                for target in targets {
                    let searchStart = leftEnd + minimumInsert
                    if searchStart >= seqLen { continue }

                    // Search for the right barcode after the minimum insert gap
                    let searchStartIndex = seq.index(seq.startIndex, offsetBy: searchStart)
                    let searchSubstring = seq[searchStartIndex...]

                    if searchSubstring.range(of: target.rightBarcode) != nil {
                        let idx = target.sampleIndex
                        sampleReadIDs[idx].append(record.readID)
                        if samplePreviews[idx].count < previewLimit {
                            samplePreviews[idx].append(record)
                        }
                        sampleReadCounts[idx] += 1
                        sampleBaseCounts[idx] += Int64(record.baseCount)
                        sampleMinLength[idx] = min(sampleMinLength[idx], seqLen)
                        sampleMaxLength[idx] = max(sampleMaxLength[idx], seqLen)
                        sampleLengthHistograms[idx][seqLen, default: 0] += 1
                        assignedReads += 1
                        matched = true
                        break
                    }
                }
            }

            if !matched {
                unassignedReadIDs.append(record.readID)
                if unassignedPreview.count < previewLimit {
                    unassignedPreview.append(record)
                }
                unassignedReadCount += 1
                unassignedBaseCount += Int64(record.baseCount)
                unassignedMinLength = min(unassignedMinLength, seqLen)
                unassignedMaxLength = max(unassignedMaxLength, seqLen)
            }
        }

        // Handle any leftover lines (incomplete record at end of file)
        if !lineBuffer.isEmpty {
            logger.warning("Input FASTQ had \(lineBuffer.count) trailing lines (incomplete record)")
        }

        progress(0.95, "Building results...")

        // Build per-sample results (omit samples with 0 reads)
        var sampleResults: [ExactBarcodeSampleResult] = []
        for (index, sample) in config.sampleBarcodes.enumerated() {
            guard sampleReadCounts[index] > 0 else { continue }
            sampleResults.append(ExactBarcodeSampleResult(
                sampleName: sample.sampleName,
                forwardBarcodeSeq: sample.forwardSequence,
                reverseBarcodeSeq: sample.reverseSequence,
                readIDs: sampleReadIDs[index],
                previewRecords: samplePreviews[index],
                readCount: sampleReadCounts[index],
                baseCount: sampleBaseCounts[index],
                minReadLength: sampleMinLength[index],
                maxReadLength: sampleMaxLength[index],
                readLengthHistogram: sampleLengthHistograms[index]
            ))
        }

        logger.info("Exact barcode demux complete: \(totalReads) total, \(assignedReads) assigned to \(sampleResults.count) sample(s)")

        progress(1.0, "Demultiplexing complete.")

        return ExactBarcodeDemuxResult(
            totalReads: totalReads,
            assignedReads: assignedReads,
            sampleResults: sampleResults,
            unassignedReadIDs: unassignedReadIDs,
            unassignedPreview: unassignedPreview,
            unassignedReadCount: unassignedReadCount,
            unassignedBaseCount: unassignedBaseCount,
            unassignedMinReadLength: unassignedReadCount > 0 ? unassignedMinLength : 0,
            unassignedMaxReadLength: unassignedMaxLength
        )
    }

    /// Computes `FASTQDatasetStatistics` from collected demux metrics.
    public static func computeStatistics(
        readCount: Int,
        baseCount: Int64,
        minReadLength: Int,
        maxReadLength: Int,
        readLengthHistogram: [Int: Int]
    ) -> FASTQDatasetStatistics {
        guard readCount > 0 else { return .empty }

        let meanLength = Double(baseCount) / Double(readCount)

        // Compute median from histogram
        let sortedLengths = readLengthHistogram.sorted { $0.key < $1.key }
        var cumulative = 0
        var medianLength = 0
        let medianTarget = readCount / 2
        for (length, count) in sortedLengths {
            cumulative += count
            if cumulative > medianTarget {
                medianLength = length
                break
            }
        }

        // Compute N50 from histogram
        var n50Length = 0
        let halfBases = baseCount / 2
        var cumulativeBases: Int64 = 0
        for (length, count) in sortedLengths.reversed() {
            cumulativeBases += Int64(length) * Int64(count)
            if cumulativeBases >= halfBases {
                n50Length = length
                break
            }
        }

        return FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: meanLength,
            minReadLength: minReadLength,
            maxReadLength: maxReadLength,
            medianReadLength: medianLength,
            n50ReadLength: n50Length,
            meanQuality: 0,
            q20Percentage: 0,
            q30Percentage: 0,
            gcContent: 0,
            readLengthHistogram: readLengthHistogram,
            qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }
}
