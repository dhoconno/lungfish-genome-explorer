// NaoMgsSamplePartitioner.swift - Streaming partitioner for NAO-MGS TSV inputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

struct NaoMgsPartitionResult: Sendable {
    let sampleFiles: [String: URL]
    let totalRows: Int
}

enum NaoMgsSamplePartitioner {
    static func partition(
        inputURLs: [URL],
        outputDirectory: URL
    ) throws -> NaoMgsPartitionResult {
        guard !inputURLs.isEmpty else {
            return NaoMgsPartitionResult(sampleFiles: [:], totalRows: 0)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var headerLine: String?
        var sampleColumnIndex: Int?
        var writers: [String: FileHandle] = [:]
        var sampleFiles: [String: URL] = [:]
        var totalRows = 0

        defer {
            for handle in writers.values {
                try? handle.close()
            }
        }

        func writer(for sample: String) throws -> FileHandle {
            if let existing = writers[sample] {
                return existing
            }

            let url = outputDirectory.appendingPathComponent("\(sample).tsv")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: url)
            if let headerLine {
                try handle.write(contentsOf: Data((headerLine + "\n").utf8))
            }
            writers[sample] = handle
            sampleFiles[sample] = url
            return handle
        }

        func processHeader(_ line: String, sourceURL: URL) throws {
            if let existing = headerLine {
                guard existing == line else {
                    throw NaoMgsSamplePartitionerError.inconsistentHeader(sourceURL)
                }
                return
            }

            let headers = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let sampleIndex = headers.firstIndex(of: "sample") else {
                throw NaoMgsSamplePartitionerError.missingSampleColumn(sourceURL)
            }

            headerLine = line
            sampleColumnIndex = sampleIndex
        }

        func processDataLine(_ line: String, sourceURL: URL) throws {
            guard let sampleColumnIndex else { return }

            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.indices.contains(sampleColumnIndex) else {
                throw NaoMgsSamplePartitionerError.malformedRow(sourceURL)
            }

            let sample = NaoMgsDatabase.normalizeImportedSampleName(String(fields[sampleColumnIndex]))
            let handle = try writer(for: sample)
            try handle.write(contentsOf: Data((line + "\n").utf8))
            totalRows += 1
        }

        for inputURL in inputURLs {
            try streamNaoMgsLines(from: inputURL) { lineNumber, line in
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }

                if lineNumber == 0 {
                    try processHeader(line, sourceURL: inputURL)
                } else {
                    try processDataLine(line, sourceURL: inputURL)
                }
            }
        }

        return NaoMgsPartitionResult(sampleFiles: sampleFiles, totalRows: totalRows)
    }
}

private enum NaoMgsSamplePartitionerError: LocalizedError {
    case inconsistentHeader(URL)
    case malformedRow(URL)
    case missingSampleColumn(URL)

    var errorDescription: String? {
        switch self {
        case .inconsistentHeader(let url):
            return "NAO-MGS TSV headers do not match across inputs: \(url.lastPathComponent)"
        case .malformedRow(let url):
            return "NAO-MGS row is missing the sample column in \(url.lastPathComponent)"
        case .missingSampleColumn(let url):
            return "NAO-MGS header is missing the sample column in \(url.lastPathComponent)"
        }
    }
}

private func streamNaoMgsLines(
    from url: URL,
    process: (_ lineNumber: Int, _ line: String) throws -> Void
) throws {
    let readHandle: FileHandle
    var gzipProcess: Process?

    if url.pathExtension.lowercased() == "gz" {
        let processHandle = Process()
        processHandle.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        processHandle.arguments = ["-dc", url.path]
        let pipe = Pipe()
        processHandle.standardOutput = pipe
        processHandle.standardError = FileHandle.nullDevice
        try processHandle.run()
        readHandle = pipe.fileHandleForReading
        gzipProcess = processHandle
    } else {
        readHandle = try FileHandle(forReadingFrom: url)
    }

    defer {
        if url.pathExtension.lowercased() == "gz" {
            gzipProcess?.waitUntilExit()
        } else {
            try? readHandle.close()
        }
    }

    let chunkSize = 4_194_304
    var partial = Data()
    var lineNumber = 0

    func processChunkText(_ text: String) throws {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            try process(lineNumber, line)
            lineNumber += 1
        }
    }

    while true {
        let chunk = readHandle.readData(ofLength: chunkSize)
        if chunk.isEmpty { break }

        partial.append(chunk)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else {
            continue
        }

        let completeRange = partial[partial.startIndex...lastNewline]
        if let text = String(data: Data(completeRange), encoding: .utf8) {
            try processChunkText(text)
        }

        let nextIndex = partial.index(after: lastNewline)
        partial = nextIndex < partial.endIndex ? Data(partial[nextIndex...]) : Data()
    }

    if !partial.isEmpty, let text = String(data: partial, encoding: .utf8) {
        let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
        try process(lineNumber, line)
    }
}
