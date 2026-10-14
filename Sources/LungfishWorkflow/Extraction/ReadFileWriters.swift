// ReadFileWriters.swift - The joins and conversions that write read files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Classifier read resolver

extension ClassifierReadResolver {
    func concatenateFiles(_ sources: [URL], into destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? outHandle.close() }
        for src in sources {
            let inHandle = try FileHandle(forReadingFrom: src)
            defer { try? inHandle.close() }
            while true {
                let chunk = inHandle.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                outHandle.write(chunk)
            }
        }
    }

    /// FASTQ → FASTA line-by-line conversion. Drops quality lines.
    func convertFASTQToFASTA(input: URL, output: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }
        fm.createFile(atPath: output.path, contents: nil)

        let inHandle = try FileHandle(forReadingFrom: input)
        defer { try? inHandle.close() }
        let outHandle = try FileHandle(forWritingTo: output)
        defer { try? outHandle.close() }

        // Stream line-by-line. We use a simple buffered line reader.
        let reader = LineReader(handle: inHandle)
        var lineIndex = 0
        while let line = reader.nextLine() {
            let mod = lineIndex % 4
            if mod == 0 {
                // Header line: convert leading @ to >
                if line.first == 0x40 /* @ */ {
                    var converted = Data([0x3E /* > */])
                    converted.append(line.dropFirst())
                    converted.append(0x0A)
                    outHandle.write(converted)
                } else {
                    var converted = line
                    converted.append(0x0A)
                    outHandle.write(converted)
                }
            } else if mod == 1 {
                var seq = line
                seq.append(0x0A)
                outHandle.write(seq)
            }
            // mod == 2 (+) and mod == 3 (quality) are discarded.
            lineIndex += 1
        }
    }
}

// MARK: - Batch importer

extension FASTQBatchImporter {
    /// Concatenates multiple FASTQ files into a single destination file.
    static func concatenateFiles(_ sources: [URL], to destination: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw BatchImportError.unknownRecipe("Cannot open destination for concatenation: \(destination.path)")
        }
        defer { output.closeFile() }
        for source in sources {
            if let data = fm.contents(atPath: source.path) {
                output.write(data)
            }
        }
    }
}

// MARK: - LineReader (private helper)

/// A minimal line reader for FASTQ → FASTA streaming. Not a general-purpose
/// line reader — it assumes LF line endings.
fileprivate final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize = 1 << 20

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex..<buffer.index(after: newlineIndex))
                return line
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            buffer.append(chunk)
        }
    }
}
