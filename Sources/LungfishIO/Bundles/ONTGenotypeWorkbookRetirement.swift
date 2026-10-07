import CryptoKit
import Darwin
import Foundation
import LungfishCore

// Retirement is performed under the bundle publication lock; that lock is the
// cooperative boundary for bundle-parent entries. Detached attestations also
// live beneath an owner-only 0700 authority root. Cooperating Lungfish
// processes must not mutate retirement tombstones.
// macOS has no unlink-by-witness primitive: unlinkat(2) is name-based and
// cannot condition deletion on a previously witnessed inode. A same-user
// process that ignores the applicable cooperative boundary can therefore race
// even the final witness/unlinkat pair. We narrow
// that unavoidable kernel gap with a second randomized exclusive rename,
// preserve anything substituted at the injectable boundary, re-witness the
// final name, and expose no callback between that final witness and unlink.
enum ONTGenotypeWorkbookRetirement {
    static func fileWitness(
        at url: URL
    ) throws -> (Data, ONTGenotypeWorkbookRetirementFileWitness, stat) {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                url.path,
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(url.path)
        }
        var data = Data()
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                    url.path,
                    errno
                )
            }
            data.append(buffer, count: count)
            digest.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery file changed while it was read."
            )
        }
        return (
            data,
            ONTGenotypeWorkbookRetirementFileWitness(
                device: after.st_dev,
                inode: after.st_ino,
                size: after.st_size,
                sha256: digest.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
            ),
            after
        )
    }

    static func retireRegularFile(
        at url: URL,
        expected: ONTGenotypeWorkbookRetirementFileWitness,
        checkpoint: String,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                parent.path,
                errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        var info = stat()
        let inspect = url.lastPathComponent.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == expected.device,
              info.st_ino == expected.inode,
              info.st_size == expected.size else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed before retirement."
            )
        }
        try failureInjector?("\(checkpoint):\(url.path)")
        let tombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let detached = url.lastPathComponent.withCString { sourceName in
            tombstone.withCString { destinationName in
                PortableRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A workbook recovery authority file changed before it could be detached."
            )
        }
        let tombstoneURL = parent.appendingPathComponent(tombstone)
        let detachedWitness = try? fileWitness(at: tombstoneURL).1
        guard detachedWitness == expected else {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: url.lastPathComponent,
                displayedAt: tombstoneURL
            )
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted workbook recovery file was detached and preserved."
            )
        }
        do {
            try failureInjector?(
                "after-workbook-retirement-witness:\(url.path)"
            )
        } catch {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: url.lastPathComponent,
                displayedAt: tombstoneURL
            )
            throw error
        }

        let finalTombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let redetached = tombstone.withCString { sourceName in
            finalTombstone.withCString { destinationName in
                PortableRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard redetached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A workbook recovery authority file changed after its retirement witness; the entry was preserved."
                )
        }
        let finalTombstoneURL = parent.appendingPathComponent(finalTombstone)
        let finalWitness = try? fileWitness(at: finalTombstoneURL).1
        guard finalWitness == expected else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A substituted workbook recovery file was preserved at \(finalTombstoneURL.path)."
                )
        }
        let removed = finalTombstone.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard removed == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                finalTombstoneURL.path,
                errno
            )
        }
    }

    static func retireDirectory(
        named name: String,
        beneath parentDescriptor: Int32,
        parentURL: URL,
        expected: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        checkpoint: String,
        failureInjector: (@Sendable (String) throws -> Void)?
    ) throws {
        var info = stat()
        let inspect = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard inspect == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook cleanup quarantine changed before retirement."
            )
        }
        let displayedURL = parentURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        try failureInjector?("\(checkpoint):\(displayedURL.path)")
        let tombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let detached = name.withCString { sourceName in
            tombstone.withCString { destinationName in
                PortableRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "The workbook cleanup quarantine changed before it could be detached."
            )
        }
        var detachedInfo = stat()
        let detachedStatus = tombstone.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &detachedInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard detachedStatus == 0,
              detachedInfo.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(detachedInfo.st_dev))
                == expected.device,
              UInt64(detachedInfo.st_ino) == expected.inode else {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: name,
                displayedAt: parentURL.appendingPathComponent(tombstone)
            )
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted workbook cleanup quarantine was detached and preserved."
            )
        }
        do {
            try failureInjector?(
                "after-workbook-retirement-witness:\(displayedURL.path)"
            )
        } catch {
            try restoreDetachedEntry(
                parentDescriptor: parentDescriptor,
                tombstone: tombstone,
                original: name,
                displayedAt: parentURL.appendingPathComponent(tombstone)
            )
            throw error
        }

        let finalTombstone =
            ".lungfish-workbook-retiring-\(UUID().uuidString.lowercased())"
        let redetached = tombstone.withCString { sourceName in
            finalTombstone.withCString { destinationName in
                PortableRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard redetached == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "The workbook cleanup quarantine changed after its retirement witness; the entry was preserved."
                )
        }
        let finalTombstoneURL = parentURL.appendingPathComponent(
            finalTombstone,
            isDirectory: true
        )
        var finalInfo = stat()
        let finalStatus = finalTombstone.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &finalInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard finalStatus == 0,
              finalInfo.st_mode & S_IFMT == S_IFDIR,
              UInt64(bitPattern: Int64(finalInfo.st_dev))
                == expected.device,
              UInt64(finalInfo.st_ino) == expected.inode else {
            throw ONTGenotypeWorkbookUpdateRecoveryError
                .ambiguousTransaction(
                    "A substituted workbook cleanup quarantine was preserved at \(finalTombstoneURL.path)."
                )
        }
        let removed = finalTombstone.withCString {
            Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard removed == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(
                finalTombstoneURL.path,
                errno
            )
        }
    }

    private static func restoreDetachedEntry(
        parentDescriptor: Int32,
        tombstone: String,
        original: String,
        displayedAt: URL
    ) throws {
        let restored = tombstone.withCString { sourceName in
            original.withCString { destinationName in
                PortableRename.renameatxNP(
                    parentDescriptor,
                    sourceName,
                    parentDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard restored == 0, Darwin.fsync(parentDescriptor) == 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "A substituted retirement target was preserved at \(displayedAt.path)."
            )
        }
    }
}
