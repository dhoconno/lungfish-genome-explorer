// FASTARecordsExport.swift - The FASTA records export that the viewers and `extract sequence` share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The FASTA records export (Phase 2.12 lane 12.34, ARCH ruling 1.1 row A11 and 1.3).
///
/// Five viewers hand the app FASTA records they already built in memory (the FASTA collection, an assembly's
/// contigs, an NVD contig, an alignment's rows and the extraction dialog), and a CLI cannot rebuild them from the
/// result alone. So the app stages the records it holds as one FASTA file and writes the sequence names to a
/// selection file (ruling 1.3), both in a new `.lungfish-export-inputs/<UUID>/` folder beside the output, before the
/// Operations row begins. The leaf `lungfish-cli extract sequence <records.fa> --selection <selection.json> -o <file>`
/// reads those two files and writes the named records exactly as stored, so the bytes are the records joined as the
/// old in-app writer joined them. A named sequence is found by its whole header line, and when no header matches, by
/// the header's first word, as `samtools faidx` finds one. A name given again takes the next record of that name.
public enum FASTARecordsExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A11).
    public static let commandPath = ["extract", "sequence"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish extract sequence"
    /// The name of the staged records inside the inputs folder.
    public static let stagedFileName = "records.fa"
    /// The extensions of the FASTA files the records run reads, as the region run reads them.
    public static let fastaExtensions: Set<String> = ["fa", "fasta", "fna", "faa"]

    /// One record of a FASTA document. Its bytes run from its header line to the next header line.
    public struct Record: Sendable, Equatable {
        /// The header line without its `>` and its line end.
        public let header: String
        /// The record's bytes in the document, its header line included.
        public let range: Range<Int>

        /// The header's first word, which ends at the first space or tab.
        public var firstWord: String {
            guard let end = header.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return header }
            return String(header[..<end])
        }
    }

    /// A FASTA document split into its records, with every byte kept.
    public struct Document: Sendable {
        public let data: Data
        /// The count of bytes before the first header line. A FASTA document has none.
        public let preambleLength: Int
        public let records: [Record]

        /// The bytes of `record`, as stored.
        public func bytes(of record: Record) -> Data {
            data.subdata(in: record.range)
        }
    }

    /// A name the document holds no further record for.
    public struct NameNotFound: Error, LocalizedError, Equatable {
        public let name: String

        public var errorDescription: String? {
            "No sequence named \(name) is left in the FASTA file. Give a name its header line or its first word holds."
        }
    }

    /// Splits `data` into its records. A header line starts with `>`, and a line ends at a line feed, with a carriage
    /// return before it left out of the header.
    public static func document(from data: Data) -> Document {
        let bytes = Array(data)
        var records: [Record] = []
        var preambleLength = bytes.count
        var currentStart: Int?
        var currentHeader = ""
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A {
                lineEnd += 1
            }
            if bytes[lineStart] == 0x3E {
                if let start = currentStart {
                    records.append(Record(header: currentHeader, range: start..<lineStart))
                } else {
                    preambleLength = lineStart
                }
                var headerEnd = lineEnd
                if headerEnd > lineStart + 1, bytes[headerEnd - 1] == 0x0D {
                    headerEnd -= 1
                }
                currentHeader = String(decoding: bytes[(lineStart + 1)..<headerEnd], as: UTF8.self)
                currentStart = lineStart
            }
            lineStart = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
        }
        if let start = currentStart {
            records.append(Record(header: currentHeader, range: start..<bytes.count))
        }
        return Document(data: Data(bytes), preambleLength: preambleLength, records: records)
    }

    /// The records `names` ask for, in the order asked. A name is matched to an unused record whose whole header
    /// equals it, else to an unused record whose first word equals it, so a name asked twice takes two records.
    public static func resolve(_ names: [String], in document: Document) throws -> [Record] {
        var byHeader: [String: [Int]] = [:]
        var byWord: [String: [Int]] = [:]
        for (index, record) in document.records.enumerated() {
            byHeader[record.header, default: []].append(index)
            byWord[record.firstWord, default: []].append(index)
        }
        var used = Set<Int>()
        var resolved: [Record] = []
        for name in names {
            let index = (byHeader[name] ?? []).first { !used.contains($0) }
                ?? (byWord[name] ?? []).first { !used.contains($0) }
            guard let index else { throw NameNotFound(name: name) }
            used.insert(index)
            resolved.append(document.records[index])
        }
        return resolved
    }

    /// The selection that names the records the app staged, by their whole header lines in the staged order.
    public static func selection(headers: [String]) -> ViewerExportSelection {
        ViewerExportSelection(identities: headers)
    }

    /// The leaf's invocation, with absolute standardized paths. The begin helper passes its `arguments()` to the
    /// runner and to the row's command, and the leaf records its `canonicalArgv()`. `sequences` spell the names on the
    /// command line, in the `--sequence=<name>` form so that a name may start with a dash. `lineWidth` asks the leaf
    /// to wrap each record's bases, and a run that leaves it out writes the records as stored.
    public static func invocation(
        sourceURL: URL,
        sequences: [String] = [],
        selectionURL: URL? = nil,
        lineWidth: Int? = nil,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        var leafArguments = sequences.map { "--sequence=\($0)" }
        if let lineWidth {
            leafArguments += ["--line-width", String(lineWidth)]
        }
        return ViewerExportInvocation(
            commandPath: commandPath,
            input: sourceURL.standardizedFileURL.path,
            leafArguments: leafArguments,
            selection: selectionURL?.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}
