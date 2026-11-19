// DemultiplexGzipChunks.swift - Gzip read and written a window at a time, with the file closed between windows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import zlib

/// Inflates one gzip file a window at a time for ``OrderedOutputCursor``. The file is opened only to read the next
/// compressed window, so a pass over many outputs at once holds no open file and no child process for each output. It
/// reads a file of several gzip members (BGZF, or files joined with `cat`) as one stream.
final class GzipChunkInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var pending: [UInt8] = []
    private var pendingPosition = 0
    private var fileEnded = false
    private var memberEnded = false
    private var readAny = false
    private static let compressedWindow = 65_536

    /// Whether the file at `url` starts with the gzip magic bytes.
    static func isGzip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        return magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
    }

    init() throws {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        // 15 + 32: a window of 32 KB and a gzip or zlib header found by its magic.
        guard inflateInit2_(stream, 15 + 32, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw DemultiplexError.outputParsingFailed("could not start reading a gzip output")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// The next bytes of the file's plain text, at most `limit` and at least 1, or none at its end. `offset` is where the
    /// next compressed window starts in the file, and moves past each window read.
    func next(from url: URL, offset: inout UInt64, limit: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: limit)
        var produced = 0
        while produced == 0 {
            if pendingPosition >= pending.count {
                if fileEnded {
                    guard !readAny || memberEnded else {
                        throw DemultiplexError.outputParsingFailed("\(url.lastPathComponent) ends inside its gzip stream")
                    }
                    return []
                }
                let window = try OrderedOutputCursor.readWindow(of: url, at: offset, count: Self.compressedWindow)
                if window.isEmpty {
                    fileEnded = true
                    continue
                }
                offset += UInt64(window.count)
                pending = window
                pendingPosition = 0
                readAny = true
            }
            if memberEnded {
                // The bytes after a member's end start the next member.
                guard inflateReset(stream) == Z_OK else {
                    throw DemultiplexError.outputParsingFailed("could not read the next gzip member of \(url.lastPathComponent)")
                }
                memberEnded = false
            }
            let available = pending.count - pendingPosition
            var status: Int32 = Z_OK
            var left = 0
            pending.withUnsafeMutableBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    stream.pointee.next_in = input.baseAddress! + pendingPosition
                    stream.pointee.avail_in = UInt32(available)
                    stream.pointee.next_out = out.baseAddress! + produced
                    stream.pointee.avail_out = UInt32(limit - produced)
                    status = inflate(stream, Z_NO_FLUSH)
                    produced = limit - Int(stream.pointee.avail_out)
                    left = Int(stream.pointee.avail_in)
                }
            }
            pendingPosition += available - left
            switch status {
            case Z_STREAM_END:
                memberEnded = true
            case Z_OK:
                break
            case Z_BUF_ERROR where available > left || produced > 0:
                break
            default:
                throw DemultiplexError.outputParsingFailed("\(url.lastPathComponent) is not a whole gzip file (zlib \(status))")
            }
            if produced == limit { break }
        }
        return Array(output[0..<produced])
    }
}

/// Deflates the bytes of one output into a gzip stream for ``AppendingFASTQSink``, at level 1, the level Cutadapt writes
/// its gzip outputs at.
final class GzipChunkDeflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init(level: Int32 = 1) throws {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        // 15 + 16: a window of 32 KB and a gzip header and trailer.
        guard deflateInit2_(stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw DemultiplexError.outputParsingFailed("could not start writing a gzip output")
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// The compressed bytes of `bytes`, and with `finish` the end of the stream.
    func compress(_ bytes: [UInt8], finish: Bool) throws -> [UInt8] {
        var input = bytes
        var compressed: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var status: Int32 = Z_OK
        try input.withUnsafeMutableBufferPointer { source in
            stream.pointee.next_in = source.baseAddress
            stream.pointee.avail_in = UInt32(source.count)
            repeat {
                var full = false
                chunk.withUnsafeMutableBufferPointer { out in
                    stream.pointee.next_out = out.baseAddress
                    stream.pointee.avail_out = UInt32(out.count)
                    status = deflate(stream, finish ? Z_FINISH : Z_NO_FLUSH)
                    full = stream.pointee.avail_out == 0
                    compressed.append(contentsOf: out[0..<(out.count - Int(stream.pointee.avail_out))])
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw DemultiplexError.outputParsingFailed("could not write a gzip output (zlib \(status))")
                }
                if finish ? status == Z_STREAM_END : (!full && stream.pointee.avail_in == 0) { break }
            } while true
        }
        return compressed
    }
}
