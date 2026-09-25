// SafeZipExtractor.swift - ZIP extraction that refuses path traversal and escaping symlinks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One entry from a ZIP archive's central directory.
public struct ZipCentralDirectoryEntry: Sendable, Equatable {
    public let path: String
    /// Unix mode from the external attributes, when the archive was made on a Unix host.
    public let unixMode: UInt16?

    public var isDirectory: Bool {
        path.hasSuffix("/") || unixMode.map { $0 & 0o170000 == 0o040000 } == true
    }

    public var isSymbolicLink: Bool {
        unixMode.map { $0 & 0o170000 == 0o120000 } == true
    }
}

/// Extracts a ZIP archive without letting any entry land outside the destination.
///
/// Before anything is written, the central directory is read and every entry
/// name is checked: absolute paths, `..` components, backslashes, drive
/// letters and entries that would be written *through* a symbolic link stored
/// earlier in the same archive are all refused. `/usr/bin/unzip` then unpacks
/// into the destination, and a final walk refuses any symbolic link whose
/// target resolves outside it. The caller should extract into an empty
/// staging directory and discard it on failure.
public struct SafeZipExtractor: Sendable {
    public let unzipURL: URL

    public init(unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip")) {
        self.unzipURL = unzipURL
    }

    // MARK: - Public API

    /// Validates `archiveURL` and extracts it into `destination` (created if needed).
    public func extract(_ archiveURL: URL, to destination: URL) async throws {
        let entries = try Self.readCentralDirectory(of: archiveURL)
        try Self.validate(entries: entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await runUnzip(archiveURL: archiveURL, destination: destination)
        try Self.verifySymbolicLinksStayInside(destination)
    }

    /// Checks entry names and symlink layering without touching the disk.
    public static func validate(entries: [ZipCentralDirectoryEntry]) throws {
        var normalizedPaths = Set<String>()
        var symlinkPaths = Set<String>()
        var normalized: [(String, ZipCentralDirectoryEntry)] = []

        for entry in entries {
            let name = entry.path
            guard !name.isEmpty else { throw DemoProjectError.unsafeArchive("an entry has an empty name") }
            guard !name.contains("\0") else { throw DemoProjectError.unsafeArchive("the entry “\(name)” contains a NUL character") }
            guard !name.contains("\\") else {
                throw DemoProjectError.unsafeArchive("the entry “\(name)” uses a backslash path separator")
            }
            guard !name.hasPrefix("/") && !name.hasPrefix("~") else {
                throw DemoProjectError.unsafeArchive("the entry “\(name)” is an absolute path")
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let first = components.first, first.count == 2, first.hasSuffix(":") {
                throw DemoProjectError.unsafeArchive("the entry “\(name)” names a drive letter")
            }
            guard !components.contains("..") else {
                throw DemoProjectError.unsafeArchive("the entry “\(name)” climbs out of the destination with “..”")
            }
            let clean = components.filter { $0 != "." }.joined(separator: "/")
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            if !entry.isDirectory {
                guard normalizedPaths.insert(key).inserted else {
                    throw DemoProjectError.unsafeArchive("the entry “\(name)” appears more than once")
                }
            }
            if entry.isSymbolicLink { symlinkPaths.insert(key) }
            normalized.append((clean, entry))
        }

        guard !symlinkPaths.isEmpty else { return }
        for (clean, _) in normalized {
            let parts = clean.lowercased().split(separator: "/")
            guard parts.count > 1 else { continue }
            for depth in 1..<parts.count {
                let ancestor = parts[0..<depth].joined(separator: "/")
                if symlinkPaths.contains(ancestor) {
                    throw DemoProjectError.unsafeArchive(
                        "the entry “\(clean)” would be written through the symbolic link “\(ancestor)”"
                    )
                }
            }
        }
    }

    /// Refuses any symbolic link under `root` whose target is absolute or resolves outside `root`.
    public static func verifySymbolicLinksStayInside(_ root: URL) throws {
        let fileManager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let relative = url.path.dropFirst(root.path.count).drop { $0 == "/" }
            if target.hasPrefix("/") || target.hasPrefix("~") {
                throw DemoProjectError.unsafeArchive("the symbolic link “\(relative)” points to the absolute path \(target)")
            }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let resolved = parent.appendingPathComponent(target).standardizedFileURL.path
            guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/") else {
                throw DemoProjectError.unsafeArchive("the symbolic link “\(relative)” points outside the project (\(target))")
            }
        }
    }

    // MARK: - Central directory

    /// Reads entry names and Unix modes from the archive's central directory.
    public static func readCentralDirectory(of archiveURL: URL) throws -> [ZipCentralDirectoryEntry] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archiveURL)
        } catch {
            throw DemoProjectError.extractionFailed("the archive could not be opened (\(error.localizedDescription))")
        }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw DemoProjectError.extractionFailed("the file is too small to be a ZIP archive") }

        // The end-of-central-directory record sits in the last 22 + 65535 bytes.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocdIndex = lastIndex(of: 0x0605_4b50, in: tail) else {
            throw DemoProjectError.extractionFailed("the file is not a ZIP archive (no end-of-central-directory record)")
        }
        let eocdOffset = fileSize - tailLength + UInt64(eocdIndex)
        var entryCount = UInt64(tail.le16(at: eocdIndex + 10))
        var directorySize = UInt64(tail.le32(at: eocdIndex + 12))
        var directoryOffset = UInt64(tail.le32(at: eocdIndex + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the locator is the 20 bytes just before the classic record.
            guard eocdOffset >= 20 else { throw DemoProjectError.extractionFailed("the ZIP64 directory locator is missing") }
            try handle.seek(toOffset: eocdOffset - 20)
            let locator = try handle.read(upToCount: 20) ?? Data()
            guard locator.count == 20, locator.le32(at: 0) == 0x0706_4b50 else {
                throw DemoProjectError.extractionFailed("the ZIP64 directory locator is missing")
            }
            let zip64Offset = locator.le64(at: 8)
            try handle.seek(toOffset: zip64Offset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.le32(at: 0) == 0x0606_4b50 else {
                throw DemoProjectError.extractionFailed("the ZIP64 end-of-central-directory record is damaged")
            }
            entryCount = record.le64(at: 32)
            directorySize = record.le64(at: 40)
            directoryOffset = record.le64(at: 48)
        }

        guard directoryOffset + directorySize <= fileSize, directorySize < 512 * 1024 * 1024 else {
            throw DemoProjectError.extractionFailed("the central directory lies outside the file")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else {
            throw DemoProjectError.extractionFailed("the central directory is truncated")
        }

        var entries: [ZipCentralDirectoryEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var cursor = 0
        while cursor + 46 <= directory.count, directory.le32(at: cursor) == 0x0201_4b50 {
            let versionMadeBy = directory.le16(at: cursor + 4)
            let flags = directory.le16(at: cursor + 8)
            let nameLength = Int(directory.le16(at: cursor + 28))
            let extraLength = Int(directory.le16(at: cursor + 30))
            let commentLength = Int(directory.le16(at: cursor + 32))
            let externalAttributes = directory.le32(at: cursor + 38)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= directory.count else {
                throw DemoProjectError.extractionFailed("a central directory entry is truncated")
            }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let isUTF8 = flags & 0x0800 != 0
            let name = (isUTF8 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            let hostSystem = versionMadeBy >> 8
            let mode: UInt16? = hostSystem == 3 ? UInt16(externalAttributes >> 16) : nil
            entries.append(ZipCentralDirectoryEntry(path: name, unixMode: mode))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard UInt64(entries.count) == entryCount else {
            throw DemoProjectError.extractionFailed(
                "the central directory lists \(entryCount) entries but \(entries.count) could be read"
            )
        }
        return entries
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.le32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Extraction

    private func runUnzip(archiveURL: URL, destination: URL) async throws {
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lge-unzip-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = unzipURL
        process.arguments = ["-qq", "-o", archiveURL.path, "-d", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: DemoProjectError.extractionFailed(
                        "unzip could not be started (\(error.localizedDescription))"
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        if Task.isCancelled { throw DemoProjectError.cancelled }
        guard status == 0 else {
            let message = (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DemoProjectError.extractionFailed(
                "unzip exited with status \(status)\(message.isEmpty ? "" : ": \(message.prefix(500))")"
            )
        }
    }
}

// MARK: - Little-endian readers

private extension Data {
    func le16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func le32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func le64(at offset: Int) -> UInt64 {
        UInt64(le32(at: offset)) | UInt64(le32(at: offset + 4)) << 32
    }
}
