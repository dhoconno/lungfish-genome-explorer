// BigWigReader.swift - BigWig binary file reader
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)
// Reference: UCSC BigWig specification
// https://github.com/ucscGenomeBrowser/kent/blob/master/src/inc/bwgInternal.h

import Foundation

/// A value from a BigWig file.
public struct BigWigValue: Sendable {
    /// Chromosome name
    public let chromosome: String

    /// Start position (0-based)
    public let start: Int

    /// End position (0-based, exclusive)
    public let end: Int

    /// Signal value
    public let value: Float

    public init(chromosome: String, start: Int, end: Int, value: Float) {
        self.chromosome = chromosome
        self.start = start
        self.end = end
        self.value = value
    }
}

/// Summary statistics for a region.
public struct BigWigSummary: Sendable {
    /// Number of bases covered
    public let validCount: Int

    /// Minimum value
    public let minVal: Double

    /// Maximum value
    public let maxVal: Double

    /// Sum of values
    public let sumData: Double

    /// Sum of squared values
    public let sumSquares: Double

    /// Mean value
    public var mean: Double {
        validCount > 0 ? sumData / Double(validCount) : 0
    }

    /// Standard deviation
    public var stdDev: Double {
        guard validCount > 1 else { return 0 }
        let variance = (sumSquares - (sumData * sumData) / Double(validCount)) / Double(validCount - 1)
        return variance > 0 ? variance.squareRoot() : 0
    }
}

/// Header information from a BigWig file.
public struct BigWigHeader: Sendable {
    /// Magic number (should be 0x888FFC26 or 0x26FC8F88)
    public let magic: UInt32

    /// Version number
    public let version: UInt16

    /// Number of zoom levels
    public let zoomLevels: UInt16

    /// Offset to chromosome tree
    public let chromTreeOffset: UInt64

    /// Offset to full data
    public let fullDataOffset: UInt64

    /// Offset to full index
    public let fullIndexOffset: UInt64

    /// Field count
    public let fieldCount: UInt16

    /// Defined field count
    public let definedFieldCount: UInt16

    /// Auto-SQL offset
    public let autoSqlOffset: UInt64

    /// Total summary offset
    public let totalSummaryOffset: UInt64

    /// Uncompressed buffer size
    public let uncompressBufSize: UInt32

    /// Extension offset
    public let extensionOffset: UInt64

    /// Whether the file is big-endian
    public let isBigEndian: Bool
}

/// Chromosome information from BigWig.
public struct BigWigChromosome: Sendable {
    /// Chromosome name
    public let name: String

    /// Chromosome ID in the file
    public let id: UInt32

    /// Chromosome length
    public let length: UInt32
}

// MARK: - BigWigReader

/// Actor-based reader for BigWig binary files.
///
/// BigWig files contain signal data (like coverage) with built-in
/// indexing for efficient range queries at multiple zoom levels.
///
/// ## Usage
/// ```swift
/// let reader = try await BigWigReader(url: fileURL)
/// let values = try await reader.values(chromosome: "chr1", start: 1000, end: 2000)
/// let summary = try await reader.summary(chromosome: "chr1", start: 0, end: 100000, bins: 100)
/// ```
public actor BigWigReader {

    // MARK: - Properties

    private let url: URL
    private let fileHandle: FileHandle
    private let header: BigWigHeader
    private let chromosomes: [String: BigWigChromosome]
    private let chromIdToName: [UInt32: String]

    // MARK: - Initialization

    /// Opens a BigWig file for reading.
    ///
    /// - Parameter url: URL of the BigWig file
    /// - Throws: `BigWigError` if the file cannot be opened or parsed
    public init(url: URL) async throws {
        self.url = url

        // Open file
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw BigWigError.cannotOpenFile(path: url.path)
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
    public func getHeader() -> BigWigHeader {
        header
    }

    /// Reads values for a genomic region.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    /// - Returns: Array of values in the region
    public func values(chromosome: String, start: Int, end: Int) throws -> [BigWigValue] {
        guard let chromInfo = chromosomes[chromosome] else {
            throw BigWigError.unknownChromosome(name: chromosome)
        }

        // For this implementation, we'll read the R-tree index and fetch data blocks
        // This is a simplified implementation - a full implementation would traverse
        // the R-tree more efficiently

        return try readValuesFromIndex(
            chromId: chromInfo.id,
            chromName: chromosome,
            start: UInt32(start),
            end: UInt32(end)
        )
    }

    /// Computes summary statistics for bins across a region.
    ///
    /// - Parameters:
    ///   - chromosome: Chromosome name
    ///   - start: Start position (0-based)
    ///   - end: End position (0-based, exclusive)
    ///   - bins: Number of bins to compute
    /// - Returns: Array of mean values for each bin
    public func summary(chromosome: String, start: Int, end: Int, bins: Int) throws -> [Float] {
        let values = try self.values(chromosome: chromosome, start: start, end: end)

        guard bins > 0 else { return [] }

        let regionLength = end - start
        let binSize = max(1, regionLength / bins)
        var result = [Float](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)

        for value in values {
            // Determine which bins this value overlaps
            let valueStart = max(value.start, start)
            let valueEnd = min(value.end, end)

            let startBin = (valueStart - start) / binSize
            let endBin = min(bins - 1, (valueEnd - start - 1) / binSize)

            for bin in startBin...endBin {
                if bin >= 0 && bin < bins {
                    result[bin] += value.value
                    counts[bin] += 1
                }
            }
        }

        // Compute means
        for i in 0..<bins {
            if counts[i] > 0 {
                result[i] /= Float(counts[i])
            }
        }

        return result
    }

    /// Returns overall statistics for the file.
    public func totalSummary() throws -> BigWigSummary? {
        guard header.totalSummaryOffset > 0 else { return nil }

        try fileHandle.seek(toOffset: header.totalSummaryOffset)

        guard let data = try fileHandle.read(upToCount: 40) else {
            return nil
        }

        let validCount = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        let minVal = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Double.self) }
        let maxVal = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Double.self) }
        let sumData = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Double.self) }
        let sumSquares = data.withUnsafeBytes { $0.load(fromByteOffset: 32, as: Double.self) }

        return BigWigSummary(
            validCount: Int(validCount),
            minVal: minVal,
            maxVal: maxVal,
            sumData: sumData,
            sumSquares: sumSquares
        )
    }

    // MARK: - Private Methods

    private static func readHeader(handle: FileHandle) throws -> BigWigHeader {
        try handle.seek(toOffset: 0)

        guard let data = try handle.read(upToCount: 64) else {
            throw BigWigError.invalidFormat(reason: "Cannot read header")
        }

        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }

        // Check magic number (big or little endian)
        let isBigEndian: Bool
        if magic == 0x888FFC26 {
            isBigEndian = false
        } else if magic == 0x26FC8F88 {
            isBigEndian = true
        } else {
            throw BigWigError.invalidFormat(reason: "Invalid magic number: \(String(format: "0x%08X", magic))")
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

        return BigWigHeader(
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

    private static func readChromosomeTree(handle: FileHandle, header: BigWigHeader) throws -> ([String: BigWigChromosome], [UInt32: String]) {
        try handle.seek(toOffset: header.chromTreeOffset)

        // Read B+ tree header
        guard let treeHeader = try handle.read(upToCount: 32) else {
            throw BigWigError.invalidFormat(reason: "Cannot read chromosome tree header")
        }

        let magic = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x78CA8C91 else {
            throw BigWigError.invalidFormat(reason: "Invalid B+ tree magic")
        }

        let blockSize = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let keySize = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        let valSize = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let itemCount = treeHeader.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }

        var chromosomes: [String: BigWigChromosome] = [:]
        var idToName: [UInt32: String] = [:]

        // Simple implementation: read leaf nodes
        // A full implementation would properly traverse the B+ tree
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
        chromosomes: inout [String: BigWigChromosome],
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
                    let chrom = BigWigChromosome(name: name, id: chromId, length: chromSize)
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

    private func readValuesFromIndex(chromId: UInt32, chromName: String, start: UInt32, end: UInt32) throws -> [BigWigValue] {
        // Navigate to the R-tree index
        try fileHandle.seek(toOffset: header.fullIndexOffset)

        // Read R-tree header
        guard let rTreeHeader = try fileHandle.read(upToCount: 48) else {
            throw BigWigError.invalidFormat(reason: "Cannot read R-tree header")
        }

        let magic = rTreeHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x2468ACE0 else {
            throw BigWigError.invalidFormat(reason: "Invalid R-tree magic: \(String(format: "0x%08X", magic))")
        }

        // For a simplified implementation, we'll scan the data section
        // A full implementation would properly traverse the R-tree

        var values: [BigWigValue] = []

        // Read data blocks from the full data offset
        try fileHandle.seek(toOffset: header.fullDataOffset)

        // Read a reasonable chunk and parse it
        // This is simplified - real implementation would use the index
        if let dataHeader = try fileHandle.read(upToCount: 24) {
            let dataChromId = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let dataStart = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let dataEnd = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
            let itemStep = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
            let itemSpan = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
            let dataType = dataHeader[20]
            let itemCount = dataHeader.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }

            if dataChromId == chromId {
                // Parse based on data type
                switch dataType {
                case 1: // bedGraph
                    for _ in 0..<itemCount {
                        if let item = try fileHandle.read(upToCount: 12) {
                            let itemStart = item.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                            let itemEnd = item.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
                            let value = item.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }

                            if itemEnd > start && itemStart < end {
                                values.append(BigWigValue(
                                    chromosome: chromName,
                                    start: Int(itemStart),
                                    end: Int(itemEnd),
                                    value: value
                                ))
                            }
                        }
                    }

                case 2: // variableStep
                    var pos = dataStart
                    for _ in 0..<itemCount {
                        if let item = try fileHandle.read(upToCount: 8) {
                            let itemStart = item.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                            let value = item.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }

                            let itemEnd = itemStart + itemSpan
                            if itemEnd > start && itemStart < end {
                                values.append(BigWigValue(
                                    chromosome: chromName,
                                    start: Int(itemStart),
                                    end: Int(itemEnd),
                                    value: value
                                ))
                            }
                        }
                    }

                case 3: // fixedStep
                    var pos = dataStart
                    for _ in 0..<itemCount {
                        if let item = try fileHandle.read(upToCount: 4) {
                            let value = item.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float.self) }

                            let itemEnd = pos + itemSpan
                            if itemEnd > start && pos < end {
                                values.append(BigWigValue(
                                    chromosome: chromName,
                                    start: Int(pos),
                                    end: Int(itemEnd),
                                    value: value
                                ))
                            }
                            pos += itemStep
                        }
                    }

                default:
                    break
                }
            }
        }

        return values
    }
}

// MARK: - BigWigError

/// Errors that can occur when reading BigWig files.
public enum BigWigError: Error, LocalizedError, Sendable {

    case cannotOpenFile(path: String)
    case invalidFormat(reason: String)
    case unknownChromosome(name: String)
    case readError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path):
            return "Cannot open BigWig file: \(path)"
        case .invalidFormat(let reason):
            return "Invalid BigWig format: \(reason)"
        case .unknownChromosome(let name):
            return "Unknown chromosome: \(name)"
        case .readError(let reason):
            return "Read error: \(reason)"
        }
    }
}
