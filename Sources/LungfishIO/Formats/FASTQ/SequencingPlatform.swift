// SequencingPlatform.swift - Sequencing platform identification and capabilities
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation

/// Identifies the sequencing platform that generated a FASTQ dataset.
///
/// Used to select platform-appropriate adapter contexts, error rates,
/// and demultiplexing strategies.
public enum SequencingPlatform: String, Codable, Sendable, CaseIterable {
    case illumina
    case oxfordNanopore
    case pacbio
    case element
    case ultima
    case mgi
    case unknown

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .illumina:       return "Illumina"
        case .oxfordNanopore: return "Oxford Nanopore"
        case .pacbio:         return "PacBio"
        case .element:        return "Element Biosciences"
        case .ultima:         return "Ultima Genomics"
        case .mgi:            return "MGI / DNBSEQ"
        case .unknown:        return "Unknown"
        }
    }

    /// Whether reads can appear in either orientation (forward or reverse complement).
    ///
    /// Long-read platforms (ONT, PacBio) sequence both strands randomly;
    /// short-read platforms always read from a defined primer.
    public var readsCanBeReverseComplemented: Bool {
        switch self {
        case .oxfordNanopore, .pacbio: return true
        default: return false
        }
    }

    /// Whether this platform demultiplexes via separate index reads
    /// (i.e., demux is done before the user receives FASTQ files).
    ///
    /// When true, the app only needs to trim residual adapter read-through,
    /// not perform barcode-based demultiplexing.
    public var indexesInSeparateReads: Bool {
        switch self {
        case .illumina, .element, .ultima, .mgi: return true
        case .oxfordNanopore, .pacbio: return false
        default: return false
        }
    }

    /// Whether poly-G trimming may be needed (two-color SBS platforms).
    ///
    /// On NextSeq/NovaSeq (Illumina) and AVITI (Element), no-signal clusters
    /// produce runs of G at read ends.
    public var mayNeedPolyGTrimming: Bool {
        switch self {
        case .illumina, .element: return true
        default: return false
        }
    }

    /// Default poly-G trim quality threshold for two-color platforms.
    ///
    /// cutadapt `--nextseq-trim=N` uses this quality score to trim trailing
    /// poly-G artifacts. Only meaningful when `mayNeedPolyGTrimming` is true.
    /// Returns nil for platforms that don't need poly-G trimming.
    public var defaultPolyGTrimQuality: Int? {
        mayNeedPolyGTrimming ? 20 : nil
    }

    /// Recommended cutadapt error rate for this platform.
    ///
    /// ONT has higher error rates at read ends / adapter junctions (~5-10%),
    /// but 0.20 is overly permissive and risks false barcode matches.
    /// 0.15 balances sensitivity with specificity for noisy long reads.
    /// PacBio HiFi and short-read platforms are Q30+ (~0.1% error).
    public var recommendedErrorRate: Double {
        switch self {
        case .oxfordNanopore: return 0.15
        default:              return 0.10
        }
    }

    /// Recommended minimum overlap for cutadapt barcode matching.
    ///
    /// Short-read platforms use 5 bp minimum to reduce spurious matches
    /// while retaining sensitivity for standard 6-8 bp index sequences.
    public var recommendedMinimumOverlap: Int {
        switch self {
        case .oxfordNanopore: return 20
        case .pacbio:         return 14
        default:              return 5
        }
    }

    /// Detects the sequencing platform from a FASTQ header line.
    ///
    /// ONT headers contain `basecall_model_version_id=` or `runid=` with 40-char hex.
    /// PacBio CCS headers contain `ccs` or `zmw`.
    /// Illumina headers match the pattern `@INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y`.
    /// Returns nil if the platform cannot be determined.
    public static func detect(fromHeader header: String) -> SequencingPlatform? {
        // ONT: headers contain key=value metadata from MinKNOW basecaller
        if header.contains("basecall_model_version_id=")
            || header.contains("basecall_gpu=")
            || header.contains("start_time=") && header.contains("flow_cell_id=") {
            return .oxfordNanopore
        }
        // PacBio CCS: movie/zmw format like m64001_190101_000000/123/ccs
        if header.contains("/ccs") || header.contains("zmw") {
            return .pacbio
        }
        // Illumina: @INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y format (7 colon-separated fields)
        let stripped = header.hasPrefix("@") ? String(header.dropFirst()) : header
        let colonFields = stripped.split(separator: ":").count
        if colonFields >= 7 {
            return .illumina
        }
        return nil
    }

    /// Detects the sequencing platform by reading the first header of a FASTQ file.
    ///
    /// Handles both plain text and gzip-compressed FASTQ files.
    /// Reads only the first line, so this is very fast.
    public static func detect(fromFASTQ url: URL) -> SequencingPlatform? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }

        let text: String?
        if data.count >= 2, data[0] == 0x1F, data[1] == 0x8B {
            // Gzip-compressed: decompress to get the header
            text = decompressGzipPrefix(data: data).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            text = String(data: data, encoding: .utf8)
        }

        guard let text, let firstLine = text.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        return detect(fromHeader: String(firstLine))
    }

    /// Decompresses the beginning of a gzip stream to extract header text.
    private static func decompressGzipPrefix(data: Data) -> Data? {
        guard data.count > 10 else { return nil }
        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0, data.count > offset + 2 {
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count else { return nil }

        let compressed = data.subdata(in: offset..<data.count)
        let bufferSize = 4096
        var output = Data(count: bufferSize)
        let size: Int = compressed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                guard let srcPtr = src.baseAddress, let dstPtr = dst.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr.assumingMemoryBound(to: UInt8.self), bufferSize,
                    srcPtr.assumingMemoryBound(to: UInt8.self), compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard size > 0 else { return nil }
        return output.prefix(size)
    }

    /// Maps legacy vendor strings to platform enum values.
    public init(vendor: String) {
        switch vendor.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "illumina":
            self = .illumina
        case "oxford-nanopore", "oxfordnanopore", "ont":
            self = .oxfordNanopore
        case "pacbio", "pacific-biosciences":
            self = .pacbio
        case "element", "element-biosciences":
            self = .element
        case "ultima", "ultima-genomics":
            self = .ultima
        case "mgi", "bgi", "dnbseq", "mgi-tech":
            self = .mgi
        default:
            self = .unknown
        }
    }
}
