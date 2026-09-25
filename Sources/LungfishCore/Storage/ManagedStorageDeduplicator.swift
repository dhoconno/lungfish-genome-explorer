// ManagedStorageDeduplicator.swift - Reclaim duplicate managed storage with APFS clones
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Options for one deduplication pass.
public struct ManagedStorageDedupeOptions: Sendable, Equatable {
    /// Managed storage roots to scan. Symbolic links are never followed out of them.
    public var roots: [URL]
    /// Whether `conda/envs/` is scanned file by file. Environments hardlink into
    /// the package cache, so scanning them is what lets a hardlinked package be
    /// replaced completely and its old inode freed.
    public var includeCondaEnvironments: Bool
    /// Files below this size are ignored; a clone still costs an inode and the
    /// APFS block size makes savings on tiny files illusory.
    public var minimumFileSize: Int

    public init(roots: [URL], includeCondaEnvironments: Bool = true, minimumFileSize: Int = 4096) {
        self.roots = roots.map { $0.standardizedFileURL }
        self.includeCondaEnvironments = includeCondaEnvironments
        self.minimumFileSize = minimumFileSize
    }
}

/// The outcome of a dry run or an applied deduplication pass.
public struct ManagedStorageDedupeReport: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case dryRun = "dry-run", apply }

    public struct RootSummary: Codable, Sendable, Equatable {
        public var path: String
        public var filesExamined: Int
        public var bytesExamined: Int64
        public var duplicateFiles: Int
        public var bytesReclaimable: Int64
        public var bytesReclaimed: Int64
        public var filesReplaced: Int
    }

    public struct DuplicateSet: Codable, Sendable, Equatable {
        public var sha256: String
        public var size: Int64
        public var keptPath: String
        public var duplicatePaths: [String]
        public var bytesReclaimable: Int64
    }

    public struct Replacement: Codable, Sendable, Equatable {
        public var path: String
        public var keptPath: String
        public var size: Int64
    }

    public var mode: Mode
    public var startedAt: Date
    public var finishedAt: Date
    public var roots: [RootSummary]
    public var filesExamined: Int
    public var bytesExamined: Int64
    public var filesHashed: Int
    public var duplicateSets: Int
    public var duplicateFiles: Int
    public var bytesReclaimable: Int64
    public var bytesReclaimed: Int64
    /// Bytes in duplicate files that already share blocks with the kept copy
    /// (APFS clones), which a re-clone cannot reclaim.
    public var bytesAlreadyShared: Int64
    /// Files skipped because another process holds them open.
    public var filesOpenElsewhere: Int
    /// Files skipped because they have hard links outside the scanned trees, so
    /// replacing the scanned links would not free the inode.
    public var filesWithExternalLinks: Int
    public var sets: [DuplicateSet]
    public var replacements: [Replacement]
    public var failures: [String]
    public var blockers: [String]

    public init(mode: Mode, startedAt: Date) {
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = startedAt
        self.roots = []
        self.filesExamined = 0
        self.bytesExamined = 0
        self.filesHashed = 0
        self.duplicateSets = 0
        self.duplicateFiles = 0
        self.bytesReclaimable = 0
        self.bytesReclaimed = 0
        self.bytesAlreadyShared = 0
        self.filesOpenElsewhere = 0
        self.filesWithExternalLinks = 0
        self.sets = []
        self.replacements = []
        self.failures = []
        self.blockers = []
    }
}

public enum ManagedStorageDedupeError: Error, LocalizedError, Equatable, Sendable {
    case installInProgress([String])
    case noRoots

    public var errorDescription: String? {
        switch self {
        case .installInProgress(let blockers):
            return "A managed install or download is in progress; wait for it to finish before applying. "
                + blockers.joined(separator: "; ")
        case .noRoots:
            return "No managed storage roots exist to scan."
        }
    }
}

/// Finds identical files across managed storage roots and replaces every
/// duplicate with an APFS clone of one kept copy.
///
/// Algorithm:
/// 1. Walk `databases/`, `conda/pkgs/` and (optionally) `conda/envs/` under each
///    root, never following symbolic links and skipping install transaction files.
/// 2. Group paths by inode (hard links are one physical file), then physical
///    files by size. Only sizes seen more than once go further.
/// 3. Inside one size group, files that already share an APFS clone identifier
///    are one family and are never hashed against each other. One
///    representative per family is digested with streaming SHA-256, so a tree
///    that is already cloned costs no hashing at all.
/// 4. Families with one digest are one duplicate set. One family is kept (the
///    most linked, then the earliest root); every other family is a duplicate.
/// 5. Applying clones the kept file to a temporary name next to each duplicate
///    path, verifies size and SHA-256 of the clone, preserves mode, xattrs and
///    times, and renames it over the duplicate. Open readers keep their old
///    inode. A family is only counted as reclaimed once every hard link to its
///    inode has been replaced, so the inode is actually freed. Open files are
///    checked only when applying, against one snapshot of the process table
///    captured on first use; a dry run never inspects processes.
public struct ManagedStorageDeduplicator: Sendable {
    public static let logFilename = "storage-dedupe-log.jsonl"
    static let temporaryPrefix = ".lungfish-dedupe-"

    public typealias ProgressHandler = @Sendable (String) -> Void

    /// Builds one open-file check per apply pass. It is invoked at most once
    /// per run, only when applying, and only when there is a duplicate to
    /// replace, so a dry run never inspects the process table.
    public typealias OpenFileCheckFactory = @Sendable () -> (@Sendable (URL) -> Bool)

    private var fileManager: FileManager { .default }
    private let openFileCheckFactory: OpenFileCheckFactory
    private let cloneIdentifier: @Sendable (URL) -> UInt64?
    private let now: @Sendable () -> Date

    public init() {
        self.init(
            openFileCheckFactory: {
                let snapshot = APFSCloneSupport.OpenFileSnapshot.capture()
                return { snapshot.contains($0) }
            },
            cloneIdentifier: APFSCloneSupport.cloneIdentifier(of:),
            now: Date.init
        )
    }

    init(
        openFileCheckFactory: @escaping OpenFileCheckFactory,
        cloneIdentifier: @escaping @Sendable (URL) -> UInt64?,
        now: @escaping @Sendable () -> Date
    ) {
        self.openFileCheckFactory = openFileCheckFactory
        self.cloneIdentifier = cloneIdentifier
        self.now = now
    }

    /// Throttles progress messages to one every `interval` seconds.
    private final class ProgressReporter {
        private let handler: ProgressHandler?
        private let started: Date
        private var lastReport: Date
        private let interval: TimeInterval
        var filesScanned = 0
        var filesHashed = 0
        var bytesHashed: Int64 = 0

        init(handler: ProgressHandler?, started: Date, interval: TimeInterval = 10) {
            self.handler = handler
            self.started = started
            self.lastReport = started
            self.interval = interval
        }

        func tick(phase: String, force: Bool = false) {
            guard let handler else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= interval else { return }
            lastReport = now
            let elapsed = Int(now.timeIntervalSince(started))
            let hashed = ByteCountFormatter.string(fromByteCount: bytesHashed, countStyle: .file)
            handler("\(phase): \(filesScanned) files scanned, \(filesHashed) hashed (\(hashed)), \(elapsed)s elapsed")
        }
    }

    // MARK: - Public entry points

    /// Scans without changing anything.
    public func dryRun(_ options: ManagedStorageDedupeOptions, progress: ProgressHandler? = nil) throws -> ManagedStorageDedupeReport {
        try run(options, apply: false, progress: progress)
    }

    /// Scans and replaces duplicates. Refuses while a managed install holds a
    /// root busy.
    public func apply(_ options: ManagedStorageDedupeOptions, progress: ProgressHandler? = nil) throws -> ManagedStorageDedupeReport {
        try run(options, apply: true, progress: progress)
    }

    /// Reasons an apply pass must not run right now: a held conda install lock or
    /// a database install transaction in flight under any root.
    public func installBlockers(in roots: [URL]) -> [String] {
        var blockers: [String] = []
        for root in roots {
            let lockURL = root.appendingPathComponent("conda", isDirectory: true).appendingPathComponent(".install.lock")
            if fileManager.fileExists(atPath: lockURL.path), lockIsHeld(lockURL) {
                blockers.append("conda install lock held at \(lockURL.path)")
            }
            let databases = root.appendingPathComponent("databases", isDirectory: true)
            if let enumerator = fileManager.enumerator(
                at: databases, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [], errorHandler: { _, _ in true }
            ) {
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if enumerator.level > 3 { enumerator.skipDescendants() }
                    if Self.isTransactionDirectory(name), values?.isDirectory == true {
                        blockers.append("database install transaction at \(url.path)")
                        enumerator.skipDescendants()
                    } else if Self.isPartialDownload(name),
                              let modified = values?.contentModificationDate,
                              now().timeIntervalSince(modified) < 3600 {
                        blockers.append("active download at \(url.path)")
                    }
                }
            }
        }
        return blockers
    }

    // MARK: - Scan

    struct PhysicalFile {
        let device: dev_t
        let inode: ino_t
        let linkCount: Int
        let size: Int64
        let allocatedBytes: Int64
        var paths: [URL]
        var rootIndex: Int
    }

    struct Family {
        var files: [PhysicalFile]
        var cloneID: UInt64?
        var size: Int64 { files.first?.size ?? 0 }
        var paths: [URL] { files.flatMap(\.paths) }
        var linkCount: Int { files.reduce(0) { $0 + $1.paths.count } }
        var rootIndex: Int { files.map(\.rootIndex).min() ?? 0 }
        var fullyLinked: Bool { files.allSatisfy { $0.linkCount == $0.paths.count } }
        var allocatedBytes: Int64 { files.reduce(0) { $0 + $1.allocatedBytes } }
    }

    private func run(_ options: ManagedStorageDedupeOptions, apply: Bool, progress: ProgressHandler?) throws -> ManagedStorageDedupeReport {
        let roots = options.roots.filter { isDirectory($0) }
        guard !roots.isEmpty else { throw ManagedStorageDedupeError.noRoots }
        var report = ManagedStorageDedupeReport(mode: apply ? .apply : .dryRun, startedAt: now())
        report.blockers = installBlockers(in: roots)
        if apply, !report.blockers.isEmpty {
            throw ManagedStorageDedupeError.installInProgress(report.blockers)
        }

        let reporter = ProgressReporter(handler: progress, started: report.startedAt)
        var physical: [String: PhysicalFile] = [:]
        var rootSummaries = roots.map {
            ManagedStorageDedupeReport.RootSummary(
                path: $0.path, filesExamined: 0, bytesExamined: 0, duplicateFiles: 0,
                bytesReclaimable: 0, bytesReclaimed: 0, filesReplaced: 0
            )
        }
        for (rootIndex, root) in roots.enumerated() {
            for directory in Self.scanDirectories(under: root, includeEnvironments: options.includeCondaEnvironments) {
                scan(directory: directory, rootIndex: rootIndex, minimumSize: options.minimumFileSize,
                     into: &physical, summary: &rootSummaries[rootIndex], reporter: reporter)
            }
        }
        report.filesExamined = rootSummaries.reduce(0) { $0 + $1.filesExamined }
        report.bytesExamined = rootSummaries.reduce(0) { $0 + $1.bytesExamined }
        reporter.tick(phase: "Scanned", force: true)

        // Group by size; only sizes seen more than once can hold duplicates.
        var bySize: [Int64: [PhysicalFile]] = [:]
        for file in physical.values { bySize[file.size, default: []].append(file) }
        let candidates = bySize.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }

        // The open-file check is built once per apply pass, on first use.
        var openFileCheck: (@Sendable (URL) -> Bool)?
        func isOpen(_ url: URL) -> Bool {
            if openFileCheck == nil { openFileCheck = openFileCheckFactory() }
            return openFileCheck!(url)
        }

        for (size, files) in candidates {
            // Files already in one APFS clone family share blocks: nothing to
            // gain and nothing to hash. Only distinct families are digested,
            // one representative each.
            let sizeFamilies = Self.families(of: files, cloneIdentifier: cloneIdentifier)
            guard sizeFamilies.count > 1 else {
                report.bytesAlreadyShared += Int64(files.count - 1) * size
                continue
            }
            var byHash: [String: [Family]] = [:]
            for family in sizeFamilies {
                guard let path = family.paths.first else { continue }
                do {
                    let digest = try FileDigest.sha256(of: path)
                    reporter.filesHashed += 1
                    reporter.bytesHashed += size
                    report.filesHashed += 1
                    byHash[digest, default: []].append(family)
                } catch {
                    report.failures.append("hash \(path.path): \(error.localizedDescription)")
                }
                reporter.tick(phase: "Hashing")
            }
            for (digest, group) in byHash where group.count > 1 {
                var families = group
                families.sort { lhs, rhs in
                    if lhs.linkCount != rhs.linkCount { return lhs.linkCount > rhs.linkCount }
                    if lhs.rootIndex != rhs.rootIndex { return lhs.rootIndex < rhs.rootIndex }
                    return (lhs.paths.first?.path ?? "") < (rhs.paths.first?.path ?? "")
                }
                let kept = families.removeFirst()
                if kept.files.count > 1 {
                    report.bytesAlreadyShared += Int64(kept.files.count - 1) * size
                }
                guard let keptPath = kept.paths.sorted(by: { $0.path < $1.path }).first else { continue }
                var set = ManagedStorageDedupeReport.DuplicateSet(
                    sha256: digest, size: size, keptPath: keptPath.path, duplicatePaths: [], bytesReclaimable: 0
                )
                for family in families {
                    if family.files.count > 1 {
                        report.bytesAlreadyShared += Int64(family.files.count - 1) * size
                    }
                    guard family.fullyLinked else {
                        report.filesWithExternalLinks += family.files.count
                        continue
                    }
                    if apply {
                        let openPaths = family.paths.filter(isOpen)
                        guard openPaths.isEmpty else {
                            report.filesOpenElsewhere += openPaths.count
                            continue
                        }
                    }
                    let reclaimable = min(family.allocatedBytes, Int64(family.files.count) * size)
                    set.duplicatePaths.append(contentsOf: family.paths.map(\.path))
                    set.bytesReclaimable += reclaimable
                    report.duplicateFiles += family.paths.count
                    report.bytesReclaimable += reclaimable
                    rootSummaries[family.rootIndex].duplicateFiles += family.paths.count
                    rootSummaries[family.rootIndex].bytesReclaimable += reclaimable
                    guard apply else { continue }
                    let replaced = replace(family: family, with: keptPath, digest: digest, report: &report)
                    if replaced {
                        report.bytesReclaimed += reclaimable
                        rootSummaries[family.rootIndex].bytesReclaimed += reclaimable
                        rootSummaries[family.rootIndex].filesReplaced += family.paths.count
                    }
                    reporter.tick(phase: apply ? "Replacing" : "Comparing")
                }
                guard !set.duplicatePaths.isEmpty else { continue }
                report.duplicateSets += 1
                report.sets.append(set)
            }
        }
        reporter.tick(phase: apply ? "Replaced" : "Compared", force: true)
        report.roots = rootSummaries
        report.finishedAt = now()
        if apply {
            for root in roots { writeLogRecord(report, under: root) }
        }
        return report
    }

    static func scanDirectories(under root: URL, includeEnvironments: Bool) -> [URL] {
        var directories = [
            root.appendingPathComponent("databases", isDirectory: true),
            root.appendingPathComponent("conda", isDirectory: true).appendingPathComponent("pkgs", isDirectory: true),
        ]
        if includeEnvironments {
            directories.append(root.appendingPathComponent("conda", isDirectory: true).appendingPathComponent("envs", isDirectory: true))
        }
        return directories
    }

    private func scan(
        directory: URL, rootIndex: Int, minimumSize: Int,
        into physical: inout [String: PhysicalFile],
        summary: inout ManagedStorageDedupeReport.RootSummary,
        reporter: ProgressReporter
    ) {
        guard isDirectory(directory) else { return }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            let mode = metadata.st_mode & S_IFMT
            if mode == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            if mode == S_IFDIR {
                if Self.isTransactionDirectory(name) { enumerator.skipDescendants() }
                continue
            }
            guard mode == S_IFREG, !Self.isTransientFile(name) else { continue }
            let size = Int64(metadata.st_size)
            summary.filesExamined += 1
            summary.bytesExamined += size
            reporter.filesScanned += 1
            reporter.tick(phase: "Scanning")
            guard size >= Int64(minimumSize) else { continue }
            let key = "\(metadata.st_dev):\(metadata.st_ino)"
            if var existing = physical[key] {
                existing.paths.append(url.standardizedFileURL)
                physical[key] = existing
            } else {
                physical[key] = PhysicalFile(
                    device: metadata.st_dev, inode: metadata.st_ino, linkCount: Int(metadata.st_nlink),
                    size: size, allocatedBytes: Int64(metadata.st_blocks) * 512,
                    paths: [url.standardizedFileURL], rootIndex: rootIndex
                )
            }
        }
    }

    static func families(of files: [PhysicalFile], cloneIdentifier: (URL) -> UInt64?) -> [Family] {
        var byClone: [UInt64: Family] = [:]
        var unknown: [Family] = []
        for file in files {
            guard let path = file.paths.first, let id = cloneIdentifier(path) else {
                unknown.append(Family(files: [file], cloneID: nil))
                continue
            }
            byClone[id, default: Family(files: [], cloneID: id)].files.append(file)
        }
        return byClone.values.sorted { ($0.cloneID ?? 0) < ($1.cloneID ?? 0) } + unknown
    }

    // MARK: - Replace

    /// Replaces every path of `family` with a verified clone of `keptPath`.
    /// Returns `true` only when every link was replaced, which frees the inode.
    private func replace(family: Family, with keptPath: URL, digest: String, report: inout ManagedStorageDedupeReport) -> Bool {
        var replacedAll = true
        for path in family.paths {
            do {
                try replaceFile(at: path, withCloneOf: keptPath, expectedDigest: digest, expectedSize: family.size)
                report.replacements.append(.init(path: path.path, keptPath: keptPath.path, size: family.size))
            } catch {
                replacedAll = false
                report.failures.append("replace \(path.path): \(error.localizedDescription)")
            }
        }
        return replacedAll
    }

    func replaceFile(at path: URL, withCloneOf keptPath: URL, expectedDigest: String, expectedSize: Int64) throws {
        let directory = path.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString)")
        try APFSCloneSupport.cloneItem(at: keptPath, to: temporary)
        do {
            var cloneMetadata = stat()
            guard lstat(temporary.path, &cloneMetadata) == 0, (cloneMetadata.st_mode & S_IFMT) == S_IFREG,
                  Int64(cloneMetadata.st_size) == expectedSize else {
                throw ManagedStorageDedupeReplaceError.cloneSizeMismatch(temporary.path)
            }
            guard try FileDigest.sha256(of: temporary) == expectedDigest else {
                throw ManagedStorageDedupeReplaceError.cloneDigestMismatch(temporary.path)
            }
            try preserveMetadata(from: path, to: temporary)
            guard rename(temporary.path, path.path) == 0 else {
                throw ManagedStorageDedupeReplaceError.renameFailed(path.path, errno)
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private func preserveMetadata(from original: URL, to clone: URL) throws {
        var metadata = stat()
        guard lstat(original.path, &metadata) == 0 else {
            throw ManagedStorageDedupeReplaceError.metadataUnavailable(original.path)
        }
        // Extended attributes and ACLs first, then the mode and times so that
        // nothing below resets what came before.
        let flags = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        guard copyfile(original.path, clone.path, nil, flags) == 0 else {
            throw ManagedStorageDedupeReplaceError.metadataCopyFailed(clone.path, errno)
        }
        guard chmod(clone.path, metadata.st_mode & 0o7777) == 0 else {
            throw ManagedStorageDedupeReplaceError.metadataCopyFailed(clone.path, errno)
        }
        var times = [timespec(tv_sec: metadata.st_atimespec.tv_sec, tv_nsec: metadata.st_atimespec.tv_nsec),
                     timespec(tv_sec: metadata.st_mtimespec.tv_sec, tv_nsec: metadata.st_mtimespec.tv_nsec)]
        guard utimensat(AT_FDCWD, clone.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ManagedStorageDedupeReplaceError.metadataCopyFailed(clone.path, errno)
        }
    }

    // MARK: - Helpers

    static func isTransactionDirectory(_ name: String) -> Bool {
        name.hasPrefix(".install-") || name.hasPrefix(".backup-") || name.contains(".staging-") || name.contains(".old-")
    }

    static func isPartialDownload(_ name: String) -> Bool {
        name.hasSuffix(".download") || name.hasSuffix(".partial") || name.hasSuffix(".partial.tmp")
    }

    static func isTransientFile(_ name: String) -> Bool {
        isPartialDownload(name) || name.hasPrefix(temporaryPrefix) || name == ".install.lock" || name == logFilename
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func lockIsHeld(_ lockURL: URL) -> Bool {
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func writeLogRecord(_ report: ManagedStorageDedupeReport, under root: URL) {
        struct Record: Encodable {
            let recordedAt: String
            let mode: String
            let roots: [String]
            let filesExamined: Int
            let duplicateSets: Int
            let bytesReclaimable: Int64
            let bytesReclaimed: Int64
            let filesReplacedUnderThisRoot: Int
            let bytesReclaimedUnderThisRoot: Int64
            let failures: Int
        }
        let summary = report.roots.first { $0.path == root.path }
        let record = Record(
            recordedAt: ISO8601DateFormatter().string(from: report.finishedAt),
            mode: report.mode.rawValue,
            roots: report.roots.map(\.path),
            filesExamined: report.filesExamined,
            duplicateSets: report.duplicateSets,
            bytesReclaimable: report.bytesReclaimable,
            bytesReclaimed: report.bytesReclaimed,
            filesReplacedUnderThisRoot: summary?.filesReplaced ?? 0,
            bytesReclaimedUnderThisRoot: summary?.bytesReclaimed ?? 0,
            failures: report.failures.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(contentsOf: [0x0A])
        let logURL = root.appendingPathComponent(Self.logFilename)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL, options: [.atomic])
        }
    }
}

enum ManagedStorageDedupeReplaceError: Error, LocalizedError {
    case cloneSizeMismatch(String)
    case cloneDigestMismatch(String)
    case renameFailed(String, Int32)
    case metadataUnavailable(String)
    case metadataCopyFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .cloneSizeMismatch(let path): return "clone at \(path) has the wrong size"
        case .cloneDigestMismatch(let path): return "clone at \(path) has the wrong SHA-256"
        case .renameFailed(let path, let code): return "rename over \(path) failed: \(String(cString: strerror(code)))"
        case .metadataUnavailable(let path): return "could not read metadata of \(path)"
        case .metadataCopyFailed(let path, let code): return "could not preserve metadata on \(path): \(String(cString: strerror(code)))"
        }
    }
}
