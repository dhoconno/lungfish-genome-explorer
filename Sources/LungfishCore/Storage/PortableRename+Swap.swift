// PortableRename+Swap.swift - URL calls, the RENAME_SWAP fallback and its self-heal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

extension PortableRename {
    /// Exchanges two existing entries, as `RENAME_SWAP` does.
    @discardableResult
    public static func swap(_ first: URL, _ second: URL) throws -> Mechanism {
        try swap(first, second, operations: .current)
    }

    package static func swap(_ first: URL, _ second: URL, operations: Operations) throws -> Mechanism {
        try perform(first, second, flags: UInt32(RENAME_SWAP), operations: operations)
    }

    /// Moves `source` to `destination`, refusing to replace an existing entry.
    @discardableResult
    public static func exclusive(_ source: URL, to destination: URL) throws -> Mechanism {
        try exclusive(source, to: destination, operations: .current)
    }

    package static func exclusive(_ source: URL, to destination: URL, operations: Operations) throws -> Mechanism {
        try perform(source, destination, flags: UInt32(RENAME_EXCL), operations: operations)
    }

    // MARK: - Swap fallback

    /// The infix of a tombstone name: `.<name>.lungfish-swap-<UUID>`.
    public static let swapTombstoneInfix = ".lungfish-swap-"

    /// Exchanges two entries with three exclusive renames when the volume
    /// rejects `RENAME_SWAP`:
    ///
    /// 1. `second` moves to a hidden tombstone beside it.
    /// 2. `first` moves onto `second`'s name.
    /// 3. The tombstone moves onto `first`'s name.
    ///
    /// A failed step undoes the earlier ones, so both entries end up where
    /// they started. Unlike `RENAME_SWAP` this is not atomic: a crash between
    /// steps 1 and 2 leaves `second` missing and its old entry under the
    /// tombstone. ``recoverInterruptedSwaps(underProject:maximumDepth:)`` puts it back, and every
    /// swap runs that recovery for its own `second` before it starts.
    package static func fallbackSwapReporting(
        _ firstParent: Int32,
        _ firstName: UnsafePointer<CChar>,
        _ secondParent: Int32,
        _ secondName: UnsafePointer<CChar>,
        operations: Operations
    ) -> Outcome {
        let second = String(cString: secondName)
        if let secondURL = resolvedURL(parent: secondParent, name: second) {
            recoverInterruptedSwaps(of: secondURL, operations: operations)
        }
        let slash = second.lastIndex(of: "/")
        let secondDirectoryPart = slash.map { String(second[...$0]) } ?? ""
        let secondBase = slash.map { String(second[second.index(after: $0)...]) } ?? second
        let tombstone = "\(secondDirectoryPart).\(secondBase)\(swapTombstoneInfix)\(UUID().uuidString)"

        func exclusive(_ fromParent: Int32, _ from: String, _ toParent: Int32, _ to: String) -> Int32 {
            from.withCString { fromPointer in
                to.withCString { toPointer in
                    renameatxNPReporting(
                        fromParent, fromPointer, toParent, toPointer, UInt32(RENAME_EXCL),
                        operations: operations
                    ).status
                }
            }
        }
        let first = String(cString: firstName)

        guard exclusive(secondParent, second, secondParent, tombstone) == 0 else {
            return Outcome(status: -1, mechanism: .rotationFallback)
        }
        guard exclusive(firstParent, first, secondParent, second) == 0 else {
            let code = errno
            _ = exclusive(secondParent, tombstone, secondParent, second)
            errno = code
            return Outcome(status: -1, mechanism: .rotationFallback)
        }
        guard exclusive(secondParent, tombstone, firstParent, first) == 0 else {
            let code = errno
            if exclusive(secondParent, second, firstParent, first) == 0 {
                _ = exclusive(secondParent, tombstone, secondParent, second)
            }
            errno = code
            return Outcome(status: -1, mechanism: .rotationFallback)
        }
        return Outcome(status: 0, mechanism: .rotationFallback)
    }

    // MARK: - Self-heal

    /// Restores entries that an interrupted swap left under a tombstone,
    /// anywhere under `projectURL` and at most `maximumDepth` levels down.
    /// An entry that is missing, or is the empty file an interrupted ExFAT
    /// rename reserved it with, takes its newest regular tombstone that holds
    /// bytes, as `DurableReplace.recover` chooses. Otherwise a tombstone is
    /// restored only when its entry is missing. One beside a present entry
    /// holds a retired generation and is left alone, never deleted. Symbolic
    /// links are not followed. Opening a project runs this, and a read runs
    /// no recovery. Returns the restored entries.
    @discardableResult
    public static func recoverInterruptedSwaps(underProject projectURL: URL, maximumDepth: Int = 12) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var tombstonesByDirectory: [URL: [String]] = [:]
        for case let url as URL in enumerator {
            if enumerator.level >= maximumDepth { enumerator.skipDescendants() }
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.contains(swapTombstoneInfix) else { continue }
            enumerator.skipDescendants()
            tombstonesByDirectory[url.deletingLastPathComponent(), default: []].append(name)
        }
        return tombstonesByDirectory.keys.sorted { $0.path < $1.path }.flatMap { directory in
            restoreTombstones(
                tombstonesByDirectory[directory, default: []].sorted(),
                in: directory,
                replacingEmptyEntries: true,
                operations: .current
            )
        }
    }

    @discardableResult
    private static func recoverInterruptedSwaps(of entry: URL, operations: Operations) -> [URL] {
        let directory = entry.deletingLastPathComponent()
        let prefix = ".\(entry.lastPathComponent)\(swapTombstoneInfix)"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // A swap's own pre-step keeps the missing-entry rule, so the name of
        // an observed write never changes under it.
        return restoreTombstones(
            names.filter { $0.hasPrefix(prefix) }.sorted(),
            in: directory,
            replacingEmptyEntries: false,
            operations: operations
        )
    }

    private static func restoreTombstones(
        _ names: [String],
        in directory: URL,
        replacingEmptyEntries: Bool,
        operations: Operations
    ) -> [URL] {
        var restored: [URL] = []
        var decided: Set<String> = []
        if replacingEmptyEntries {
            let byEntry = Dictionary(grouping: names.compactMap { name in entryName(forTombstone: name).map { ($0, name) } }) { $0.0 }
            for entryName in byEntry.keys.sorted() {
                let tombstones = byEntry[entryName, default: []].map { $0.1 }
                guard let newest = newestFileHoldingBytes(tombstones, in: directory) else { continue }
                decided.insert(entryName)
                if let entry = restore(newest, over: entryName, in: directory, operations: operations) {
                    restored.append(entry)
                }
            }
        }
        for name in names {
            guard let entryName = entryName(forTombstone: name), !decided.contains(entryName) else { continue }
            let entry = directory.appendingPathComponent(entryName)
            var information = stat()
            guard lstat(entry.path, &information) != 0, errno == ENOENT else { continue }
            let tombstone = directory.appendingPathComponent(name)
            if (try? exclusive(tombstone, to: entry, operations: operations)) != nil {
                restored.append(entry)
            }
        }
        return restored
    }

    /// The newest regular tombstone that holds bytes, by modification time and
    /// then by name.
    private static func newestFileHoldingBytes(_ tombstones: [String], in directory: URL) -> String? {
        var newest: (name: String, modified: timespec)?
        for name in tombstones {
            var information = stat()
            guard lstat(directory.appendingPathComponent(name).path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG,
                  information.st_size > 0 else { continue }
            let modified = information.st_mtimespec
            if let current = newest {
                let older = (modified.tv_sec, modified.tv_nsec, name) <= (current.modified.tv_sec, current.modified.tv_nsec, current.name)
                if older { continue }
            }
            newest = (name, modified)
        }
        return newest?.name
    }

    /// Moves `tombstone` onto its entry when the entry is missing or an empty
    /// regular file, unlinking the empty file only while `lstat` still finds
    /// it empty. Returns the entry when it was restored.
    private static func restore(
        _ tombstone: String,
        over entryName: String,
        in directory: URL,
        operations: Operations
    ) -> URL? {
        let entry = directory.appendingPathComponent(entryName)
        var information = stat()
        if lstat(entry.path, &information) == 0 {
            // `lstat` runs right before the unlink, so only a file that is
            // still empty is removed.
            guard information.st_mode & S_IFMT == S_IFREG, information.st_size == 0,
                  entry.path.withCString({ operations.removeEntry(AT_FDCWD, $0, 0) }) == 0 else { return nil }
        } else if errno != ENOENT {
            return nil
        }
        let source = directory.appendingPathComponent(tombstone)
        return (try? exclusive(source, to: entry, operations: operations)) == nil ? nil : entry
    }

    /// The entry a tombstone belongs to, or `nil` when `name` is not a tombstone.
    static func entryName(forTombstone name: String) -> String? {
        guard name.hasPrefix("."),
              let range = name.range(of: swapTombstoneInfix, options: .backwards),
              UUID(uuidString: String(name[range.upperBound...])) != nil else {
            return nil
        }
        let entry = String(name[name.index(after: name.startIndex)..<range.lowerBound])
        return entry.isEmpty ? nil : entry
    }

    private static func resolvedURL(parent: Int32, name: String) -> URL? {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        if parent == AT_FDCWD {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parent, F_GETPATH, &buffer) != -1 else { return nil }
        let directory = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
    }

    private static func perform(_ source: URL, _ destination: URL, flags: UInt32, operations: Operations) throws -> Mechanism {
        let outcome = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatxNPReporting(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, flags, operations: operations)
            }
        }
        guard outcome.status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return outcome.mechanism
    }
}
