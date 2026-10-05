// SRAToolkitRunner.swift - How an SRA Toolkit download runs its tools, and which files it keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Runs the SRA Toolkit's `prefetch` and `fasterq-dump` for
/// `SRAService.downloadFASTQ`.
///
/// By default the service runs the tools of the managed sra-tools
/// environment as subprocesses. A test passes a runner that writes the files
/// the tools would, so it spawns no tool and reaches no network.
public struct SRAToolkitRunner: Sendable {
    /// What one run of a tool returned.
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// The `prefetch` executable.
    public let prefetch: URL
    /// The `fasterq-dump` executable.
    public let fasterqDump: URL
    /// Runs one of the two executables with the given arguments.
    public let run: @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Result

    public init(
        prefetch: URL,
        fasterqDump: URL,
        run: @escaping @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Result
    ) {
        self.prefetch = prefetch
        self.fasterqDump = fasterqDump
        self.run = run
    }
}

/// One run's files in the output folder of an SRA Toolkit download.
///
/// `prefetch` writes the run's archive under `<accession>/`, and
/// `fasterq-dump` names the run's reads `<accession>_1.fastq`,
/// `<accession>_2.fastq` and `<accession>.fastq`. The folder can also hold
/// other runs' files, such as the user's earlier downloads, and older files
/// of this run, such as a stale mate. So `SRAService.downloadFASTQ` notes
/// what the folder holds before the tools run. It then returns only this
/// run's reads that the download wrote, and once `fasterq-dump` succeeds it
/// removes what `prefetch` added. A file that was there before is never
/// returned and never removed.
struct SRAToolkitRunFiles {
    /// What identifies one file's content: a file the download rewrote
    /// differs in at least one of these.
    private struct Stamp: Equatable {
        let fileNumber: Int?
        let modified: Date?
        let size: Int?

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.intValue
        }
    }

    private let fastqURLs: [URL]
    private let fastqBefore: [URL: Stamp]
    /// The folder `prefetch` writes the run's archive to, or nil when the
    /// accession cannot name a folder.
    private let prefetchFolder: URL?
    /// What the prefetch folder held before the download, or nil when it did
    /// not exist.
    private let prefetchEntriesBefore: Set<String>?

    init(accession: String, outputDirectory: URL) {
        fastqURLs = ["_1", "_2", ""].flatMap { suffix in
            [".fastq", ".fastq.gz"].map { outputDirectory.appendingPathComponent("\(accession)\(suffix)\($0)") }
        }
        var before: [URL: Stamp] = [:]
        for url in fastqURLs {
            before[url] = Stamp(url)
        }
        fastqBefore = before
        let namesAFolder = !accession.isEmpty && !accession.contains("/") && accession != "." && accession != ".."
        prefetchFolder = namesAFolder ? outputDirectory.appendingPathComponent(accession, isDirectory: true) : nil
        prefetchEntriesBefore = prefetchFolder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }
            .map(Set.init)
    }

    /// The run's FASTQ files that the download wrote, mate 1 and mate 2
    /// first.
    func writtenFASTQFiles() -> [URL] {
        fastqURLs.filter { url in
            guard let stamp = Stamp(url) else { return false }
            return fastqBefore[url] != stamp
        }
    }

    /// Removes what `prefetch` added under `<accession>/`, and the folder
    /// itself when the download created it.
    func removePrefetchFiles() {
        guard let prefetchFolder else { return }
        let fileManager = FileManager.default
        guard let entriesBefore = prefetchEntriesBefore else {
            try? fileManager.removeItem(at: prefetchFolder)
            return
        }
        let entries = (try? fileManager.contentsOfDirectory(atPath: prefetchFolder.path)) ?? []
        for entry in entries where !entriesBefore.contains(entry) {
            try? fileManager.removeItem(at: prefetchFolder.appendingPathComponent(entry))
        }
    }
}
