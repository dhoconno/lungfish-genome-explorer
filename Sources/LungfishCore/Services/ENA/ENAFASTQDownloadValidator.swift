// ENAFASTQDownloadValidator.swift - Sanity checks for FASTQ files fetched from ENA
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Validates a FASTQ file downloaded from ENA's HTTP mirror before it is
/// handed to the import pipeline.
///
/// ENA's mirror (`ftp.sra.ebi.ac.uk`) does not always hold every file the
/// portal filereport advertises. When a mate file is missing, the path is
/// sometimes present as an empty directory: the server answers with a 301 to
/// the trailing-slash URL and then an HTTP 200 Apache directory listing.
/// URLSession follows the redirect, so a naive status-code check accepts an
/// HTML page as `SRR…_2.fastq.gz` and fastp later fails with
/// `igzip: Error invalid gzip header`.
///
/// The checks here are cheap (a two-byte header read plus a size lookup) and
/// are shared by the CLI download path (`SRAService.downloadFASTQFromENA`) and
/// the GUI batch importer.
public enum ENAFASTQDownloadValidator {
    /// Reasons a downloaded body is not the FASTQ file ENA advertised.
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        /// The file could not be opened for reading.
        case unreadable(filename: String)
        /// The file is zero bytes long.
        case empty(filename: String)
        /// The body is an HTML document (typically a directory listing).
        case htmlBody(filename: String)
        /// The name ends in `.gz` but the body lacks the gzip magic bytes.
        case notGzip(filename: String)
        /// The body's size differs from the size the ENA portal advertised.
        case sizeMismatch(filename: String, expected: Int64, actual: Int64)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let filename):
                return "ENA download \(filename) could not be read after download."
            case .empty(let filename):
                return "ENA download \(filename) is empty."
            case .htmlBody(let filename):
                return "ENA returned an HTML page instead of \(filename). The file is missing from the ENA mirror (the server sent a directory listing)."
            case .notGzip(let filename):
                return "ENA download \(filename) is not a gzip file."
            case .sizeMismatch(let filename, let expected, let actual):
                return "ENA download \(filename) is \(actual) bytes but the ENA portal advertised \(expected) bytes."
            }
        }
    }

    private static let gzipMagic: [UInt8] = [0x1f, 0x8b]

    /// Checks that `fileURL` looks like the FASTQ file ENA advertised.
    ///
    /// - Parameters:
    ///   - fileURL: The downloaded file.
    ///   - expectedBytes: The size the ENA portal advertised for this file
    ///     (`fastq_bytes`), or nil when unknown.
    /// - Throws: ``Failure`` describing the first problem found.
    public static func validate(fileURL: URL, expectedBytes: Int64?) throws {
        let filename = fileURL.lastPathComponent

        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw Failure.unreadable(filename: filename)
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 16), !header.isEmpty else {
            throw Failure.empty(filename: filename)
        }

        if looksLikeHTML(header) {
            throw Failure.htmlBody(filename: filename)
        }

        if filename.lowercased().hasSuffix(".gz") {
            guard header.count >= 2,
                  header[header.startIndex] == gzipMagic[0],
                  header[header.startIndex + 1] == gzipMagic[1] else {
                throw Failure.notGzip(filename: filename)
            }
        }

        if let expectedBytes {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            if actual != expectedBytes {
                throw Failure.sizeMismatch(filename: filename, expected: expectedBytes, actual: actual)
            }
        }
    }

    /// The per-file sizes the ENA portal advertised, aligned index-for-index
    /// with `record.fastqHTTPURLs`. Entries are nil when the portal supplied
    /// no size for that position.
    public static func expectedByteCounts(for record: ENAReadRecord) -> [Int64?] {
        let urlCount = record.fastqHTTPURLs.count
        guard let bytesString = record.fastqBytes else {
            return Array(repeating: nil, count: urlCount)
        }
        let sizes: [Int64?] = bytesString
            .components(separatedBy: ";")
            .map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        if sizes.count >= urlCount {
            return Array(sizes.prefix(urlCount))
        }
        return sizes + Array(repeating: nil, count: urlCount - sizes.count)
    }

    /// True when the first bytes are the start of an HTML document, ignoring
    /// leading whitespace and a UTF-8 byte-order mark.
    private static func looksLikeHTML(_ header: Data) -> Bool {
        var bytes = Array(header)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes.removeFirst()
        }
        guard let first = bytes.first, first == UInt8(ascii: "<") else {
            return false
        }
        let text = String(decoding: bytes.prefix(15), as: UTF8.self).lowercased()
        return text.hasPrefix("<!doctype") || text.hasPrefix("<html") || text.hasPrefix("<head")
            || text.hasPrefix("<body") || text.hasPrefix("<?xml") || text.hasPrefix("<title")
    }
}
