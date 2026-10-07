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
/// `<accession>_2.fastq` and `<accession>.fastq`, and the reads beyond mates
/// 1 and 2 `<accession>_3.fastq` and on. The folder can also hold other runs'
/// files, such as the user's earlier downloads, and older files of this run,
/// such as a stale mate. So `SRAService.downloadFASTQ` notes what the folder
/// holds before the tools run. It then returns only this run's read files
/// that the download wrote, and once `fasterq-dump` succeeds it removes what
/// `prefetch` added. A file that was there before is never returned and
/// never removed.
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

    private let accession: String
    private let outputDirectory: URL
    private let fastqURLs: [URL]
    private let fastqBefore: [URL: Stamp]
    /// The run's read files beyond mates 1 and 2 that the folder held before
    /// the download, by name.
    private let laterReadFilesBefore: [String: Stamp]
    /// The folder `prefetch` writes the run's archive to, or nil when the
    /// accession cannot name a folder.
    private let prefetchFolder: URL?
    /// What was at the prefetch folder's path before the download.
    private let prefetchPathBefore: PrefetchPathSnapshot

    /// What was at `<out>/<accession>` before the toolkit ran.
    enum PrefetchPathSnapshot: Equatable {
        /// Nothing was there, so whatever is there now is the toolkit's.
        case absent
        /// A folder with these entries, so only entries added since are the
        /// toolkit's.
        case folder(Set<String>)
        /// A file, a link, or a folder whose entries could not be listed.
        /// Nothing there is provably the toolkit's.
        case notTheToolkits

        init(of url: URL) {
            let fileManager = FileManager.default
            // attributesOfItem does not follow a link, so a link counts as
            // the user's and is never removed or looked into.
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                self = fileManager.fileExists(atPath: url.path) ? .notTheToolkits : .absent
                return
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else {
                self = .notTheToolkits
                return
            }
            self = .folder(Set(entries))
        }
    }

    init(accession: String, outputDirectory: URL) {
        self.accession = accession
        self.outputDirectory = outputDirectory
        fastqURLs = ["_1", "_2", ""].flatMap { suffix in
            [".fastq", ".fastq.gz"].map { outputDirectory.appendingPathComponent("\(accession)\(suffix)\($0)") }
        }
        var before: [URL: Stamp] = [:]
        for url in fastqURLs {
            before[url] = Stamp(url)
        }
        fastqBefore = before
        var laterBefore: [String: Stamp] = [:]
        for url in Self.laterReadFiles(in: outputDirectory, accession: accession) {
            laterBefore[url.lastPathComponent] = Stamp(url)
        }
        laterReadFilesBefore = laterBefore
        prefetchFolder = SRAAccessionParser.namesOneFolder(accession)
            ? outputDirectory.appendingPathComponent(accession, isDirectory: true) : nil
        prefetchPathBefore = prefetchFolder.map(PrefetchPathSnapshot.init(of:)) ?? .notTheToolkits
    }

    /// The run's FASTQ files that the download wrote, mate 1 and mate 2
    /// first and any read file beyond them last, which `SRARunReads.sorting`
    /// leaves out of the run's reads and names in its warning.
    func writtenFASTQFiles() -> [URL] {
        let reads = fastqURLs.filter { url in
            guard let stamp = Stamp(url) else { return false }
            return fastqBefore[url] != stamp
        }
        let laterFiles = Self.laterReadFiles(in: outputDirectory, accession: accession).filter { url in
            guard let stamp = Stamp(url) else { return false }
            return laterReadFilesBefore[url.lastPathComponent] != stamp
        }
        return reads + laterFiles
    }

    /// The read files of `accession` beyond mates 1 and 2 in `folder`.
    private static func laterReadFiles(in folder: URL, accession: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return SRARunReads.laterReadFiles(in: names.map { folder.appendingPathComponent($0) }, accession: accession)
    }

    /// Removes the run's FASTQ files that the download wrote, after a failed
    /// or cancelled `fasterq-dump`, so no partial mate stays. A file that was
    /// there before the download is never removed.
    func removeWrittenFASTQFiles() {
        for file in writtenFASTQFiles() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes what `prefetch` added under `<accession>/`, and the folder
    /// itself when nothing was at its path before the download. A path that
    /// existed before is never removed. Inside a folder that existed before,
    /// only entries added since are removed. When the folder could not be
    /// listed before, nothing is removed.
    func removePrefetchFiles() {
        guard let prefetchFolder else { return }
        let fileManager = FileManager.default
        switch prefetchPathBefore {
        case .absent:
            try? fileManager.removeItem(at: prefetchFolder)
        case .folder(let entriesBefore):
            let entries = (try? fileManager.contentsOfDirectory(atPath: prefetchFolder.path)) ?? []
            for entry in entries where !entriesBefore.contains(entry) {
                try? fileManager.removeItem(at: prefetchFolder.appendingPathComponent(entry))
            }
        case .notTheToolkits:
            return
        }
    }
}
