// AssemblyReadType.swift - Read-class model for the shared assembly surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation
import LungfishIO

/// Visible read classes supported by the v1 assembly experience.
public enum AssemblyReadType: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    /// Human-readable display name shown in the shared assembly UI.
    public var displayName: String {
        switch self {
        case .illuminaShortReads: return "Illumina short reads"
        case .ontReads: return "ONT reads"
        case .pacBioHiFi: return "PacBio HiFi/CCS"
        }
    }

    /// Short explanation of the expected input class.
    public var detail: String {
        switch self {
        case .illuminaShortReads:
            return "Single-end or paired-end short reads from Illumina-style data."
        case .ontReads:
            return "Single-file Oxford Nanopore long reads."
        case .pacBioHiFi:
            return "Single-file PacBio HiFi/CCS long reads."
        }
    }

    /// Maps sequencing-platform detection onto the supported v1 assembly classes.
    public static func detect(from platform: LungfishIO.SequencingPlatform) -> Self? {
        switch platform {
        case .illumina: return .illuminaShortReads
        case .oxfordNanopore: return .ontReads
        case .pacbio: return nil
        default: return nil
        }
    }

    /// Maps the workflow-level ingestion platform model onto v1 assembly classes.
    public static func detect(fromWorkflowPlatform platform: SequencingPlatform) -> Self? {
        switch platform {
        case .illumina: return .illuminaShortReads
        case .ont: return .ontReads
        case .pacbio: return nil
        default: return nil
        }
    }

    /// Best-effort FASTQ-based read-type detection.
    public static func detect(fromFASTQ url: URL) -> Self? {
        guard let header = readFASTQHeader(from: url) else {
            return nil
        }
        return detect(fromFASTQHeader: header)
    }

    /// Best-effort detection for an app-selected assembly input.
    ///
    /// Supports raw FASTQ files, `.lungfishfastq` bundles, and files inside bundles.
    /// Falls back to persisted sequencing-platform metadata when header sniffing
    /// is inconclusive.
    public static func detect(fromInputURL url: URL) -> Self? {
        guard let fastqURL = resolveFASTQURL(forInputURL: url) else {
            return nil
        }

        let persistedMetadata = FASTQMetadataStore.load(for: fastqURL)

        if let explicitReadType = persistedMetadata?.assemblyReadType.flatMap(Self.init(persistedReadType:)) {
            return explicitReadType
        }

        if let detected = detect(fromFASTQ: fastqURL) {
            return detected
        }

        if let platform = persistedMetadata?.sequencingPlatform {
            return detect(from: platform)
        }

        return nil
    }

    /// Best-effort multi-input detection, preserving stable case order.
    public static func detectAll(fromFASTQs urls: [URL]) -> [Self] {
        let detected = Set(urls.compactMap(detect(fromFASTQ:)))
        return allCases.filter { detected.contains($0) }
    }

    /// Stable CLI spelling for the shared assembly surface.
    public var cliArgument: String {
        switch self {
        case .illuminaShortReads:
            return "illumina-short-reads"
        case .ontReads:
            return "ont-reads"
        case .pacBioHiFi:
            return "pacbio-hifi"
        }
    }

    /// Parses the CLI spelling used by the app and CLI entry points.
    public init?(cliArgument: String) {
        switch cliArgument {
        case "illumina-short-reads":
            self = .illuminaShortReads
        case "ont-reads":
            self = .ontReads
        case "pacbio-hifi":
            self = .pacBioHiFi
        default:
            return nil
        }
    }

    public init?(persistedReadType: FASTQAssemblyReadType) {
        switch persistedReadType {
        case .illuminaShortReads:
            self = .illuminaShortReads
        case .ontReads:
            self = .ontReads
        case .pacBioHiFi:
            self = .pacBioHiFi
        }
    }

    /// Best-effort header-based detection that only promotes PacBio reads when CCS is explicit.
    public static func detect(fromFASTQHeader header: String) -> Self? {
        let stripped = header.hasPrefix("@") ? String(header.dropFirst()) : header

        if stripped.contains("/ccs") {
            return .pacBioHiFi
        }

        guard let platform = LungfishIO.SequencingPlatform.detect(fromHeader: header) else {
            return nil
        }
        return detect(from: platform)
    }

    private static func readFASTQHeader(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }

        let text: String?
        if data.count >= 2, data[0] == 0x1F, data[1] == 0x8B {
            text = decompressGzipPrefix(data: data).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            text = String(data: data, encoding: .utf8)
        }

        guard let text, let firstLine = text.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        return String(firstLine)
    }

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

    private static func resolveFASTQURL(forInputURL url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if let resolved = FASTQBundle.resolvePrimaryFASTQURL(for: standardizedURL) {
            return resolved
        }

        let parentURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        return FASTQBundle.resolvePrimaryFASTQURL(for: parentURL)
    }
}
