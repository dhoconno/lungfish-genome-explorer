// SRARunReads.swift - Which of an SRA run's FASTQ files make up its reads, and the lone-mate rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The reads of one SRA run, one file or both mates of a pair with the reads
/// whose mate is missing when the run has any.
///
/// ENA's mirror and the SRA Toolkit both name a run's files
/// `<accession>_1.fastq`, `<accession>_2.fastq` and `<accession>.fastq`,
/// gzipped when ENA serves them. Mates 1 and 2 go together as a pair. The
/// file without a suffix beside them holds the reads whose mate is missing,
/// and it goes with the pair as the run's unpaired reads. A run never counts
/// as one mate of a pair, so a lone mate 2 fails, and so does a lone mate 1
/// of a run its archive lists as paired. Files named for another run never
/// count, and neither do the run's read files beyond mates 1 and 2, such as
/// `<accession>_3.fastq.gz` for spots of three reads, which the warning of
/// `sorting(_:accession:enaLayout:ncbiLayout:)` names.
///
/// The window's SRA download and `lungfish-cli fetch sra download` both
/// sort a run's files with this type, and `ENAService.fastqDownloadRoute`
/// checks ENA's listing with it, so the window and the CLI take the same
/// run whole or refuse it alike.
public struct SRARunReads: Equatable, Sendable {
    /// Why a run's files hold no reads that can be taken whole.
    public struct Failure: LocalizedError, Equatable, Sendable {
        /// What is wrong with the files.
        public enum Kind: Equatable, Sendable {
            /// One mate arrived as two files, such as `.fastq` and `.fastq.gz`.
            case twoCopies(String, String)
            /// Mate 2 arrived without mate 1.
            case onlyMate2
            /// Mate 1 arrived without mate 2, and `listedBy` lists the run as
            /// paired. Nil when the file of unpaired reads beside it shows the
            /// run is paired.
            case onlyMate1(listedBy: String?)
            /// No file named for the run arrived.
            case noFile
        }

        public let accession: String
        public let kind: Kind

        public init(accession: String, kind: Kind) {
            self.accession = accession
            self.kind = kind
        }

        /// The one-line reason for files that arrived. `fetch sra download`
        /// fails with it.
        public var message: String {
            switch kind {
            case .twoCopies(let first, let second):
                return "\(accession) arrived as both \(first) and \(second)"
            case .onlyMate2:
                return "Only mate 2 of \(accession) arrived"
            case .onlyMate1(let archive?):
                return "Only mate 1 of \(accession) arrived and \(archive) lists the run as paired"
            case .onlyMate1(nil):
                return "Only mate 1 of the paired run \(accession) arrived"
            case .noFile:
                return "No FASTQ file of \(accession) arrived"
            }
        }

        /// The one-line reason for the files an archive lists, which sends
        /// the run to the other route.
        public func listingMessage(archive: String) -> String {
            switch kind {
            case .twoCopies(let first, let second):
                return "\(archive) lists \(accession) as both \(first) and \(second)"
            case .onlyMate2:
                return "\(archive) lists only mate 2 of \(accession)"
            case .onlyMate1:
                return "\(archive) lists only mate 1 of the paired run \(accession)"
            case .noFile:
                return "\(archive) lists no FASTQ file named for \(accession)"
            }
        }

        /// The reason with what the window did, which its Operations panel
        /// row shows.
        public var errorDescription: String? { "\(message), so it was not imported" }
    }

    /// Mate 1, or the run's only file.
    public let r1: URL
    /// Mate 2, or nil for single reads.
    public let r2: URL?
    /// The reads beside a pair whose mate is missing, or nil.
    public let unpaired: URL?

    /// The files in import order, mate 1, mate 2, then the unpaired reads.
    public var files: [URL] { [r1] + [r2, unpaired].compactMap { $0 } }

    /// Sorts one run's files into its reads.
    ///
    /// - Parameters:
    ///   - listedAsPaired: Whether the run's archive record lists its
    ///     layout as PAIRED.
    ///   - listedBy: The archive whose record that is, named in the reason
    ///     a lone mate 1 is refused.
    /// - Throws: `Failure` when the files hold one mate of a pair, two copies
    ///   of one file, or no file of this run.
    public init(stagedFiles: [URL], accession: String, listedAsPaired: Bool, listedBy: String? = nil) throws {
        func file(_ suffix: String) throws -> URL? {
            let names: Set = ["\(accession)\(suffix).fastq", "\(accession)\(suffix).fastq.gz"]
            let matches = stagedFiles.filter { names.contains($0.lastPathComponent) }
            guard matches.count < 2 else {
                throw Failure(
                    accession: accession,
                    kind: .twoCopies(matches[0].lastPathComponent, matches[1].lastPathComponent)
                )
            }
            return matches.first
        }
        let mate1 = try file("_1")
        let mate2 = try file("_2")
        let unsuffixed = try file("")
        switch (mate1, mate2) {
        case let (mate1?, mate2?):
            r1 = mate1
            r2 = mate2
            unpaired = unsuffixed
        case (nil, .some):
            throw Failure(accession: accession, kind: .onlyMate2)
        case let (mate1?, nil):
            if unsuffixed != nil {
                throw Failure(accession: accession, kind: .onlyMate1(listedBy: nil))
            }
            if listedAsPaired {
                throw Failure(accession: accession, kind: .onlyMate1(listedBy: listedBy ?? "the archive"))
            }
            r1 = mate1
            r2 = nil
            unpaired = nil
        case (nil, nil):
            guard let unsuffixed else {
                throw Failure(accession: accession, kind: .noFile)
            }
            r1 = unsuffixed
            r2 = nil
            unpaired = nil
        }
    }
}

/// The library layout an archive record lists for an SRA run.
public struct SRARunListedLayout: Equatable, Sendable {
    /// "ENA" or "NCBI".
    public let archive: String
    /// The layout as the record gives it, such as "PAIRED" or "SINGLE".
    public let layout: String

    public init(archive: String, layout: String) {
        self.archive = archive
        self.layout = layout
    }

    public var isPaired: Bool { layout.uppercased() == "PAIRED" }

    /// ENA's layout when ENA's record gives one, else NCBI's from `ncbiLayout`.
    /// NCBI is asked only when ENA's record gives no layout, so a run ENA
    /// describes costs no request to NCBI.
    ///
    /// - Throws: A cancellation when the task was cancelled while NCBI was
    ///   asked. `SRAService.ncbiRunInfo(forRun:)` answers nil then, as for a
    ///   run NCBI does not list, and a cancelled download must stop rather
    ///   than sort the run's files as if no archive listed a layout.
    public static func resolve(
        enaLayout: String?,
        ncbiLayout: () async throws -> String?
    ) async throws -> SRARunListedLayout? {
        if let enaLayout = enaLayout?.trimmingCharacters(in: .whitespaces), !enaLayout.isEmpty {
            return SRARunListedLayout(archive: "ENA", layout: enaLayout)
        }
        let ncbiLayout = try await ncbiLayout()
        try Task.checkCancellation()
        if let ncbi = ncbiLayout?.trimmingCharacters(in: .whitespaces), !ncbi.isEmpty {
            return SRARunListedLayout(archive: "NCBI", layout: ncbi)
        }
        return nil
    }
}

public extension SRARunReads {
    /// Sorts the files of a downloaded run with the layout its archives
    /// list, as the window and `lungfish-cli fetch sra download` both do.
    ///
    /// The layout matters only when no mate 2 arrived. It is ENA's when
    /// ENA's record gives one, else NCBI's LibraryLayout, which
    /// `ncbiLayout` supplies. A lone mate 1 of a run either archive lists as
    /// paired is refused. A run listed as paired that arrived as one file of
    /// single reads is taken as single reads, and the warning says so. So
    /// does a lone mate 1 of a run neither archive gives a layout for, and
    /// the warning names any read file beyond mates 1 and 2, which the reads
    /// leave out. Several warnings share the one line.
    ///
    /// - Returns: The reads, and the warning line to log and record under
    ///   `layoutWarning`, or nil.
    /// - Throws: `Failure` for files that are not one whole run, or a
    ///   cancellation when the task was cancelled while NCBI was asked.
    static func sorting(
        _ files: [URL],
        accession: String,
        enaLayout: String?,
        ncbiLayout: () async throws -> String?
    ) async throws -> (reads: SRARunReads, layoutWarning: String?) {
        let mate2Names: Set = ["\(accession)_2.fastq", "\(accession)_2.fastq.gz"]
        let mate2Arrived = files.contains { mate2Names.contains($0.lastPathComponent) }
        let layout = mate2Arrived
            ? nil
            : try await SRARunListedLayout.resolve(enaLayout: enaLayout, ncbiLayout: ncbiLayout)
        let reads = try SRARunReads(
            stagedFiles: files,
            accession: accession,
            listedAsPaired: layout?.isPaired == true,
            listedBy: layout?.archive
        )
        var warnings: [String] = []
        if reads.r2 == nil, let layout, layout.isPaired {
            warnings.append("\(layout.archive) lists \(accession) as paired but only one read file arrived; imported as single-end reads")
        }
        let mate1Names: Set = ["\(accession)_1.fastq", "\(accession)_1.fastq.gz"]
        if !mate2Arrived, layout == nil, mate1Names.contains(reads.r1.lastPathComponent) {
            warnings.append(
                "No layout of \(accession) came from ENA or NCBI and only \(reads.r1.lastPathComponent) arrived, so its reads import as single-end reads"
            )
        }
        let laterFiles = laterReadFiles(in: files, accession: accession)
        if !laterFiles.isEmpty {
            warnings.append(laterReadFilesWarning(laterFiles))
        }
        return (reads, warnings.isEmpty ? nil : warnings.joined(separator: ". "))
    }

    /// The read files of `accession` beyond mates 1 and 2 among `files`, such
    /// as `<accession>_3.fastq.gz`, in the order of their read numbers. ENA
    /// lists one for a run whose spots hold three reads, and `fasterq-dump`
    /// can write one. The run's reads never take them.
    static func laterReadFiles(in files: [URL], accession: String) -> [URL] {
        files
            .compactMap { file in laterReadNumber(of: file.lastPathComponent, accession: accession).map { (file, $0) } }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
            .map(\.0)
    }

    /// The read number `name` gives a read file of `accession` beyond mates 1
    /// and 2, 3 for `<accession>_3.fastq` or `<accession>_3.fastq.gz` and so
    /// on, or nil for any other name.
    static func laterReadNumber(of name: String, accession: String) -> Int? {
        let prefix = "\(accession)_"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        for suffix in [".fastq.gz", ".fastq"] where rest.hasSuffix(suffix) {
            let digits = rest.dropLast(suffix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(digits), number >= 3 else { return nil }
            return number
        }
        return nil
    }

    /// The warning line that names the read files beyond mates 1 and 2.
    private static func laterReadFilesWarning(_ files: [URL]) -> String {
        let names = files.map(\.lastPathComponent)
        guard let last = names.last, names.count > 1 else {
            return "\(names.joined()) holds reads beyond mates 1 and 2 and is not imported with the run"
        }
        let listed = names.dropLast().joined(separator: ", ") + " and " + last
        return "\(listed) hold reads beyond mates 1 and 2 and are not imported with the run"
    }
}
