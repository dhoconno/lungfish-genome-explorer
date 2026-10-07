import Darwin
import Foundation

extension PortableRename.Operations {
    /// The environment variable that makes every flagged rename behave as on
    /// ExFAT. Honoured only in Debug builds.
    package static let simulateUnsupportedFlagsVariable = "LUNGFISH_SIMULATE_UNSUPPORTED_RENAME_FLAGS"

    package static func forEnvironment(_ environment: [String: String]) -> PortableRename.Operations {
        #if DEBUG
        if environment[simulateUnsupportedFlagsVariable] == "1" {
            return unsupportedFlags
        }
        #endif
        return PortableRename.Operations()
    }

    /// The system calls of a volume without `RENAME_EXCL` or `RENAME_SWAP`.
    package static let unsupportedFlags = PortableRename.Operations(
        nativeRename: { sourceParent, sourceName, destinationParent, destinationName, flags in
            guard flags == 0 else {
                errno = ENOTSUP
                return -1
            }
            return Darwin.renameatx_np(sourceParent, sourceName, destinationParent, destinationName, 0)
        }
    )
}

extension PortableRename.Operations {
    /// The operations every rename uses: ``darwin`` unless a test has
    /// overridden them for the current task.
    package static var current: PortableRename.Operations {
        PortableRename.overrideOperations ?? .darwin
    }
}

extension PortableRename {
    /// Replaces the system calls for the current task and the synchronous
    /// calls it makes. Tests use ``simulatingUnsupportedFlags(_:)``.
    @TaskLocal package static var overrideOperations: Operations?

    /// Runs `body` as if the volume were ExFAT: every rename with
    /// `RENAME_EXCL` or `RENAME_SWAP` takes its fallback.
    package static func simulatingUnsupportedFlags<Result>(_ body: () throws -> Result) rethrows -> Result {
        try $overrideOperations.withValue(Operations.unsupportedFlags, operation: body)
    }

    package static func simulatingUnsupportedFlags<Result>(
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        try await $overrideOperations.withValue(Operations.unsupportedFlags, operation: body)
    }

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
    /// tombstone. ``recoverInterruptedSwaps(in:)`` puts it back, and every
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

    /// Restores entries that an interrupted swap left under a tombstone name
    /// in `directory`. A tombstone is restored only when the entry it belongs
    /// to is missing. A tombstone beside a present entry holds a retired
    /// generation and is left alone, never deleted. Returns the restored entries.
    @discardableResult
    public static func recoverInterruptedSwaps(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return restoreTombstones(names.sorted(), in: directory, operations: .current)
    }

    /// Restores interrupted swaps anywhere under `projectURL`, at most
    /// `maximumDepth` levels down. Symbolic links are not followed.
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
            restoreTombstones(tombstonesByDirectory[directory, default: []].sorted(), in: directory, operations: .current)
        }
    }

    @discardableResult
    private static func recoverInterruptedSwaps(of entry: URL, operations: Operations) -> [URL] {
        let directory = entry.deletingLastPathComponent()
        let prefix = ".\(entry.lastPathComponent)\(swapTombstoneInfix)"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return restoreTombstones(names.filter { $0.hasPrefix(prefix) }.sorted(), in: directory, operations: operations)
    }

    private static func restoreTombstones(_ names: [String], in directory: URL, operations: Operations) -> [URL] {
        var restored: [URL] = []
        for name in names {
            guard let entryName = entryName(forTombstone: name) else { continue }
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
