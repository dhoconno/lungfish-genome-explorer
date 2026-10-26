// ImportFastqStagedReads.swift - `import fastq --staged-reads`: the list of reads already in the Linux staging folder (CHTC C6 lane STAGED)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// The `--staged-reads` list of a plan whose reads exist only in the Linux staging folder (ruling STAGED, O59): a
/// tab-separated file made on the Linux machine, a header line that names at least the columns `file`, `bytes` and
/// `sha256`, then one line a read with its absolute path there, its size in bytes and its SHA-256. The plan takes each
/// read's size and SHA-256 from the list and never opens the read, and each job checks the read against them before any
/// step runs. Any other column is ignored, so a list may keep an `md5` column, and blank lines are skipped. A line no sheet
/// row names is ignored, so one list may describe a whole folder of reads.
struct ImportFastqStagedReads: Equatable {
    struct Read: Equatable {
        var size: Int64
        var sha256: String
    }

    /// The columns every list names, in the order the refusals name them.
    static let columns = ["file", "bytes", "sha256"]

    /// The list's path as it was given, which the dry run names.
    var list: String
    /// Each read by its absolute path in the staging folder.
    var reads: [String: Read]

    /// Reads the list at `list`, or refuses in one sentence a user can act on.
    static func read(_ list: String) throws -> ImportFastqStagedReads {
        guard let data = FileManager.default.contents(atPath: list), let text = String(data: data, encoding: .utf8) else {
            throw ImportFastqPlanRefusal(message: "The file \(list) given to --staged-reads cannot be read as text.")
        }
        return try parse(text, list: list)
    }

    /// The list's reads. A line is numbered as an editor numbers it, the header line 1 and blank lines counted.
    static func parse(_ text: String, list: String) throws -> ImportFastqStagedReads {
        func refuse(_ message: String) -> ImportFastqPlanRefusal { ImportFastqPlanRefusal(message: message) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        let header = lines.first ?? ""
        if header.contains(","), !header.contains("\t") {
            throw refuse("The staged-reads list \(list) is comma-separated. Write it tab-separated, with the columns file, bytes and sha256.")
        }
        // The header is matched after trimming spaces and lowercasing, as the sample sheet's is.
        let names = header.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var index: [String: Int] = [:]
        for column in columns {
            guard let found = names.firstIndex(of: column) else {
                throw refuse("The staged-reads list \(list) has no \(column) column. Its first line names the columns file, bytes and sha256, separated by tabs.")
            }
            index[column] = found
        }
        var reads: [String: Read] = [:]
        var lineOfFile: [String: Int] = [:]
        for (offset, line) in lines.enumerated().dropFirst()
        where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let number = offset + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var values: [String: String] = [:]
            for column in columns {
                let at = index[column] ?? 0
                let value = at < fields.count ? fields[at] : ""
                guard !value.isEmpty else {
                    throw refuse("Line \(number) of the staged-reads list has no \(column) value.")
                }
                values[column] = value
            }
            let file = values["file"] ?? "", bytes = values["bytes"] ?? "", sha256 = values["sha256"] ?? ""
            guard isSHA256(sha256) else {
                throw refuse("Line \(number) of the staged-reads list gives the SHA-256 \(sha256), which is not 64 lowercase hexadecimal characters. Copy it from the output of sha256sum.")
            }
            guard let size = wholeBytes(bytes) else {
                throw refuse("Line \(number) of the staged-reads list gives the size \(bytes), which is not a whole number of bytes above 0. Copy it from the output of stat -c %s.")
            }
            guard file.hasPrefix("/") else {
                throw refuse("Line \(number) of the staged-reads list names \(file), which is not an absolute path. Name each read by its absolute path on the Linux machine.")
            }
            // A read listed twice is refused even with equal values, so the list says one thing for each read.
            if let earlier = lineOfFile[file] {
                throw refuse("The staged-reads list names \(file) on lines \(earlier) and \(number). List each read once.")
            }
            lineOfFile[file] = number
            reads[file] = Read(size: size, sha256: sha256)
        }
        return ImportFastqStagedReads(list: list, reads: reads)
    }

    /// The inputs of one sheet row as the plan pins them, R1 then R2, at their paths in the staging folder. Each path is
    /// checked to lie in the staging folder before its list line is looked up, so a path on this Mac in a staged sheet
    /// gets the words for a mixed batch, and the writer's own check (`ExecutorPlanBatchWriter.checkStagedRead`) is the
    /// one the CLI makes, so the dry run refuses as the run does. Nothing opens a read.
    func inputs(of pair: SamplePair, files: [URL], layout: ExecutorPlanStagingLayout) throws -> [ExecutorPlanSourceFile] {
        var inputs: [ExecutorPlanSourceFile] = []
        for (position, url) in files.enumerated() {
            let path = url.path
            try ExecutorPlanBatchWriter.checkStagedRead(path, sample: pair.sampleName, layout: layout)
            guard let read = reads[path] else {
                throw ImportFastqPlanRefusal(message: "The sample sheet names \(path) as the \(position == 0 ? "R1" : "R2") of \(pair.sampleName), and the staged-reads list has no line for it. Add its size and SHA-256 to the list, or correct the path.")
            }
            inputs.append(ExecutorPlanSourceFile(url: URL(fileURLWithPath: path), sha256: read.sha256, size: read.size))
        }
        try ExecutorPlanBatchWriter.checkStagedReadNames(files.map(\.path), sample: pair.sampleName)
        return inputs
    }

    /// 64 lowercase hexadecimal characters, the form `sha256sum` prints (Q-STAGED-3: one form).
    private static func isSHA256(_ value: String) -> Bool {
        let hex = Set("0123456789abcdef".unicodeScalars)
        return value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    /// A whole number of bytes above 0 that fits an `Int64`, written in digits only, as `stat -c %s` prints it.
    private static func wholeBytes(_ value: String) -> Int64? {
        guard value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let size = Int64(value), size > 0 else { return nil }
        return size
    }
}
