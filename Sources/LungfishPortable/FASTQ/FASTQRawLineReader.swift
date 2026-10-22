// FASTQRawLineReader.swift - Pull-based byte line reader over a plain or gzip FASTQ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Pull-based byte line reader over a plain or gzip/BGZF file.
///
/// Gzip input is decompressed through `/usr/bin/gzip -dc`, the same route
/// `GzipLineSource` takes, because it handles concatenated BGZF members.
/// `launcher` starts that child, so the reader names no launcher of one
/// platform.
package final class FASTQRawLineReader {
    private let url: URL
    private let handle: FileHandle?
    private let child: (any PortableChild)?
    private var buffer: [UInt8] = []
    private var position = 0
    private var reachedEnd = false
    private var closed = false
    private let chunkSize = 1_048_576

    package init(url: URL, launcher: any PortableChildLauncher) throws {
        self.url = url
        guard let probe = FileHandle(forReadingAtPath: url.path) else {
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(file: url.lastPathComponent, reason: "file not found or not readable")
        }
        let magic = (try? probe.read(upToCount: 2)) ?? Data()
        let isGzip = magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
        if isGzip {
            try? probe.close()
            self.child = try launcher.start(PortableChildRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
                arguments: ["-dc", url.path],
                environment: ["PATH": "/usr/bin:/bin"],
                label: "gzip -dc"
            ))
            self.handle = nil
        } else {
            try probe.seek(toOffset: 0)
            self.child = nil
            self.handle = probe
        }
    }

    deinit { close() }

    package func nextLine() throws -> [UInt8]? {
        while true {
            if let newline = indexOfNewline() {
                let line = Array(buffer[position..<newline])
                position = newline + 1
                return line
            }
            if reachedEnd {
                guard position < buffer.count else { return nil }
                let line = Array(buffer[position..<buffer.count])
                position = buffer.count
                return line
            }
            try fill()
        }
    }

    package func readChunk() throws -> [UInt8]? {
        guard !reachedEnd else { return nil }
        // A plain file's `read(upToCount:)` hands back an autoreleased buffer.
        // Without a pool per chunk, a caller that never leaves its thread keeps
        // every chunk.
        let chunk = try autoreleasepool { () -> [UInt8] in
            [UInt8](try readNext())
        }
        if chunk.isEmpty {
            try finishInput()
            return nil
        }
        return chunk
    }

    package func close() {
        guard !closed else { return }
        closed = true
        try? handle?.close()
        if let child {
            child.cancel()
            // Reaps gzip before returning, as terminate and wait did. The main thread never waits.
            if !Thread.isMainThread { _ = try? child.waitForExit() }
        }
    }

    /// The next piece of input, empty at the end. A plain file gives up to a chunk, and gzip gives a whole
    /// chunk unless its output ends.
    private func readNext() throws -> Data {
        if let child { return child.readStdout(filling: chunkSize) }
        return try handle?.read(upToCount: chunkSize) ?? Data()
    }

    private func indexOfNewline() -> Int? {
        guard position < buffer.count else { return nil }
        let start = position
        return buffer.withUnsafeBufferPointer { pointer -> Int? in
            guard let base = pointer.baseAddress,
                  let found = memchr(base + start, 0x0A, pointer.count - start) else { return nil }
            return UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - base
        }
    }

    private func fill() throws {
        if position > 0 {
            buffer.removeSubrange(0..<position)
            position = 0
        }
        let reachedEndOfInput = try autoreleasepool { () -> Bool in
            let data = try readNext()
            buffer.append(contentsOf: data)
            return data.isEmpty
        }
        if reachedEndOfInput {
            try finishInput()
        }
    }

    private func finishInput() throws {
        reachedEnd = true
        guard let child else { return }
        let result: PortableChildExit
        do {
            result = try child.waitForExit()
        } catch {
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(
                file: url.lastPathComponent, reason: "gzip decompression failed (\(error.localizedDescription))"
            )
        }
        guard result.isSuccess else {
            throw FASTQPairInterleaver.InterleaveError.unreadableInput(
                file: url.lastPathComponent, reason: "gzip decompression failed (exit \(result.status))"
            )
        }
    }
}
