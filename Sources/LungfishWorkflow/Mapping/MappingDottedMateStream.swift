// MappingDottedMateStream.swift - One stream for a mapper that pairs only records of one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// minimap2's short-read preset and bwa-mem2 `-p` pair adjacent records only when their names match once `/1` or `/2`
/// is stripped, so mates named `SRR1.7.1` and `SRR1.7.2` would map as single reads under a record that says pairs. Such a
/// run reads a copy of its one stream in its input folder, with each pair of dotted mates written `SRR1.7/1` and
/// `SRR1.7/2`. Single reads and every other name keep their bytes, and a file in any other form keeps its command.
enum MappingDottedMateStream {

    /// The files a mapper reads for `inputs`. A copy with shared mate names when the run pairs by name in one stream and
    /// the file's first read has the dotted form, else `inputs`.
    static func executionURLs(
        _ inputs: [URL],
        request: MappingRunRequest,
        layout: FASTQInputLayout,
        into directory: URL,
        progress: (@Sendable (String) -> Void)?
    ) throws -> [URL] {
        guard inputs.count == 1, layout == .strictlyInterleaved || layout == .mixedMergedAndPairs,
              MappingInputResolver.readPairingCapability(tool: request.tool, modeID: request.modeID)?.mixedInput == .nameInterleavedStream,
              try firstReadIsDotted(inputs[0]) else { return inputs }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("shared-mate-names.fastq")
        let pairs = try writeSharedMateNames(from: inputs[0], to: output)
        progress?("Mates named like SRR1.7.1 and SRR1.7.2 go to \(request.tool.displayName) as SRR1.7/1 and SRR1.7/2, so it pairs all \(pairs) pairs.")
        return [output]
    }

    private static func firstReadIsDotted(_ input: URL) throws -> Bool {
        let reader = try FASTQRawLineReader(url: input)
        defer { reader.close() }
        guard let line = try reader.nextLine() else { return false }
        return FASTQReadLayoutClassifier.holdsDottedMateName(String(decoding: line.dropFirst(), as: UTF8.self))
    }

    /// Writes `input` with each adjacent pair of dotted mates under a shared name, and returns the number of pairs.
    static func writeSharedMateNames(from input: URL, to output: URL) throws -> Int {
        let reader = try FASTQRawLineReader(url: input)
        defer { reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var buffer: [UInt8] = []
        var total = 0
        var pairs = 0
        var pending: [[UInt8]]?
        func append(_ record: [[UInt8]], header: [UInt8]? = nil) {
            buffer.append(contentsOf: header ?? record[0])
            buffer.append(0x0A)
            for line in record.dropFirst() {
                buffer.append(contentsOf: line)
                buffer.append(0x0A)
            }
        }
        while let record = try FASTQPairInterleaver.readRecord(from: reader, file: input.lastPathComponent, recordNumber: total + 1) {
            total += 1
            if total & 0x3FFF == 0 { try Task.checkCancellation() }
            guard let previous = pending else {
                pending = record
                continue
            }
            let name1 = String(decoding: previous[0].dropFirst(), as: UTF8.self)
            let name2 = String(decoding: record[0].dropFirst(), as: UTF8.self)
            if FASTQReadLayoutClassifier.areMates(name1, name2),
               let shared1 = FASTQReadLayoutClassifier.sharedMateName(name1),
               let shared2 = FASTQReadLayoutClassifier.sharedMateName(name2) {
                append(previous, header: Array("@\(shared1)".utf8))
                append(record, header: Array("@\(shared2)".utf8))
                pairs += 1
                pending = nil
            } else {
                append(previous)
                pending = record
            }
            if buffer.count >= 4 * 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if let last = pending { append(last) }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        return pairs
    }
}
