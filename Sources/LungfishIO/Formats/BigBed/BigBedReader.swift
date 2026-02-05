// BigBedReader.swift - BigBed binary file reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: UCSC BigBed specification
// https://github.com/ucscGenomeBrowser/kent/blob/master/src/inc/bigBed.h

import Foundation
import Compression
import LungfishCore

// MARK: - BigBedFeature

/// A feature (annotation) from a BigBed file.
public struct BigBedFeature: Sendable, Identifiable {
    /// Unique identifier.
    public let id: String
    
    /// Chromosome name.
    public let chromosome: String
    
    /// Start position (0-based, inclusive).
    public let start: Int
    
    /// End position (0-based, exclusive).
    public let end: Int
    
    /// Feature name (from column 4).
    public let name: String?
    
    /// Score (0-1000, from column 5).
    public let score: Int?
    
    /// Strand ('+', '-', or '.').
    public let strand: Character?
    
    /// Thick start position (for drawing, from column 7).
    public let thickStart: Int?
    
    /// Thick end position (for drawing, from column 8).
    public let thickEnd: Int?
    
    /// RGB color for display (from column 9).
    public let itemRgb: (r: UInt8, g: UInt8, b: UInt8)?
    
    /// Block count for multi-part features (from column 10).
    public let blockCount: Int?
    
    /// Block sizes (from column 11).
    public let blockSizes: [Int]?
    
    /// Block starts relative to chromStart (from column 12).
    public let blockStarts: [Int]?
    
    /// Additional fields beyond BED12 as raw string.
    public let extraFields: String?
    
    /// Length of the feature.
    public var length: Int { end - start }
    
    /// Creates a BigBed feature.
    public init(
        id: String = UUID().uuidString,
        chromosome: String,
        start: Int,
        end: Int,
        name: String? = nil,
        score: Int? = nil,
        strand: Character? = nil,
        thickStart: Int? = nil,
        thickEnd: Int? = nil,
        itemRgb: (r: UInt8, g: UInt8, b: UInt8)? = nil,
        blockCount: Int? = nil,
        blockSizes: [Int]? = nil,
        blockStarts: [Int]? = nil,
        extraFields: String? = nil
    ) {
        self.id = id
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.name = name
        self.score = score
        self.strand = strand
        self.thickStart = thickStart
        self.thickEnd = thickEnd
        self.itemRgb = itemRgb
        self.blockCount = blockCount
        self.blockSizes = blockSizes
        self.blockStarts = blockStarts
        self.extraFields = extraFields
    }
}

// MARK: - BigBedHeader

/// Header information from a BigBed file.
public struct BigBedHeader: Sendable {
    /// Magic number (should be 0x8789F2EB or 0xEBF28987).
    public let magic: UInt32
    
    /// Version number.
    public let version: UInt16
    
    /// Number of zoom levels.
    public let zoomLevels: UInt16
    
    /// Offset to chromosome tree.
    public let chromTreeOffset: UInt64
    
    /// Offset to full data.
    public let fullDataOffset: UInt64
    
    /// Offset to full index (R-tree).
    public let fullIndexOffset: UInt64
    
    /// Number of fields in BED format.
    public let fieldCount: UInt16
    
    /// Number of defined (standard BED) fields.
    public let definedFieldCount: UInt16
    
    /// Offset to autoSql definition.
    public let autoSqlOffset: UInt64
    
    /// Offset to total summary.
    public let totalSummaryOffset: UInt64
    
    /// Uncompressed buffer size.
    public let uncompressBufSize: UInt32
    
    /// Extension offset.
    public let extensionOffset: UInt64
    
    /// Whether the file is big-endian.
    public let isBigEndian: Bool
}

// MARK: - BigBedChromosome

/// Chromosome information from BigBed.
public struct BigBedChromosome: Sendable {
    /// Chromosome name.
    public let name: String
    
    /// Chromosome ID in the file.
    public let id: UInt32
    
    /// Chromosome length.
    public let length: UInt32
}

// MARK: - BigBedReader

/// Actor-based reader for BigBed binary files.
///
/// BigBed files contain annotation features (like BED records) with built-in
/// R-tree indexing for efficient range queries.
///
/// ## Usage
/// ```swift
/// let reader = try await BigBedReader(url: fileURL)
/// let features = try await reader.features(chromosome: "chr1", start: 1000, end: 2000)
/// ```
public actor BigBedReader {
    
    // MARK: - Properties
    
    private let url: URL
    private let fileHandle: FileHandle
    private let header: BigBedHeader
    private let chromosomes: [String: BigBedChromosome]
    private let chromIdToName: [UInt32: String]
    
    // MARK: - Initialization
    
    /// Opens a BigBed file for reading.
    ///
    /// - Parameter url: URL of the BigBed file
    /// - Throws: `BigBedError` if the file cannot be opened or parsed
    public init(url: URL) async throws {
        self.url = url
        
        // Open file
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw BigBedError.cannotOpenFile(path: url.path)
        }
        self.fileHandle = handle
        
        // Read and validate header
        self.header = try Self.readHeader(handle: handle)
        
        // Read chromosome tree
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
    
    /// Returns the total number of features in the file.
    public func totalFeatureCount() throws -> Int {
        // For now, return 0 - full implementation would read from summary
        return 0
    }
    
    // MARK: - Private Methods - Header Reading
    
    private static func readHeader(handle: FileHandle) throws -> BigBedHeader {
        try handle.seek(toOffset: 0)
        
        guard let data = try handle.read(upToCount: 64) else {
            throw BigBedError.invalidFormat(reason: "Cannot read header")
        }
        
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        
        // Check magic number (big or little endian)
        // BigBed magic: 0x8789F2EB (little) or 0xEBF28987 (big)
        let isBigEndian: Bool
        if magic == 0x8789F2EB {
            isBigEndian = false
        } else if magic == 0xEBF28987 {
            isBigEndian = true
        } else {
            throw BigBedError.invalidFormat(reason: "Invalid magic number: \(String(format: "0x%08X", magic))")
        }
        
        // Read header fields (assuming little-endian for now)
        let version = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }
        let zoomLevels = data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
        let chromTreeOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        let fullDataOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
        let fullIndexOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
        let fieldCount = data.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt16.self) }
        let definedFieldCount = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        let autoSqlOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 36, as: UInt64.self) }
        let totalSummaryOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: UInt64.self) }
        let uncompressBufSize = data.withUnsafeBytes { $0.load(fromByteOffset: 52, as: UInt32.self) }
        let extensionOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 56, as: UInt64.self) }
        
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
        
        // Read B+ tree header
        guard let treeHeader = try handle.read(upToCount: 32) else {
            throw BigBedError.invalidFormat(reason: "Cannot read chromosome tree header")
        }
        
        let magic = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x78CA8C91 else {
            throw BigBedError.invalidFormat(reason: "Invalid B+ tree magic")
        }
        
        let keySize = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let valSize = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        
        var chromosomes: [String: BigBedChromosome] = [:]
        var idToName: [UInt32: String] = [:]
        
        // Read leaf nodes (simplified - real implementation would traverse B+ tree)
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
            // Leaf node - read chromosome entries
            for _ in 0..<count {
                guard let keyData = try handle.read(upToCount: keySize) else { break }
                guard let valData = try handle.read(upToCount: 8) else { break }
                
                // Parse key (null-terminated string)
                let name = String(data: keyData, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters)
                    .replacingOccurrences(of: "\0", with: "") ?? ""
                
                // Parse value (chromId + chromSize)
                let chromId = valData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let chromSize = valData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                
                if !name.isEmpty {
                    let chrom = BigBedChromosome(name: name, id: chromId, length: chromSize)
                    chromosomes[name] = chrom
                    idToName[chromId] = name
                }
            }
        } else {
            // Non-leaf node - skip for now (simplified implementation)
            let skipBytes = Int(count) * (keySize + 8)
            try handle.seek(toOffset: handle.offsetInFile + UInt64(skipBytes))
        }
    }
    
    // MARK: - Private Methods - R-tree Index Reading
    
    private func readFeaturesFromIndex(chromId: UInt32, chromName: String, start: UInt32, end: UInt32) throws -> [BigBedFeature] {
        // Navigate to the R-tree index
        try fileHandle.seek(toOffset: header.fullIndexOffset)
        
        // Read R-tree header
        guard let rTreeHeader = try fileHandle.read(upToCount: 48) else {
            throw BigBedError.invalidFormat(reason: "Cannot read R-tree header")
        }
        
        let magic = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x2468ACE0 else {
            throw BigBedError.invalidFormat(reason: "Invalid R-tree magic: \(String(format: "0x%08X", magic))")
        }
        
        // Read R-tree parameters
        let blockSize = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let itemCount = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }  // startChromIx
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }  // startBase
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }  // endChromIx
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }  // endBase
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self) }  // fileSize
        _ = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }  // itemsPerSlot
        
        // Record the root node offset
        let rootOffset = fileHandle.offsetInFile
        
        // Traverse R-tree to find overlapping leaves
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
        
        // Read node header
        guard let nodeHeader = try fileHandle.read(upToCount: 4) else { return }
        
        let isLeaf = nodeHeader[0] == 1
        let count = UInt16(nodeHeader[2]) | (UInt16(nodeHeader[3]) << 8)
        
        if isLeaf {
            // Leaf node - read data block references
            for _ in 0..<count {
                guard let item = try fileHandle.read(upToCount: 32) else { break }
                
                let itemStartChromIx = item.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let itemStartBase = item.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                let itemEndChromIx = item.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let itemEndBase = item.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                let dataOffset = item.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
                let dataSize = item.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
                
                // Check if this block overlaps our query region
                if itemEndChromIx >= chromId && itemStartChromIx <= chromId {
                    // Overlaps on chromosome - check position
                    let overlaps: Bool
                    if itemStartChromIx == chromId && itemEndChromIx == chromId {
                        overlaps = itemEndBase > start && itemStartBase < end
                    } else if itemStartChromIx == chromId {
                        overlaps = itemStartBase < end
                    } else if itemEndChromIx == chromId {
                        overlaps = itemEndBase > start
                    } else {
                        overlaps = true  // Spans our chromosome entirely
                    }
                    
                    if overlaps {
                        // Read and parse the data block
                        let blockFeatures = try readDataBlock(
                            offset: dataOffset,
                            size: Int(dataSize),
                            chromId: chromId,
                            chromName: chromName,
                            queryStart: start,
                            queryEnd: end
                        )
                        features.append(contentsOf: blockFeatures)
                    }
                }
            }
        } else {
            // Non-leaf node - traverse children
            var childNodes: [(offset: UInt64, overlaps: Bool)] = []
            
            for _ in 0..<count {
                guard let item = try fileHandle.read(upToCount: 24) else { break }
                
                let itemStartChromIx = item.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let itemStartBase = item.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                let itemEndChromIx = item.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let itemEndBase = item.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                let childOffset = item.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
                
                // Check if this subtree might contain our region
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
            
            // Recursively traverse overlapping children
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
        
        // Decompress if needed (BigBed blocks are typically zlib compressed)
        let blockData: Data
        if header.uncompressBufSize > 0 {
            blockData = try decompressBlock(compressedData)
        } else {
            blockData = compressedData
        }
        
        // Parse BED records from the block
        return parseDataBlock(
            data: blockData,
            chromId: chromId,
            chromName: chromName,
            queryStart: queryStart,
            queryEnd: queryEnd
        )
    }
    
    private func decompressBlock(_ data: Data) throws -> Data {
        var outputData = Data(count: Int(header.uncompressBufSize))
        var decompressedSize = 0
        
        try data.withUnsafeBytes { compressedBuffer in
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
            // Each record: chromId(4) + start(4) + end(4) + rest(null-terminated string)
            guard offset + 12 <= data.count else { break }
            
            let recordChromId = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: offset, as: UInt32.self)
            }
            let recordStart = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: offset + 4, as: UInt32.self)
            }
            let recordEnd = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: offset + 8, as: UInt32.self)
            }
            
            offset += 12
            
            // Read the rest field (null-terminated string with BED fields)
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
            
            offset = restEnd + 1  // Skip null terminator
            
            // Filter by query region
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
        
        // Parse RGB color (field 6, format "r,g,b")
        var itemRgb: (r: UInt8, g: UInt8, b: UInt8)?
        if fields.count > 5 && !fields[5].isEmpty {
            let rgbParts = fields[5].split(separator: ",").compactMap { UInt8($0) }
            if rgbParts.count == 3 {
                itemRgb = (rgbParts[0], rgbParts[1], rgbParts[2])
            }
        }
        
        let blockCount = fields.count > 6 ? Int(fields[6]) : nil
        
        // Parse block sizes (field 8)
        var blockSizes: [Int]?
        if fields.count > 7 && !fields[7].isEmpty {
            blockSizes = fields[7].split(separator: ",").compactMap { Int($0) }
        }
        
        // Parse block starts (field 9)
        var blockStarts: [Int]?
        if fields.count > 8 && !fields[8].isEmpty {
            blockStarts = fields[8].split(separator: ",").compactMap { Int($0) }
        }
        
        // Collect extra fields
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

// MARK: - BigBedError

/// Errors that can occur when reading BigBed files.
public enum BigBedError: Error, LocalizedError, Sendable {
    case cannotOpenFile(path: String)
    case invalidFormat(reason: String)
    case unknownChromosome(name: String)
    case readError(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path):
            return "Cannot open BigBed file: \(path)"
        case .invalidFormat(let reason):
            return "Invalid BigBed format: \(reason)"
        case .unknownChromosome(let name):
            return "Unknown chromosome: \(name)"
        case .readError(let reason):
            return "Read error: \(reason)"
        }
    }
}
