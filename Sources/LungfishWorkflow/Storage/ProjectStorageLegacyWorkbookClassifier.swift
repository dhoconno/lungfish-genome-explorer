import Darwin
import CryptoKit
import Foundation
import LungfishIO

public struct ProjectStorageLegacyWorkbookClassifier {
    private static let archivePrefix =
        ".lungfish-workbook-generation-archive-"
    private static let maximumManifestBytes: Int64 = 16 * 1_024 * 1_024

    private let attestationRootURL: URL?
    private let cancellationCheck: () throws -> Void
    private let callerHeldPublicationLocks:
        [ONTGenotypeBundlePublicationLock]

    public init() {
        self.attestationRootURL = nil
        self.cancellationCheck = { try Task.checkCancellation() }
        self.callerHeldPublicationLocks = []
    }

    init(
        attestationRootURL: URL? = nil,
        cancellationCheck: @escaping () throws -> Void = {
            try Task.checkCancellation()
        },
        callerHeldPublicationLocks:
            [ONTGenotypeBundlePublicationLock] = []
    ) {
        self.attestationRootURL = attestationRootURL
        self.cancellationCheck = cancellationCheck
        self.callerHeldPublicationLocks = callerHeldPublicationLocks
    }

    public func classify(
        archiveURL: URL,
        projectURL: URL
    ) throws -> ProjectStorageClassification {
        do {
            try cancellationCheck()
            let archive = archiveURL.standardizedFileURL
            let project = projectURL.standardizedFileURL
            guard archive.path.hasPrefix(project.path + "/") else {
                return blocked("The workbook archive is outside the project.")
            }
            guard let transactionID = Self.transactionID(
                from: archive.lastPathComponent
            ) else {
                return .notRemovable(
                    .unknownOwnedPattern,
                    reason:
                        "The workbook archive name is not an exact "
                        + "Lungfish-owned pattern."
                )
            }
            var archiveInformation = stat()
            guard Darwin.lstat(
                archive.path,
                &archiveInformation
            ) == 0,
                archiveInformation.st_mode & S_IFMT == S_IFDIR else {
                return blocked(
                    "The workbook archive is not a real directory."
                )
            }

            var nestedBundle: URL?
            var nestedBundleCount = 0
            try forEachDirectChild(in: archive) { candidate in
                var information = stat()
                if candidate.pathExtension.lowercased()
                        == ONTGenotypeResultBundle.directoryExtension
                    && Darwin.lstat(
                        candidate.path,
                        &information
                    ) == 0
                    && information.st_mode & S_IFMT == S_IFDIR {
                    nestedBundleCount += 1
                    if nestedBundleCount == 1 {
                        nestedBundle = candidate
                    }
                }
            }
            guard nestedBundleCount == 1,
                  let archivedBundle = nestedBundle else {
                return blocked(
                    "The archive must contain exactly one real genotype "
                        + "bundle; found \(nestedBundleCount)."
                )
            }
            let archivedManifest = try loadBoundedManifest(
                from: archivedBundle
            )
            guard let archivedCurrentPath =
                    archivedManifest.currentWorkbookPath,
                  Self.isSafeRelativePath(archivedCurrentPath),
                  let archivedRevisions =
                    archivedManifest.workbookRevisions,
                  let archivedRevision = archivedRevisions.last(
                    where: { $0.path == archivedCurrentPath }
                  ),
                  archivedRevision.sizeBytes >= 0,
                  Self.isDigest(archivedRevision.sha256) else {
                return blocked(
                    "The archived current workbook has no valid latest "
                        + "manifest descriptor."
                )
            }
            let archivedWorkbook = archivedBundle.appendingPathComponent(
                archivedCurrentPath
            )
            guard try regularFileMatchesDescriptorNoFollow(
                archivedWorkbook,
                sizeBytes: archivedRevision.sizeBytes,
                sha256: archivedRevision.sha256
            ) else {
                return blocked(
                    "The archived current workbook content does not match "
                        + "its descriptor."
                )
            }

            try cancellationCheck()
            var matchCount = 0
            var matchedLiveBundle: URL?
            try forEachDirectChild(
                in: archive.deletingLastPathComponent()
            ) { liveBundle in
                guard liveBundle.standardizedFileURL != archive,
                      liveBundle.pathExtension.lowercased()
                        == ONTGenotypeResultBundle.directoryExtension else {
                    return
                }
                var information = stat()
                guard Darwin.lstat(
                    liveBundle.path,
                    &information
                ) == 0,
                    information.st_mode & S_IFMT == S_IFDIR,
                    let manifest = try? loadBoundedManifest(
                        from: liveBundle
                    ) else {
                    return
                }
                for revision in manifest.workbookRevisions ?? []
                where revision.sizeBytes == archivedRevision.sizeBytes
                    && revision.sha256.caseInsensitiveCompare(
                        archivedRevision.sha256
                    ) == .orderedSame
                    && Self.isSafeRelativePath(revision.path) {
                    let revisionURL = liveBundle.appendingPathComponent(
                        revision.path
                    )
                    if (try? regularFileMatchesDescriptorNoFollow(
                        revisionURL,
                        sizeBytes: revision.sizeBytes,
                        sha256: revision.sha256
                    )) == true {
                        matchCount += 1
                        if matchCount == 1 {
                            matchedLiveBundle = liveBundle
                        }
                    }
                }
            }
            guard matchCount == 1,
                  let liveBundle = matchedLiveBundle else {
                return blocked(
                    "The archive maps to \(matchCount) retained live "
                        + "workbook revisions; exactly one is required."
                )
            }
            let authority: ONTGenotypeWorkbookLegacyAuthorityInspection
            if let heldLock = callerHeldPublicationLocks.first(where: {
                $0.bundleURL == liveBundle.standardizedFileURL
            }) {
                authority = heldLock.inspectLegacyArchiveAuthority(
                    transactionID: transactionID,
                    attestationRootURL: attestationRootURL
                )
            } else {
                authority =
                    ONTGenotypeWorkbookUpdateRecovery
                    .inspectLegacyArchiveAuthority(
                        transactionID: transactionID,
                        liveBundleURL: liveBundle,
                        attestationRootURL: attestationRootURL
                    )
            }
            try cancellationCheck()
            let receiptFacts: [
                ONTGenotypeWorkbookLegacyReceiptFact
            ]
            switch authority {
            case .blocked(let reason):
                return .notRemovable(
                    .liveWorkbookAuthority,
                    reason: reason
                )
            case .clear(let receipts):
                receiptFacts = receipts
            }
            for receipt in receiptFacts {
                let archivedDescriptorMatchesTransaction =
                    Self.matches(
                        archivedRevision,
                        receipt.oldCurrentWorkbook
                    ) || Self.matches(
                        archivedRevision,
                        receipt.newCurrentWorkbook
                    )
                guard archivedDescriptorMatchesTransaction else {
                    return blocked(
                        "A workbook recovery receipt does not describe "
                            + "the archived workbook revision."
                    )
                }
            }
            return .removable(
                .retainedWorkbookRevision,
                reason:
                    "The retired workbook is retained exactly once in "
                    + "the live genotype bundle."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .notRemovable(
                .inspectionFailed,
                reason:
                    "Workbook archive inspection failed closed: "
                    + error.localizedDescription
            )
        }
    }

    private func loadBoundedManifest(
        from bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        try cancellationCheck()
        let url = ONTGenotypeResultBundle.manifestURL(in: bundleURL)
        let size = try regularFileSizeNoFollow(url)
        guard size <= Self.maximumManifestBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: readBoundedRegularFileNoFollow(
                url,
                maximumBytes: Self.maximumManifestBytes
            )
        )
    }

    private func forEachDirectChild(
        in directory: URL,
        _ body: (URL) throws -> Void
    ) throws {
        var enumerationFailure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = enumerator.nextObject() as? URL {
            try cancellationCheck()
            try body(url)
        }
        if let enumerationFailure {
            throw enumerationFailure
        }
    }

    private func readBoundedRegularFileNoFollow(
        _ url: URL,
        maximumBytes: Int64
    ) throws -> Data {
        let parentDescriptor = try NoFollowFileSystem
            .openDirectoryHierarchy(
                url.standardizedFileURL.deletingLastPathComponent()
            )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellationCheck()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard Int64(data.count) <= maximumBytes - Int64(count) else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              data.count == Int(after.st_size) else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private func regularFileSizeNoFollow(_ url: URL) throws -> Int64 {
        let parentDescriptor = try NoFollowFileSystem
            .openDirectoryHierarchy(
                url.standardizedFileURL.deletingLastPathComponent()
            )
        defer { Darwin.close(parentDescriptor) }
        var information = stat()
        let status = url.lastPathComponent.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0 else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return information.st_size
    }

    private func regularFileMatchesDescriptorNoFollow(
        _ url: URL,
        sizeBytes: Int64,
        sha256: String
    ) throws -> Bool {
        guard sizeBytes >= 0, Self.isDigest(sha256) else {
            return false
        }
        let parentDescriptor = try NoFollowFileSystem
            .openDirectoryHierarchy(
                url.standardizedFileURL.deletingLastPathComponent()
            )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size == sizeBytes else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellationCheck()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let (next, overflow) = total.addingReportingOverflow(
                Int64(count)
            )
            guard !overflow, next <= sizeBytes else {
                return false
            }
            total = next
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              total == sizeBytes else {
            return false
        }
        let actual = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return actual.caseInsensitiveCompare(sha256) == .orderedSame
    }

    private static func transactionID(
        from archiveName: String
    ) -> String? {
        guard archiveName.hasPrefix(archivePrefix) else { return nil }
        let identifier = String(archiveName.dropFirst(archivePrefix.count))
        let pattern =
            #"^\d{4}-\d{2}-\d{2}T\d{6}(?:-\d+)?Z-update-current-workbook-[0-9A-Fa-f]{8}$"#
        guard identifier.range(
            of: pattern,
            options: .regularExpression
        ) != nil,
            isCalendarValidTimestamp(identifier) else {
            return nil
        }
        return identifier
    }

    private static func isCalendarValidTimestamp(
        _ identifier: String
    ) -> Bool {
        guard identifier.count >= 18 else { return false }
        let base = String(identifier.prefix(17)) + "Z"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: base) else {
            return false
        }
        return formatter.string(from: date) == base
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        let components = NSString(string: path).pathComponents
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !path.utf8.contains(0)
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-fA-F]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func matches(
        _ revision: ONTGenotypeWorkbookRevision,
        _ descriptor: ONTGenotypeWorkbookUpdateFileDescriptor
    ) -> Bool {
        revision.sizeBytes == descriptor.sizeBytes
            && revision.sha256.caseInsensitiveCompare(
                descriptor.sha256
            ) == .orderedSame
    }

    private func blocked(
        _ reason: String
    ) -> ProjectStorageClassification {
        .notRemovable(
            .ambiguousWorkbookArchive,
            reason: reason
        )
    }
}
