import Darwin
import Foundation

/// An immutable, app-owned workbook view created from the exact descriptor
/// that passed validation. The canonical bundle path can change afterwards
/// without changing what is handed to the external workbook application.
final class GenotypeCurrentWorkbookOpenHandoff: @unchecked Sendable {
    static let directoryPrefix = "lungfish-current-workbook-view."
    static let ownershipMarkerName =
        ".lungfish-owned-current-workbook-view-v1"

    let canonicalURL: URL
    private let directoryURL: URL
    private let viewURL: URL
    private var releasedForOpening = false

    private init(
        canonicalURL: URL,
        directoryURL: URL,
        viewURL: URL
    ) {
        self.canonicalURL = canonicalURL
        self.directoryURL = directoryURL
        self.viewURL = viewURL
    }

    deinit {
        guard !releasedForOpening else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    nonisolated static func make(
        opening canonicalURL: URL,
        relativeTo bundleURL: URL
    ) throws -> GenotypeCurrentWorkbookOpenHandoff {
        let standardizedURL = canonicalURL.standardizedFileURL
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let bundleComponents = standardizedBundleURL.pathComponents
        let workbookComponents = standardizedURL.pathComponents
        guard workbookComponents.count > bundleComponents.count,
              Array(workbookComponents.prefix(bundleComponents.count))
                == bundleComponents else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInvalidFileNameError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The current workbook is not inside its genotype bundle.",
                ]
            )
        }
        let relativeComponents = Array(
            workbookComponents.dropFirst(bundleComponents.count)
        )
        guard relativeComponents.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
        }) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInvalidFileNameError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The current workbook has an invalid bundle-relative path.",
                ]
            )
        }

        let rootDescriptor = Darwin.open(
            standardizedBundleURL.path,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw posixError(
                operation: "Open current-workbook bundle for viewing",
                path: standardizedBundleURL.path
            )
        }
        defer { Darwin.close(rootDescriptor) }

        var parentDescriptor = rootDescriptor
        var ownedDirectoryDescriptors: [Int32] = []
        defer {
            for descriptor in ownedDirectoryDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }
        var displayURL = standardizedBundleURL
        for component in relativeComponents.dropLast() {
            displayURL.appendPathComponent(component, isDirectory: true)
            let descriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw posixError(
                    operation:
                        "Open current-workbook bundle directory for viewing",
                    path: displayURL.path
                )
            }
            ownedDirectoryDescriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        guard let filename = relativeComponents.last else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInvalidFileNameError
            )
        }
        let descriptor = filename.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open validated current workbook for viewing",
                path: standardizedURL.path
            )
        }
        defer { Darwin.close(descriptor) }
        return try make(
            borrowing: descriptor,
            canonicalURL: standardizedURL
        )
    }

    nonisolated static func make(
        borrowing sourceDescriptor: Int32,
        canonicalURL: URL
    ) throws -> GenotypeCurrentWorkbookOpenHandoff {
        var before = stat()
        guard Darwin.fstat(sourceDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw posixError(
                operation: "Validate current workbook for viewing",
                path: canonicalURL.path
            )
        }

        let directoryURL = try makeExclusiveViewDirectory()
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw posixError(
                operation: "Open exclusive current-workbook view directory",
                path: directoryURL.path
            )
        }
        defer { Darwin.close(directoryDescriptor) }
        try writeOwnershipMarker(
            directoryDescriptor: directoryDescriptor,
            directoryURL: directoryURL
        )

        let filename = "current.xlsx"
        let outputDescriptor = filename.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard outputDescriptor >= 0 else {
            throw posixError(
                operation: "Create immutable current-workbook view",
                path: directoryURL.appendingPathComponent(filename).path
            )
        }
        defer { Darwin.close(outputDescriptor) }

        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while offset < before.st_size {
            let remaining = Int(min(
                Int64(buffer.count),
                before.st_size - offset
            ))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(
                    sourceDescriptor,
                    $0.baseAddress,
                    remaining,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw posixError(
                    operation: "Read validated current workbook for viewing",
                    path: canonicalURL.path
                )
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        outputDescriptor,
                        $0.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw posixError(
                        operation: "Write immutable current-workbook view",
                        path: directoryURL.appendingPathComponent(filename).path
                    )
                }
                written += result
            }
            offset += Int64(count)
        }

        var after = stat()
        guard Darwin.fstat(sourceDescriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              offset == after.st_size else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The validated current workbook changed while its immutable view was prepared.",
                ]
            )
        }
        guard Darwin.fsync(outputDescriptor) == 0,
              Darwin.fchmod(outputDescriptor, S_IRUSR) == 0,
              Darwin.fsync(outputDescriptor) == 0,
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError(
                operation: "Sync immutable current-workbook view",
                path: directoryURL.path
            )
        }

        completed = true
        return GenotypeCurrentWorkbookOpenHandoff(
            canonicalURL: canonicalURL.standardizedFileURL,
            directoryURL: directoryURL,
            viewURL: directoryURL.appendingPathComponent(filename)
        )
    }

    @MainActor
    func releaseURLForOpening() -> URL {
        releasedForOpening = true
        return viewURL.standardizedFileURL
    }

    private nonisolated static func makeExclusiveViewDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let templatePath = root
            .appendingPathComponent(
                "\(directoryPrefix)XXXXXX",
                isDirectory: true
            )
            .path
        var template = Array(templatePath.utf8CString)
        let createdPath: String? = template.withUnsafeMutableBufferPointer {
            buffer in
            guard let baseAddress = buffer.baseAddress,
                  Darwin.mkdtemp(baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
        guard let createdPath else {
            throw posixError(
                operation: "Create exclusive current-workbook view directory",
                path: templatePath
            )
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
            .standardizedFileURL
    }

    private nonisolated static func writeOwnershipMarker(
        directoryDescriptor: Int32,
        directoryURL: URL
    ) throws {
        let descriptor = ownershipMarkerName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Create current-workbook view ownership marker",
                path: directoryURL
                    .appendingPathComponent(ownershipMarkerName)
                    .path
            )
        }
        defer { Darwin.close(descriptor) }
        let marker = Data("Lungfish current workbook view v1\n".utf8)
        try marker.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw posixError(
                        operation:
                            "Write current-workbook view ownership marker",
                        path: directoryURL
                            .appendingPathComponent(ownershipMarkerName)
                            .path
                    )
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, S_IRUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw posixError(
                operation: "Sync current-workbook view ownership marker",
                path: directoryURL
                    .appendingPathComponent(ownershipMarkerName)
                    .path
            )
        }
    }

    private nonisolated static func posixError(
        operation: String,
        path: String
    ) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(code)))",
            ]
        )
    }
}

@MainActor
enum GenotypeCurrentWorkbookOpenHandoffRegistry {
    static let staleViewAge: TimeInterval = 24 * 60 * 60
    private static var entries:
        [String: GenotypeCurrentWorkbookOpenHandoff] = [:]
    private static var performedLaunchCleanup = false

    static func cleanupStaleViewsIfNeeded(now: Date = Date()) {
        guard !performedLaunchCleanup else { return }
        performedLaunchCleanup = true
        let root = FileManager.default.temporaryDirectory
        let cutoff = now.addingTimeInterval(-staleViewAge)
        Task.detached(priority: .utility) {
            _ = cleanupStaleViews(in: root, olderThan: cutoff)
        }
    }

    /// Removes only direct, owned, nonsymlink view directories older than the
    /// cutoff. Fresh views remain available to workbook applications; stale
    /// read-only views are retired on the next app/coordinator launch.
    @discardableResult
    nonisolated static func cleanupStaleViews(
        in rootURL: URL,
        olderThan cutoff: Date
    ) -> [URL] {
        let root = rootURL.standardizedFileURL
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        var removed: [URL] = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            let name = standardized.lastPathComponent
            guard standardized.deletingLastPathComponent() == root,
                  name.hasPrefix(
                    GenotypeCurrentWorkbookOpenHandoff.directoryPrefix
                  ),
                  name.count
                    == GenotypeCurrentWorkbookOpenHandoff.directoryPrefix.count
                        + 6 else {
                continue
            }
            var information = stat()
            guard Darwin.lstat(standardized.path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR,
                  information.st_uid == Darwin.getuid() else {
                continue
            }
            let marker = standardized.appendingPathComponent(
                GenotypeCurrentWorkbookOpenHandoff.ownershipMarkerName
            )
            var markerInformation = stat()
            guard Darwin.lstat(marker.path, &markerInformation) == 0,
                  markerInformation.st_mode & S_IFMT == S_IFREG,
                  markerInformation.st_uid == Darwin.getuid() else {
                continue
            }
            let modifiedAt = Date(
                timeIntervalSince1970:
                    TimeInterval(information.st_mtimespec.tv_sec)
            )
            guard modifiedAt < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: standardized)
                removed.append(standardized)
            } catch {
                continue
            }
        }
        return removed
    }

    static func register(_ handoff: GenotypeCurrentWorkbookOpenHandoff) {
        entries[handoff.canonicalURL.standardizedFileURL.path] = handoff
    }

    static func claim(
        for canonicalURL: URL
    ) -> GenotypeCurrentWorkbookOpenHandoff? {
        entries.removeValue(
            forKey: canonicalURL.standardizedFileURL.path
        )
    }
}
