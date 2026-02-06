// SyncBigBedReader.swift - Synchronous BigBed binary file reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Synchronous counterpart to BigBedReader for use in AppKit drawing contexts
// where async calls cannot be awaited (e.g., draw(_:) methods).

import Foundation
import Compression
import LungfishCore

// MARK: - SyncBigBedReader

/// Synchronous reader for BigBed binary files.
///
/// Unlike the actor-based `BigBedReader`, this class provides fully synchronous
/// access to BigBed features. This is required for AppKit drawing contexts where
/// `async/await` cannot be used (e.g., `NSView.draw(_:)`).
///
/// Each instance opens its own `FileHandle` and should not be shared across threads.
///
/// ## Usage
/// ```swift
/// let reader = try SyncBigBedReader(url: fileURL)
/// let features = try reader.features(chromosome: "chr1", start: 1000, end: 2000)
/// ```
public final class SyncBigBedReader {

    // MARK: - Properties

    private let url: URL
    private let fileHandle: FileHandle
    private let header: BigBedHeader
    private let chromosomes: [String: BigBedChromosome]
    private let chromIdToName: [UInt32: String]

    // MARK: - Initialization

    /// Opens a BigBed file for synchronous reading.
    ///
    /// - Parameter url: URL of the BigBed file
    /// - Throws: `BigBedError` if the file cannot be opened or parsed
    public init(url: URL) throws {
        self.url = url

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw BigBedError.cannotOpenFile(path: url.path)
        }
        self.fileHandle = handle

        self.header = try Self.readHeader(handle: handle)

        let (chroms, idMap) = try Self.readChromosomeTree(handle: handle, header: self.header)
        self.chromosomes = chroms
        self.chromIdToName = idMap
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Public API

    /// Returns the list of chromosomes in the file.
    public func getChromosomes() -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, chrom) in chromosomes {
            result[name] = Int(chrom.length)
        }
        return result
    }

    /// Returns the header information.
    public func getHeader() -> BigBedHeader {
        header
    }

    /// Reads features for a genomic region.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of features in the region
    public func features(chromosome: String, start: Int, end: Int) throws -> [BigBedFeature] {
        guard let chromInfo = chromosomes[chromosome] else {
            throw BigBedError.unknownChromosome(name: chromosome)
        }

        return try readFeaturesFromIndex(
            chromId: chromInfo.id,
            chromName: chromosome,
            start: UInt32(start),
            end: UInt32(end)
        )
    }

    /// Reads features for a genomic region.
    ///
    /// - Parameter region: The genomic region to query
    /// - Returns: Array of features in the region
    public func features(region: GenomicRegion) throws -> [BigBedFeature] {
        try features(chromosome: region.chromosome, start: region.start, end: region.end)
    }

    // MARK: - Private Methods - Header Reading

    private static func readHeader(handle: FileHandle) throws -> BigBedHeader {
        try handle.seek(toOffset: 0)

        guard let data = try handle.read(upToCount: 64) else {
            throw BigBedError.invalidFormat(reason: "Cannot read header")
        }

        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        let isBigEndian: Bool
        if magic == 0x8789F2EB {
            isBigEndian = false
        } else if magic == 0xEBF28987 {
            isBigEndian = true
        } else {
            throw BigBedError.invalidFormat(reason: "Invalid magic number: \(String(format: "0x%08X", magic))")
        }

        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        let zoomLevels = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
        let chromTreeOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
        let fullDataOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
        let fullIndexOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
        let fieldCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt16.self) }
        let definedFieldCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self) }
        let autoSqlOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt64.self) }
        let totalSummaryOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 44, as: UInt64.self) }
        let uncompressBufSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 52, as: UInt32.self) }
        let extensionOffset = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 56, as: UInt64.self) }

        return BigBedHeader(
            magic: magic,
            version: version,
            zoomLevels: zoomLevels,
            chromTreeOffset: chromTreeOffset,
            fullDataOffset: fullDataOffset,
            fullIndexOffset: fullIndexOffset,
            fieldCount: fieldCount,
            definedFieldCount: definedFieldCount,
            autoSqlOffset: autoSqlOffset,
            totalSummaryOffset: totalSummaryOffset,
            uncompressBufSize: uncompressBufSize,
            extensionOffset: extensionOffset,
            isBigEndian: isBigEndian
        )
    }

    private static func readChromosomeTree(handle: FileHandle, header: BigBedHeader) throws -> ([String: BigBedChromosome], [UInt32: String]) {
        try handle.seek(toOffset: header.chromTreeOffset)

        guard let treeHeader = try handle.read(upToCount: 32) else {
            throw BigBedError.invalidFormat(reason: "Cannot read chromosome tree header")
        }

        let magic = treeHeader.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x78CA8C91 else {
            throw BigBedError.invalidFormat(reason: "Invalid B+ tree magic")
        }

        let keySize = treeHeader.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let valSize = treeHeader.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }

        var chromosomes: [String: BigBedChromosome] = [:]
        var idToName: [UInt32: String] = [:]

        try readChromTreeNode(
            handle: handle,
            keySize: Int(keySize),
            valSize: Int(valSize),
            chromosomes: &chromosomes,
            idToName: &idToName
        )

        return (chromosomes, idToName)
    }

    private static func readChromTreeNode(
        handle: FileHandle,
        keySize: Int,
        valSize: Int,
        chromosomes: inout [String: BigBedChromosome],
        idToName: inout [UInt32: String]
    ) throws {
        guard let nodeHeader = try handle.read(upToCount: 4) else { return }

        let isLeaf = nodeHeader[0]
        let count = UInt16(nodeHeader[2]) | (UInt16(nodeHeader[3]) << 8)

        if isLeaf == 1 {
            for _ in 0..<count {
                guard let keyData = try handle.read(upToCount: keySize) else { break }
                guard let valData = try handle.read(upToCount: 8) else { break }

                let name = String(data: keyData, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
                    .replacingOccurrences(of: "\0", with: "") ?? ""

                let chromId = valData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                let chromSize = valData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }

                if !name.isEmpty {
                    let chrom = BigBedChromosome(name: name, id: chromId, length: chromSize)
                    chromosomes[name] = chrom
                    idToName[chromId] = name
                }
            }
        } else {
            // Non-leaf node - need to traverse children
            // Read all child pointers first, then recursively visit
            var childOffsets: [UInt64] = []
            for _ in 0..<count {
                // Skip key
                _ = try handle.read(upToCount: keySize)
                // Read child offset
                guard let offsetData = try handle.read(upToCount: 8) else { break }
                let childOffset = offsetData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
                childOffsets.append(childOffset)
            }
            // Traverse each child node
            for childOffset in childOffsets {
                try handle.seek(toOffset: childOffset)
                try readChromTreeNode(
                    handle: handle,
                    keySize: keySize,
                    valSize: valSize,
                    chromosomes: &chromosomes,
                    idToName: &idToName
                )
            }
        }
    }

    // MARK: - Private Methods - R-tree Index Reading

    private func readFeaturesFromIndex(chromId: UInt32, chromName: String, start: UInt32, end: UInt32) throws -> [BigBedFeature] {
        try fileHandle.seek(toOffset: header.fullIndexOffset)

        guard let rTreeHeader = try fileHandle.read(upToCount: 48) else {
            throw BigBedError.invalidFormat(reason: "Cannot read R-tree header")
        }

        let magic = rTreeHeader.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x2468ACE0 else {
            throw BigBedError.invalidFormat(reason: "Invalid R-tree magic: \(String(format: "0x%08X", magic))")
        }

        let rootOffset = fileHandle.offsetInFile

        var features: [BigBedFeature] = []
        try traverseRTree(
            nodeOffset: rootOffset,
            chromId: chromId,
            chromName: chromName,
            start: start,
            end: end,
            features: &features
        )

        return features
    }

    private func traverseRTree(
        nodeOffset: UInt64,
        chromId: UInt32,
        chromName: String,
        start: UInt32,
        end: UInt32,
        features: inout [BigBedFeature]
    ) throws {
        try fileHandle.seek(toOffset: nodeOffset)

        guard let nodeHeader = try fileHandle.read(upToCount: 4) else { return }

        let isLeaf = nodeHeader[0] == 1
        let count = UInt16(nodeHeader[2]) | (UInt16(nodeHeader[3]) << 8)

        if isLeaf {
            // Collect ALL leaf items first, then read data blocks.
            // readDataBlock seeks the fileHandle to a different position, so we
            // must finish reading all 32-byte leaf items before seeking elsewhere.
            var dataBlocks: [(offset: UInt64, size: Int)] = []

            for _ in 0..<count {
                guard let item = try fileHandle.read(upToCount: 32) else { break }

                let itemStartChromIx = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                let itemStartBase = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                let itemEndChromIx = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
                let itemEndBase = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
                let dataOffset = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }
                let dataSize = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }

                if itemEndChromIx >= chromId && itemStartChromIx <= chromId {
                    let overlaps: Bool
                    if itemStartChromIx == chromId && itemEndChromIx == chromId {
                        overlaps = itemEndBase > start && itemStartBase < end
                    } else if itemStartChromIx == chromId {
                        overlaps = itemStartBase < end
                    } else if itemEndChromIx == chromId {
                        overlaps = itemEndBase > start
                    } else {
                        overlaps = true
                    }

                    if overlaps {
                        dataBlocks.append((dataOffset, Int(dataSize)))
                    }
                }
            }

            // Now read and parse each data block (safe to seek)
            for block in dataBlocks {
                let blockFeatures = try readDataBlock(
                    offset: block.offset,
                    size: block.size,
                    chromId: chromId,
                    chromName: chromName,
                    queryStart: start,
                    queryEnd: end
                )
                features.append(contentsOf: blockFeatures)
            }
        } else {
            var childNodes: [(offset: UInt64, overlaps: Bool)] = []

            for _ in 0..<count {
                guard let item = try fileHandle.read(upToCount: 24) else { break }

                let itemStartChromIx = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
                let itemStartBase = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                let itemEndChromIx = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
                let itemEndBase = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
                let childOffset = item.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self) }

                if itemEndChromIx >= chromId && itemStartChromIx <= chromId {
                    let overlaps: Bool
                    if itemStartChromIx == chromId && itemEndChromIx == chromId {
                        overlaps = itemEndBase > start && itemStartBase < end
                    } else if itemStartChromIx == chromId {
                        overlaps = itemStartBase < end
                    } else if itemEndChromIx == chromId {
                        overlaps = itemEndBase > start
                    } else {
                        overlaps = true
                    }

                    childNodes.append((childOffset, overlaps))
                }
            }

            for (childOffset, overlaps) in childNodes where overlaps {
                try traverseRTree(
                    nodeOffset: childOffset,
                    chromId: chromId,
                    chromName: chromName,
                    start: start,
                    end: end,
                    features: &features
                )
            }
        }
    }

    private func readDataBlock(
        offset: UInt64,
        size: Int,
        chromId: UInt32,
        chromName: String,
        queryStart: UInt32,
        queryEnd: UInt32
    ) throws -> [BigBedFeature] {
        try fileHandle.seek(toOffset: offset)

        guard let compressedData = try fileHandle.read(upToCount: size) else {
            throw BigBedError.readError(reason: "Cannot read data block at offset \(offset)")
        }

        let blockData: Data
        if header.uncompressBufSize > 0 {
            blockData = try decompressBlock(compressedData)
        } else {
            blockData = compressedData
        }

        return parseDataBlock(
            data: blockData,
            chromId: chromId,
            chromName: chromName,
            queryStart: queryStart,
            queryEnd: queryEnd
        )
    }

    private func decompressBlock(_ data: Data) throws -> Data {
        // BigBed uses zlib format (RFC 1950) which has a 2-byte header (CMF+FLG).
        // Apple's COMPRESSION_ZLIB expects raw DEFLATE (RFC 1951) without the header.
        // Strip the 2-byte zlib header before decompressing.
        guard data.count > 2 else {
            throw BigBedError.readError(reason: "Compressed block too small (\(data.count) bytes)")
        }
        let deflateData = data.dropFirst(2)

        var outputData = Data(count: Int(header.uncompressBufSize))
        var decompressedSize = 0

        try deflateData.withUnsafeBytes { compressedBuffer in
            guard let compressedPointer = compressedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw BigBedError.readError(reason: "Failed to access compressed data")
            }

            try outputData.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw BigBedError.readError(reason: "Failed to allocate output buffer")
                }

                decompressedSize = compression_decode_buffer(
                    outputPointer,
                    outputBuffer.count,
                    compressedPointer,
                    compressedBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )

                if decompressedSize == 0 {
                    throw BigBedError.readError(reason: "Decompression produced no output")
                }
            }
        }

        return outputData.prefix(decompressedSize)
    }

    private func parseDataBlock(
        data: Data,
        chromId: UInt32,
        chromName: String,
        queryStart: UInt32,
        queryEnd: UInt32
    ) -> [BigBedFeature] {
        var features: [BigBedFeature] = []
        var offset = 0

        while offset < data.count {
            guard offset + 12 <= data.count else { break }

            let recordChromId = data.withUnsafeBytes { buffer in
                buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            let recordStart = data.withUnsafeBytes { buffer in
                buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            }
            let recordEnd = data.withUnsafeBytes { buffer in
                buffer.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)
            }

            offset += 12

            var restEnd = offset
            while restEnd < data.count && data[restEnd] != 0 {
                restEnd += 1
            }

            let restString: String?
            if restEnd > offset {
                restString = String(data: data.subdata(in: offset..<restEnd), encoding: .utf8)
            } else {
                restString = nil
            }

            offset = restEnd + 1

            if recordChromId == chromId && recordEnd > queryStart && recordStart < queryEnd {
                let feature = parseBedFields(
                    chromName: chromName,
                    start: Int(recordStart),
                    end: Int(recordEnd),
                    rest: restString
                )
                features.append(feature)
            }
        }

        return features
    }

    private func parseBedFields(chromName: String, start: Int, end: Int, rest: String?) -> BigBedFeature {
        guard let rest = rest else {
            return BigBedFeature(chromosome: chromName, start: start, end: end)
        }

        let fields = rest.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        let name = fields.count > 0 && !fields[0].isEmpty ? fields[0] : nil
        let score = fields.count > 1 ? Int(fields[1]) : nil
        let strand: Character? = fields.count > 2 && !fields[2].isEmpty ? fields[2].first : nil
        let thickStart = fields.count > 3 ? Int(fields[3]) : nil
        let thickEnd = fields.count > 4 ? Int(fields[4]) : nil

        var itemRgb: (r: UInt8, g: UInt8, b: UInt8)?
        if fields.count > 5 && !fields[5].isEmpty {
            let rgbParts = fields[5].split(separator: ",").compactMap { UInt8($0) }
            if rgbParts.count == 3 {
                itemRgb = (rgbParts[0], rgbParts[1], rgbParts[2])
            }
        }

        let blockCount = fields.count > 6 ? Int(fields[6]) : nil

        var blockSizes: [Int]?
        if fields.count > 7 && !fields[7].isEmpty {
            blockSizes = fields[7].split(separator: ",").compactMap { Int($0) }
        }

        var blockStarts: [Int]?
        if fields.count > 8 && !fields[8].isEmpty {
            blockStarts = fields[8].split(separator: ",").compactMap { Int($0) }
        }

        var extraFields: String?
        if fields.count > 9 {
            extraFields = fields[9...].joined(separator: "\t")
        }

        return BigBedFeature(
            chromosome: chromName,
            start: start,
            end: end,
            name: name,
            score: score,
            strand: strand,
            thickStart: thickStart,
            thickEnd: thickEnd,
            itemRgb: itemRgb,
            blockCount: blockCount,
            blockSizes: blockSizes,
            blockStarts: blockStarts,
            extraFields: extraFields
        )
    }
}
