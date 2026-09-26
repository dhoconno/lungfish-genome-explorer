// ThymineAlphabet.swift - Keeps imported nucleotide data in the T alphabet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Lungfish stores every nucleotide sequence with T. RNA is a molecule label only,
/// so U (uracil) in imported nucleotide data is rewritten as T at import time.
/// Protein data is left untouched because U there is selenocysteine.
public enum ThymineAlphabet {
    /// Letters that occur in protein sequences but never in IUPAC nucleotide codes.
    private static let proteinOnly: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in "EFIJLOPQZefijlopqz".utf8 { table[Int(byte)] = true }
        return table
    }()

    /// Returns `residues` with U/u replaced by T/t.
    public static func normalized(_ residues: String) -> String {
        guard residues.contains(where: { $0 == "U" || $0 == "u" }) else { return residues }
        return String(residues.map { $0 == "U" ? "T" : $0 == "u" ? "t" : $0 })
    }

    /// Whether `residues` contain a letter that only occurs in protein sequences.
    public static func containsProteinOnlyResidues<S: StringProtocol>(_ residues: S) -> Bool {
        residues.utf8.contains { proteinOnly[Int($0)] }
    }

    /// Normalizes a set of rows together (for example an alignment) unless any row is protein.
    public static func normalizedIfNucleotide(_ rows: [String]) -> [String] {
        guard !rows.contains(where: containsProteinOnlyResidues) else { return rows }
        return rows.map(normalized)
    }

    /// Rewrites U/u to T/t on the sequence lines of an uncompressed FASTA file in place.
    ///
    /// Header lines are never changed and gzip-compressed files are skipped. A file whose sequence lines contain protein-only
    /// letters is left untouched. Returns whether the file was rewritten; a file with no
    /// uracil costs one streaming read and is not rewritten.
    @discardableResult
    public static func normalizeFASTAFile(at url: URL, chunkSize: Int = 4 << 20) throws -> Bool {
        let magic = try FileHandle(forReadingFrom: url)
        let head = try magic.read(upToCount: 2) ?? Data()
        try magic.close()
        guard head != Data([0x1F, 0x8B]) else { return false }  // compressed input is not text

        var scan = Scanner()
        try stream(url, chunkSize: chunkSize) { chunk in
            chunk.withUnsafeBufferPointer { scan.consume($0) }
        }
        guard scan.sawUracil, !scan.sawProteinOnly else { return false }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).thymine-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var inHeader = false, atLineStart = true
            try stream(url, chunkSize: chunkSize) { chunk in
                var bytes = chunk
                for index in bytes.indices {
                    let byte = bytes[index]
                    if atLineStart { inHeader = byte == UInt8(ascii: ">") }
                    if byte == UInt8(ascii: "\n") {
                        atLineStart = true
                        inHeader = false
                        continue
                    }
                    atLineStart = false
                    if !inHeader {
                        if byte == UInt8(ascii: "U") { bytes[index] = UInt8(ascii: "T") }
                        else if byte == UInt8(ascii: "u") { bytes[index] = UInt8(ascii: "t") }
                    }
                }
                try output.write(contentsOf: bytes)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return true
    }

    private struct Scanner {
        var inHeader = false, atLineStart = true
        var sawUracil = false, sawProteinOnly = false

        mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
            for byte in bytes {
                if atLineStart { inHeader = byte == UInt8(ascii: ">") }
                if byte == UInt8(ascii: "\n") {
                    atLineStart = true
                    inHeader = false
                    continue
                }
                atLineStart = false
                guard !inHeader else { continue }
                if byte == UInt8(ascii: "U") || byte == UInt8(ascii: "u") { sawUracil = true }
                else if ThymineAlphabet.proteinOnly[Int(byte)] { sawProteinOnly = true }
            }
        }
    }

    private static func stream(_ url: URL, chunkSize: Int, _ body: ([UInt8]) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
            try body([UInt8](data))
        }
    }
}
