// GenotypeAnnotationRecoveryCopy.swift - A reader takes annotations.json from its recovery copy without renaming it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore

/// Reads `annotations.json`, or its recovery copy when an interrupted ExFAT swap left the name
/// empty (plan decision P9).
///
/// A swap on ExFAT rotates the old file through a `.annotations.json.lungfish-swap-<UUID>`
/// tombstone. A process that ends during the rotation leaves the name missing, or holding only
/// the empty file the rename reserved it with, while the annotations wait in the tombstone. A
/// reader then takes the newest tombstone that holds bytes, in memory. It renames nothing,
/// because a read runs no recovery, and it prints one line on standard error that names the
/// recovery copy, so an export never drops the annotations without a word. Opening the result in
/// the app, or the next write of the annotations, puts the copy back under its name.
package enum GenotypeAnnotationRecoveryCopy {
    /// Receives the warning line. Standard error unless a test binds it.
    @TaskLocal package static var noticeSink: (@Sendable (String) -> Void)?

    /// The bytes a reader sees for `annotations.json` in `bundleURL`, or `nil` when it holds none.
    static func readSidecarData(forBundleAt bundleURL: URL) throws -> Data? {
        let filename = GenotypeAnnotationSidecar.filename
        let directoryFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else {
            // The file access reports a folder it cannot open in its own words.
            return try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: filename, inBundleAt: bundleURL)
        }
        defer { Darwin.close(directoryFD) }
        let data = try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )
        if let data, !data.isEmpty { return data }
        guard let copyName = newestTombstone(of: filename, directoryFD: directoryFD),
              let copy = try GenotypeAnnotationPublicationFileAccess.readFileIfPresent(
                  named: copyName,
                  inBundleAt: bundleURL,
                  openedBundleDirectoryFD: directoryFD
              ),
              !copy.isEmpty
        else { return data }
        let path = bundleURL.appendingPathComponent(filename).path
        let line = "warning: \(path) is \(data == nil ? "missing" : "empty"), so the annotations came from "
            + "its recovery copy \(copyName). Opening the result in Lungfish Genome Explorer restores the file."
        if let noticeSink {
            noticeSink(line)
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return copy
    }

    /// The newest `.<name>.lungfish-swap-<UUID>` regular file that holds bytes, chosen as
    /// `DurableReplace` chooses the leftover it restores, by modification time and then by name.
    private static func newestTombstone(of name: String, directoryFD: Int32) -> String? {
        let prefix = ".\(name)\(PortableRename.swapTombstoneInfix)"
        let copy = Darwin.fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return nil }
        guard let stream = Darwin.fdopendir(copy) else {
            Darwin.close(copy)
            return nil
        }
        defer { Darwin.closedir(stream) }
        Darwin.rewinddir(stream)
        var chosen: (name: String, modified: timespec)?
        while let entry = Darwin.readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let entryName = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            guard entryName.hasPrefix(prefix),
                  UUID(uuidString: String(entryName.dropFirst(prefix.count))) != nil else { continue }
            var information = stat()
            guard entryName.withCString({ Darwin.fstatat(directoryFD, $0, &information, AT_SYMLINK_NOFOLLOW) }) == 0,
                  information.st_mode & S_IFMT == S_IFREG,
                  information.st_size > 0 else { continue }
            let modified = information.st_mtimespec
            if let current = chosen {
                let newer = modified.tv_sec != current.modified.tv_sec
                    ? modified.tv_sec > current.modified.tv_sec
                    : modified.tv_nsec != current.modified.tv_nsec
                        ? modified.tv_nsec > current.modified.tv_nsec
                        : entryName > current.name
                guard newer else { continue }
            }
            chosen = (entryName, modified)
        }
        return chosen?.name
    }
}
