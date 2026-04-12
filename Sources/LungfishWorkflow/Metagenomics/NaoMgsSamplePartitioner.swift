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

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try clearExistingPartitionOutputs(in: outputDirectory, fileManager: fileManager)

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

            let url = outputDirectory.appendingPathComponent(safePartitionFileName(for: sample))
            try Data().write(to: url, options: .atomic)

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

private func clearExistingPartitionOutputs(in directory: URL, fileManager: FileManager) throws {
    let existingFiles = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )

    for fileURL in existingFiles where fileURL.pathExtension == "tsv" {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
            try fileManager.removeItem(at: fileURL)
        }
    }
}

private enum NaoMgsSamplePartitionerError: LocalizedError {
    case decodeFailed(URL)
    case gzipFailed(URL, Int32)
    case inconsistentHeader(URL)
    case malformedRow(URL)
    case missingSampleColumn(URL)

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let url):
            return "NAO-MGS TSV is not valid UTF-8: \(url.lastPathComponent)"
        case .gzipFailed(let url, let status):
            return "Failed to decompress NAO-MGS gzip input \(url.lastPathComponent) (exit \(status))"
        case .inconsistentHeader(let url):
            return "NAO-MGS TSV headers do not match across inputs: \(url.lastPathComponent)"
        case .malformedRow(let url):
            return "NAO-MGS row is missing the sample column in \(url.lastPathComponent)"
        case .missingSampleColumn(let url):
            return "NAO-MGS header is missing the sample column in \(url.lastPathComponent)"
        }
    }
}

private func safePartitionFileName(for sample: String) -> String {
    let sanitized = String(sample.unicodeScalars.map { scalar in
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".":
            Character(scalar)
        default:
            "_"
        }
    })
    .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

    let baseName = sanitized.isEmpty ? "sample" : sanitized
    return "\(baseName)-\(deterministicSampleHash(sample)).tsv"
}

private func deterministicSampleHash(_ sample: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in sample.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(format: "%016llx", hash)
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

    defer { try? readHandle.close() }

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
        guard let text = String(data: Data(completeRange), encoding: .utf8) else {
            throw NaoMgsSamplePartitionerError.decodeFailed(url)
        }
        try processChunkText(text)

        let nextIndex = partial.index(after: lastNewline)
        partial = nextIndex < partial.endIndex ? Data(partial[nextIndex...]) : Data()
    }

    if !partial.isEmpty {
        guard let text = String(data: partial, encoding: .utf8) else {
            throw NaoMgsSamplePartitionerError.decodeFailed(url)
        }
        let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
        try process(lineNumber, line)
    }

    if let gzipProcess {
        gzipProcess.waitUntilExit()
        guard gzipProcess.terminationReason == .exit, gzipProcess.terminationStatus == 0 else {
            throw NaoMgsSamplePartitionerError.gzipFailed(url, gzipProcess.terminationStatus)
        }
    }
}
