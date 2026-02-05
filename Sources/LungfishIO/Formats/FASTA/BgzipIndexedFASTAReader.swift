// BgzipIndexedFASTAReader.swift - Random access to bgzip-compressed FASTA files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Compression
import LungfishCore

// MARK: - GZI Index

/// Represents a bgzip index (.gzi) file for random access to bgzip-compressed files.
///
/// The GZI format stores pairs of (compressed_offset, uncompressed_offset) that
/// mark the boundaries of bgzip blocks. This enables seeking to any position
/// in the uncompressed data by finding the appropriate block.
public struct GZIIndex: Sendable {
    /// A single entry in the GZI index representing a block boundary.
    public struct Entry: Sendable {
        /// Offset in the compressed file (bytes from start)
        public let compressedOffset: UInt64
        
        /// Offset in the uncompressed data (bytes from start)
        public let uncompressedOffset: UInt64
        
        public init(compressedOffset: UInt64, uncompressedOffset: UInt64) {
            self.compressedOffset = compressedOffset
            self.uncompressedOffset = uncompressedOffset
        }
    }
    
    /// All entries in the index, sorted by uncompressed offset.
    public let entries: [Entry]
    
    /// Creates a GZI index by loading from a .gzi file.
    ///
    /// GZI format: 8-byte little-endian count, followed by pairs of 8-byte offsets
    ///
    /// - Parameter url: The .gzi file URL
    /// - Throws: `BgzipError` if the file cannot be read
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BgzipError.indexNotFound(url)
        }
        
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else {
            throw BgzipError.invalidIndex("GZI file too short")
        }
        
        // Read entry count (8-byte little-endian)
        let count = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: 0, as: UInt64.self)
        }
        
        let expectedSize = 8 + Int(count) * 16
        guard data.count >= expectedSize else {
            throw BgzipError.invalidIndex("GZI file truncated: expected \(expectedSize) bytes, got \(data.count)")
        }
        
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count) + 1)
        
        // First entry is always (0, 0) implicitly - the start of the file
        entries.append(Entry(compressedOffset: 0, uncompressedOffset: 0))
        
        // Read pairs of offsets
        for i in 0..<Int(count) {
            let offset = 8 + i * 16
            let compressedOffset = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: offset, as: UInt64.self)
            }
            let uncompressedOffset = data.withUnsafeBytes { buffer in
                buffer.load(fromByteOffset: offset + 8, as: UInt64.self)
            }
            entries.append(Entry(compressedOffset: compressedOffset, uncompressedOffset: uncompressedOffset))
        }
        
        self.entries = entries
    }
    
    /// Creates a GZI index from entries.
    public init(entries: [Entry]) {
        self.entries = entries
    }
    
    /// Finds the block containing the given uncompressed offset.
    ///
    /// - Parameter uncompressedOffset: Byte offset in uncompressed data
    /// - Returns: The entry for the block containing this offset, and the offset within the block
    public func findBlock(for uncompressedOffset: UInt64) -> (entry: Entry, offsetInBlock: UInt64)? {
        // Binary search for the largest entry with uncompressedOffset <= target
        var low = 0
        var high = entries.count - 1
        
        while low < high {
            let mid = (low + high + 1) / 2
            if entries[mid].uncompressedOffset <= uncompressedOffset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        
        guard low < entries.count else { return nil }
        
        let entry = entries[low]
        let offsetInBlock = uncompressedOffset - entry.uncompressedOffset
        return (entry, offsetInBlock)
    }
}

// MARK: - BgzipError

/// Errors that can occur when working with bgzip-compressed files.
public enum BgzipError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case indexNotFound(URL)
    case invalidIndex(String)
    case invalidBgzipBlock(String)
    case decompressionFailed(String)
    case regionOutOfBounds(GenomicRegion, Int)
    case sequenceNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Bgzip file not found: \(url.path)"
        case .indexNotFound(let url):
            return "Index file not found: \(url.path)"
        case .invalidIndex(let reason):
            return "Invalid index: \(reason)"
        case .invalidBgzipBlock(let reason):
            return "Invalid bgzip block: \(reason)"
        case .decompressionFailed(let reason):
            return "Decompression failed: \(reason)"
        case .regionOutOfBounds(let region, let length):
            return "Region \(region) exceeds sequence length \(length)"
        case .sequenceNotFound(let name):
            return "Sequence '\(name)' not found in index"
        }
    }
}

// MARK: - BgzipIndexedFASTAReader

/// A FASTA reader for bgzip-compressed files with random access via .fai and .gzi indices.
///
/// This reader enables efficient random access to sequences in large bgzip-compressed
/// FASTA files without decompressing the entire file. It uses:
/// - `.fai` index: Maps sequence names to byte positions in uncompressed data
/// - `.gzi` index: Maps uncompressed positions to compressed block positions
///
/// ## File Requirements
///
/// The FASTA file must be compressed with bgzip (not regular gzip). Bgzip creates
/// block-compressed files that support random access.
///
/// Required files:
/// - `sequence.fa.gz` - bgzip-compressed FASTA
/// - `sequence.fa.gz.fai` - samtools faidx index
/// - `sequence.fa.gz.gzi` - bgzip index
///
/// ## Example
///
/// ```swift
/// let reader = try await BgzipIndexedFASTAReader(url: fastaURL)
/// let region = GenomicRegion(chromosome: "chr1", start: 1000, end: 2000)
/// let sequence = try await reader.fetch(region: region)
/// ```
public actor BgzipIndexedFASTAReader {
    
    // MARK: - Properties
    
    /// The bgzip-compressed FASTA file URL.
    public let url: URL
    
    /// The FASTA index (.fai).
    public let fastaIndex: FASTAIndex
    
    /// The bgzip index (.gzi).
    public let gziIndex: GZIIndex
    
    /// File handle for the compressed file.
    private var fileHandle: FileHandle?
    
    /// Maximum size of a single bgzip block (64KB uncompressed).
    private static let maxBlockSize = 65536
    
    /// Bgzip block header size.
    private static let blockHeaderSize = 18
    
    // MARK: - Initialization
    
    /// Creates a bgzip-indexed FASTA reader.
    ///
    /// Looks for indices at `<fastaPath>.fai` and `<fastaPath>.gzi`.
    ///
    /// - Parameter url: The bgzip-compressed FASTA file URL
    /// - Throws: `BgzipError` if files or indices cannot be opened
    public init(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BgzipError.fileNotFound(url)
        }
        
        self.url = url
        
        // Load FASTA index
        let faiURL = URL(fileURLWithPath: url.path + ".fai")
        self.fastaIndex = try FASTAIndex(url: faiURL)
        
        // Load GZI index
        let gziURL = URL(fileURLWithPath: url.path + ".gzi")
        self.gziIndex = try GZIIndex(url: gziURL)
        
        // Open file handle
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw BgzipError.fileNotFound(url)
        }
        self.fileHandle = handle
    }
    
    /// Creates a bgzip-indexed FASTA reader with explicit index URLs.
    ///
    /// - Parameters:
    ///   - url: The bgzip-compressed FASTA file URL
    ///   - faiURL: The .fai index file URL
    ///   - gziURL: The .gzi index file URL
    public init(url: URL, faiURL: URL, gziURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BgzipError.fileNotFound(url)
        }
        
        self.url = url
        self.fastaIndex = try FASTAIndex(url: faiURL)
        self.gziIndex = try GZIIndex(url: gziURL)
        
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw BgzipError.fileNotFound(url)
        }
        self.fileHandle = handle
    }
    
    deinit {
        try? fileHandle?.close()
    }
    
    // MARK: - Public API
    
    /// Returns available sequence names.
    public var sequenceNames: [String] {
        fastaIndex.sequenceNames
    }
    
    /// Returns the length of a sequence.
    ///
    /// - Parameter name: Sequence name
    /// - Returns: Length in base pairs, or nil if not found
    public func sequenceLength(name: String) -> Int? {
        fastaIndex.length(of: name)
    }
    
    /// Fetches a subsequence from the FASTA file.
    ///
    /// Uses the indices to decompress only the required blocks.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string for the region
    /// - Throws: `BgzipError` if the sequence cannot be fetched
    public func fetch(region: GenomicRegion) async throws -> String {
        guard let entry = fastaIndex.entry(for: region.chromosome) else {
            throw BgzipError.sequenceNotFound(region.chromosome)
        }
        
        guard region.start >= 0 && region.end <= entry.length else {
            throw BgzipError.regionOutOfBounds(region, entry.length)
        }
        
        // Calculate byte range in uncompressed FASTA
        let startByteOffset = fastaIndex.byteOffset(for: region.start, in: entry)
        let endByteOffset = fastaIndex.byteOffset(for: region.end - 1, in: entry)
        
        // We need to read enough bytes to cover the region plus potential newlines
        let bytesToRead = endByteOffset - startByteOffset + entry.lineWidth + 1
        
        // Read and decompress the required range
        let rawData = try await readUncompressedRange(
            startOffset: UInt64(startByteOffset),
            length: bytesToRead
        )
        
        // Convert to string and remove newlines
        guard let rawString = String(data: rawData, encoding: .utf8) else {
            throw BgzipError.decompressionFailed("Invalid UTF-8 in sequence data")
        }
        
        // Remove newlines and trim to exact length
        let sequence = rawString.replacingOccurrences(of: "\n", with: "")
        let clampedLength = min(region.length, sequence.count)
        
        return String(sequence.prefix(clampedLength))
    }
    
    /// Fetches a full sequence by name.
    ///
    /// - Parameter name: Sequence name
    /// - Returns: The sequence string
    public func fetchFullSequence(name: String) async throws -> String {
        guard let entry = fastaIndex.entry(for: name) else {
            throw BgzipError.sequenceNotFound(name)
        }
        
        let region = GenomicRegion(chromosome: name, start: 0, end: entry.length)
        return try await fetch(region: region)
    }
    
    // MARK: - Private Methods
    
    /// Reads and decompresses a range of uncompressed bytes.
    ///
    /// - Parameters:
    ///   - startOffset: Starting byte offset in uncompressed data
    ///   - length: Number of uncompressed bytes to read
    /// - Returns: Decompressed data
    private func readUncompressedRange(startOffset: UInt64, length: Int) async throws -> Data {
        guard let handle = fileHandle else {
            throw BgzipError.decompressionFailed("File handle is closed")
        }
        
        var result = Data()
        result.reserveCapacity(length)
        
        var currentUncompressedOffset = startOffset
        let endOffset = startOffset + UInt64(length)
        
        while currentUncompressedOffset < endOffset {
            // Find the block containing this offset
            guard let (blockEntry, offsetInBlock) = gziIndex.findBlock(for: currentUncompressedOffset) else {
                throw BgzipError.decompressionFailed("Cannot find block for offset \(currentUncompressedOffset)")
            }
            
            // Read and decompress the block
            let blockData = try readAndDecompressBlock(at: blockEntry.compressedOffset, handle: handle)
            
            // Calculate how much data we need from this block
            let startInBlock = Int(offsetInBlock)
            let availableInBlock = blockData.count - startInBlock
            let neededBytes = Int(endOffset - currentUncompressedOffset)
            let bytesToCopy = min(availableInBlock, neededBytes)
            
            if startInBlock < blockData.count && bytesToCopy > 0 {
                result.append(blockData.subdata(in: startInBlock..<(startInBlock + bytesToCopy)))
            }
            
            // Move to next block
            currentUncompressedOffset = blockEntry.uncompressedOffset + UInt64(blockData.count)
        }
        
        return result
    }
    
    /// Reads and decompresses a single bgzip block.
    ///
    /// - Parameters:
    ///   - offset: Compressed file offset where block starts
    ///   - handle: File handle to read from
    /// - Returns: Decompressed block data
    private func readAndDecompressBlock(at offset: UInt64, handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: offset)
        
        // Read block header (18 bytes for bgzip)
        guard let header = try handle.read(upToCount: Self.blockHeaderSize) else {
            throw BgzipError.invalidBgzipBlock("Cannot read block header at offset \(offset)")
        }
        
        // Validate gzip magic
        guard header.count >= 18,
              header[0] == 0x1f,
              header[1] == 0x8b,
              header[2] == 0x08 else {
            throw BgzipError.invalidBgzipBlock("Invalid gzip magic at offset \(offset)")
        }
        
        // Check for bgzip extra field
        let flags = header[3]
        guard flags & 0x04 != 0 else {
            throw BgzipError.invalidBgzipBlock("Missing FEXTRA flag - not a bgzip file")
        }
        
        // Parse extra field to get block size
        // Extra field starts at offset 10, length at 10-11
        let xlen = UInt16(header[10]) | (UInt16(header[11]) << 8)
        guard xlen >= 6 else {
            throw BgzipError.invalidBgzipBlock("Extra field too short")
        }
        
        // Read BSIZE from extra field (bgzip-specific)
        // The extra field contains: SI1(1) SI2(1) SLEN(2) BSIZE(2)
        // SI1=66 ('B'), SI2=67 ('C') identify bgzip
        guard header[12] == 66, header[13] == 67 else {
            throw BgzipError.invalidBgzipBlock("Missing BC subfield - not a bgzip file")
        }
        
        // BSIZE is the total block size minus 1
        let bsize = UInt16(header[16]) | (UInt16(header[17]) << 8)
        let totalBlockSize = Int(bsize) + 1
        
        // Calculate compressed data size (total - header - trailer)
        let compressedDataSize = totalBlockSize - Self.blockHeaderSize - 8
        guard compressedDataSize > 0 else {
            // Empty block (EOF marker)
            return Data()
        }
        
        // Read compressed data
        guard let compressedData = try handle.read(upToCount: compressedDataSize) else {
            throw BgzipError.invalidBgzipBlock("Cannot read compressed data")
        }
        
        // Skip CRC and ISIZE (8 bytes total) - we already accounted for them
        _ = try handle.read(upToCount: 8)
        
        // Decompress using zlib/DEFLATE
        return try decompressDeflate(compressedData)
    }
    
    /// Decompresses raw DEFLATE data.
    ///
    /// - Parameter data: DEFLATE compressed data
    /// - Returns: Decompressed data
    private func decompressDeflate(_ data: Data) throws -> Data {
        // Allocate output buffer for max block size
        var outputData = Data(count: Self.maxBlockSize)
        var decompressedSize = 0
        
        try data.withUnsafeBytes { compressedBuffer in
            guard let compressedPointer = compressedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw BgzipError.decompressionFailed("Failed to access compressed data")
            }
            
            try outputData.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw BgzipError.decompressionFailed("Failed to allocate output buffer")
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
                    throw BgzipError.decompressionFailed("Decompression produced no output")
                }
            }
        }
        
        return outputData.prefix(decompressedSize)
    }
}

// MARK: - Convenience Extension

extension BgzipIndexedFASTAReader {
    /// Creates a reader if the file appears to be bgzip-compressed with indices.
    ///
    /// - Parameter url: URL that might be a bgzip FASTA
    /// - Returns: Reader if valid, nil otherwise
    public static func createIfValid(url: URL) async -> BgzipIndexedFASTAReader? {
        // Check for .gz extension
        guard url.pathExtension == "gz" else { return nil }
        
        // Check for index files
        let faiPath = url.path + ".fai"
        let gziPath = url.path + ".gzi"
        
        guard FileManager.default.fileExists(atPath: faiPath),
              FileManager.default.fileExists(atPath: gziPath) else {
            return nil
        }
        
        return try? await BgzipIndexedFASTAReader(url: url)
    }
}

// MARK: - SyncBgzipFASTAReader

/// A synchronous reader for bgzip-compressed FASTA files.
///
/// This class provides the same functionality as `BgzipIndexedFASTAReader` but
/// without async/await, useful when Swift Tasks don't execute properly.
public final class SyncBgzipFASTAReader: Sendable {
    
    /// The bgzip-compressed FASTA file URL.
    public let url: URL
    
    /// The FASTA index (.fai).
    public let fastaIndex: FASTAIndex
    
    /// The bgzip index (.gzi).
    public let gziIndex: GZIIndex
    
    /// Maximum size of a single bgzip block (64KB uncompressed).
    private static let maxBlockSize = 65536
    
    /// Bgzip block header size.
    private static let blockHeaderSize = 18
    
    /// Creates a synchronous bgzip FASTA reader.
    ///
    /// - Parameters:
    ///   - url: The bgzip-compressed FASTA file URL
    ///   - faiURL: The .fai index file URL
    ///   - gziURL: The .gzi index file URL
    public init(url: URL, faiURL: URL, gziURL: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BgzipError.fileNotFound(url)
        }
        
        self.url = url
        self.fastaIndex = try FASTAIndex(url: faiURL)
        self.gziIndex = try GZIIndex(url: gziURL)
    }
    
    /// Fetches a subsequence synchronously.
    ///
    /// - Parameter region: The genomic region to fetch
    /// - Returns: The sequence string
    public func fetchSync(region: GenomicRegion) throws -> String {
        guard let entry = fastaIndex.entry(for: region.chromosome) else {
            throw BgzipError.sequenceNotFound(region.chromosome)
        }
        
        guard region.start >= 0 && region.end <= entry.length else {
            throw BgzipError.regionOutOfBounds(region, entry.length)
        }
        
        // Calculate byte range in uncompressed FASTA
        let startByteOffset = fastaIndex.byteOffset(for: region.start, in: entry)
        let endByteOffset = fastaIndex.byteOffset(for: region.end - 1, in: entry)
        
        // We need to read enough bytes to cover the region plus potential newlines
        let bytesToRead = endByteOffset - startByteOffset + entry.lineWidth + 1
        
        // Read and decompress the required range
        let rawData = try readUncompressedRange(
            startOffset: UInt64(startByteOffset),
            length: bytesToRead
        )
        
        // Convert to string and remove newlines
        guard let rawString = String(data: rawData, encoding: .utf8) else {
            throw BgzipError.decompressionFailed("Invalid UTF-8 in sequence data")
        }
        
        // Remove newlines and trim to exact length
        let sequence = rawString.replacingOccurrences(of: "\n", with: "")
        let clampedLength = min(region.length, sequence.count)
        
        return String(sequence.prefix(clampedLength))
    }
    
    /// Reads and decompresses a range of uncompressed bytes.
    private func readUncompressedRange(startOffset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        
        var result = Data()
        result.reserveCapacity(length)
        
        var currentUncompressedOffset = startOffset
        let endOffset = startOffset + UInt64(length)
        
        while currentUncompressedOffset < endOffset {
            // Find the block containing this offset
            guard let (blockEntry, offsetInBlock) = gziIndex.findBlock(for: currentUncompressedOffset) else {
                throw BgzipError.decompressionFailed("Cannot find block for offset \(currentUncompressedOffset)")
            }
            
            // Read and decompress the block
            let blockData = try readAndDecompressBlock(at: blockEntry.compressedOffset, handle: handle)
            
            // Calculate how much data we need from this block
            let startInBlock = Int(offsetInBlock)
            let availableInBlock = blockData.count - startInBlock
            let neededBytes = Int(endOffset - currentUncompressedOffset)
            let bytesToCopy = min(availableInBlock, neededBytes)
            
            if startInBlock < blockData.count && bytesToCopy > 0 {
                result.append(blockData.subdata(in: startInBlock..<(startInBlock + bytesToCopy)))
            }
            
            // Move to next block
            currentUncompressedOffset = blockEntry.uncompressedOffset + UInt64(blockData.count)
        }
        
        return result
    }
    
    /// Reads and decompresses a single bgzip block.
    private func readAndDecompressBlock(at offset: UInt64, handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: offset)
        
        // Read block header (18 bytes for bgzip)
        guard let header = try handle.read(upToCount: Self.blockHeaderSize) else {
            throw BgzipError.invalidBgzipBlock("Cannot read block header at offset \(offset)")
        }
        
        // Validate gzip magic
        guard header.count >= 18,
              header[0] == 0x1f,
              header[1] == 0x8b,
              header[2] == 0x08 else {
            throw BgzipError.invalidBgzipBlock("Invalid gzip magic at offset \(offset)")
        }
        
        // Check for bgzip extra field
        let flags = header[3]
        guard flags & 0x04 != 0 else {
            throw BgzipError.invalidBgzipBlock("Missing FEXTRA flag - not a bgzip file")
        }
        
        // Parse extra field to get block size
        let xlen = UInt16(header[10]) | (UInt16(header[11]) << 8)
        guard xlen >= 6 else {
            throw BgzipError.invalidBgzipBlock("Extra field too short")
        }
        
        // Read BSIZE from extra field (bgzip-specific)
        guard header[12] == 66, header[13] == 67 else {
            throw BgzipError.invalidBgzipBlock("Missing BC subfield - not a bgzip file")
        }
        
        // BSIZE is the total block size minus 1
        let bsize = UInt16(header[16]) | (UInt16(header[17]) << 8)
        let totalBlockSize = Int(bsize) + 1
        
        // Calculate compressed data size (total - header - trailer)
        let compressedDataSize = totalBlockSize - Self.blockHeaderSize - 8
        guard compressedDataSize > 0 else {
            // Empty block (EOF marker)
            return Data()
        }
        
        // Read compressed data
        guard let compressedData = try handle.read(upToCount: compressedDataSize) else {
            throw BgzipError.invalidBgzipBlock("Cannot read compressed data")
        }
        
        // Skip CRC and ISIZE (8 bytes total)
        _ = try handle.read(upToCount: 8)
        
        // Decompress using zlib/DEFLATE
        return try decompressDeflate(compressedData)
    }
    
    /// Decompresses raw DEFLATE data.
    private func decompressDeflate(_ data: Data) throws -> Data {
        var outputData = Data(count: Self.maxBlockSize)
        var decompressedSize = 0
        
        try data.withUnsafeBytes { compressedBuffer in
            guard let compressedPointer = compressedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw BgzipError.decompressionFailed("Failed to access compressed data")
            }
            
            try outputData.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw BgzipError.decompressionFailed("Failed to allocate output buffer")
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
                    throw BgzipError.decompressionFailed("Decompression produced no output")
                }
            }
        }
        
        return outputData.prefix(decompressedSize)
    }
}
