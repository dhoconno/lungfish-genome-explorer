// MappingTool.swift - Neutral mapper metadata for the shared mapping surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation
import LungfishIO

public enum MappingTool: String, CaseIterable, Codable, Sendable {
    case minimap2
    case bwaMem2 = "bwa-mem2"
    case bowtie2
    case bbmap

    public var displayName: String {
        switch self {
        case .minimap2: return "minimap2"
        case .bwaMem2: return "BWA-MEM2"
        case .bowtie2: return "Bowtie2"
        case .bbmap: return "BBMap"
        }
    }

    public var environmentName: String { rawValue }

    public var executableName: String {
        switch self {
        case .minimap2: return "minimap2"
        case .bwaMem2: return "bwa-mem2"
        case .bowtie2: return "bowtie2"
        case .bbmap: return "bbmap.sh"
        }
    }
}

public enum MappingReadClass: String, CaseIterable, Codable, Sendable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi
    case pacBioCLR

    public var displayName: String {
        switch self {
        case .illuminaShortReads: return "Illumina short reads"
        case .ontReads: return "ONT reads"
        case .pacBioHiFi: return "PacBio HiFi"
        case .pacBioCLR: return "PacBio CLR"
        }
    }

    public static func detect(fromFASTQ url: URL) -> Self? {
        guard let header = readFASTQHeader(from: url) else {
            return nil
        }
        return detect(fromFASTQHeader: header)
    }

    public static func detect(fromFASTQHeader header: String) -> Self? {
        let stripped = header.hasPrefix("@") ? String(header.dropFirst()) : header
        let lowercased = stripped.lowercased()

        if lowercased.contains("/ccs") || lowercased.contains("ccs") {
            return .pacBioHiFi
        }

        guard let platform = LungfishIO.SequencingPlatform.detect(fromHeader: header) else {
            return nil
        }

        switch platform {
        case .illumina:
            return .illuminaShortReads
        case .oxfordNanopore:
            return .ontReads
        case .pacbio:
            return .pacBioCLR
        default:
            return nil
        }
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
}

public enum MappingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case defaultShortRead = "short-read-default"
    case minimap2MapONT = "map-ont"
    case minimap2MapHiFi = "map-hifi"
    case minimap2MapPB = "map-pb"
    case bbmapStandard = "bbmap-standard"
    case bbmapPacBio = "bbmap-pacbio"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .defaultShortRead: return "Short-read"
        case .minimap2MapONT: return "Oxford Nanopore"
        case .minimap2MapHiFi: return "PacBio HiFi"
        case .minimap2MapPB: return "PacBio CLR"
        case .bbmapStandard: return "Standard"
        case .bbmapPacBio: return "PacBio"
        }
    }

    public var commandPresetValue: String? {
        switch self {
        case .defaultShortRead: return "sr"
        case .minimap2MapONT: return "map-ont"
        case .minimap2MapHiFi: return "map-hifi"
        case .minimap2MapPB: return "map-pb"
        case .bbmapStandard, .bbmapPacBio: return nil
        }
    }

    public func isValid(for tool: MappingTool) -> Bool {
        switch tool {
        case .minimap2:
            return [.defaultShortRead, .minimap2MapONT, .minimap2MapHiFi, .minimap2MapPB].contains(self)
        case .bwaMem2, .bowtie2:
            return self == .defaultShortRead
        case .bbmap:
            return [.bbmapStandard, .bbmapPacBio].contains(self)
        }
    }

    public static func availableModes(for tool: MappingTool) -> [MappingMode] {
        allCases.filter { $0.isValid(for: tool) }
    }
}
