import Darwin
import Foundation

/// Narrow compatibility access for genotype annotation artifacts published by
/// Lungfish's earlier generation-based annotation store.
///
/// Arbitrary symbolic links remain unsupported. A linked file is trusted only
/// when both links exactly match the internal publication layout:
///
///     <bundle>/<filename>
///       -> artifacts/genotype-annotations/active/<filename>
///     artifacts/genotype-annotations/active
///       -> generations/<UUID>
///
/// Every directory and the final file are opened without following links.
public enum GenotypeAnnotationPublicationEntryKind: Sendable {
    case absent
    case regularFile
    case trustedGenerationLink
}

public enum GenotypeAnnotationPublicationFileAccess {
    public static func readFileIfPresent(
        named filename: String,
        inBundleAt bundleURL: URL
    ) throws -> Data? {
        let directoryFD = try openBundleDirectory(bundleURL)
        defer { Darwin.close(directoryFD) }
        return try readFileIfPresent(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )
    }

    /// The descriptor remains owned by the caller. It must identify the same
    /// no-follow bundle directory represented by `bundleURL`.
    public static func readFileIfPresent(
        named filename: String,
        inBundleAt bundleURL: URL,
        openedBundleDirectoryFD directoryFD: Int32
    ) throws -> Data? {
        var status = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw systemError(
                operation: "inspect genotype annotation publication entry",
                path: bundleURL.appendingPathComponent(filename).path
            )
        }

        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            let descriptor = try openRegularFile(
                named: filename,
                at: directoryFD,
                path: bundleURL.appendingPathComponent(filename).path
            )
            defer { Darwin.close(descriptor) }
            return try readAll(
                from: descriptor,
                status: status,
                path: bundleURL.appendingPathComponent(filename).path
            )
        case mode_t(S_IFLNK):
            return try readTrustedGenerationLinkedFile(
                named: filename,
                bundleURL: bundleURL,
                bundleDirectoryFD: directoryFD
            )
        default:
            throw unsafeEntryError(
                bundleURL.appendingPathComponent(filename).path
            )
        }
    }

    public static func entryKind(
        named filename: String,
        inBundleAt bundleURL: URL
    ) throws -> GenotypeAnnotationPublicationEntryKind {
        let directoryFD = try openBundleDirectory(bundleURL)
        defer { Darwin.close(directoryFD) }
        return try entryKind(
            named: filename,
            inBundleAt: bundleURL,
            openedBundleDirectoryFD: directoryFD
        )
    }

    /// The descriptor remains owned by the caller. It must identify the same
    /// no-follow bundle directory represented by `bundleURL`.
    public static func entryKind(
        named filename: String,
        inBundleAt bundleURL: URL,
        openedBundleDirectoryFD directoryFD: Int32
    ) throws -> GenotypeAnnotationPublicationEntryKind {
        var status = stat()
        let result = filename.withCString {
            Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return .absent }
            throw systemError(
                operation: "inspect genotype annotation publication entry",
                path: bundleURL.appendingPathComponent(filename).path
            )
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            return .regularFile
        case mode_t(S_IFLNK):
            _ = try readTrustedGenerationLinkedFile(
                named: filename,
                bundleURL: bundleURL,
                bundleDirectoryFD: directoryFD
            )
            return .trustedGenerationLink
        default:
            throw unsafeEntryError(
                bundleURL.appendingPathComponent(filename).path
            )
        }
    }

    private static func readTrustedGenerationLinkedFile(
        named filename: String,
        bundleURL: URL,
        bundleDirectoryFD: Int32
    ) throws -> Data {
        try validateFilename(filename)
        let rootTarget = try readLink(
            named: filename,
            at: bundleDirectoryFD,
            path: bundleURL.appendingPathComponent(filename).path
        )
        let expectedRootTarget =
            "artifacts/genotype-annotations/active/\(filename)"
        guard rootTarget == expectedRootTarget else {
            throw unsafeEntryError(
                bundleURL.appendingPathComponent(filename).path
            )
        }

        let artifactsFD = try openDirectory(
            named: "artifacts",
            at: bundleDirectoryFD,
            path: bundleURL.appendingPathComponent("artifacts").path
        )
        defer { Darwin.close(artifactsFD) }
        let annotationRootFD = try openDirectory(
            named: "genotype-annotations",
            at: artifactsFD,
            path: bundleURL
                .appendingPathComponent("artifacts")
                .appendingPathComponent("genotype-annotations").path
        )
        defer { Darwin.close(annotationRootFD) }

        let activePath = bundleURL
            .appendingPathComponent("artifacts")
            .appendingPathComponent("genotype-annotations")
            .appendingPathComponent("active").path
        let activeTarget = try readLink(
            named: "active",
            at: annotationRootFD,
            path: activePath
        )
        let activeComponents = activeTarget.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard activeComponents.count == 2,
              activeComponents[0] == "generations",
              let generationID = UUID(uuidString: String(activeComponents[1]))
        else {
            throw unsafeEntryError(activePath)
        }

        let generationsFD = try openDirectory(
            named: "generations",
            at: annotationRootFD,
            path: bundleURL
                .appendingPathComponent("artifacts")
                .appendingPathComponent("genotype-annotations")
                .appendingPathComponent("generations").path
        )
        defer { Darwin.close(generationsFD) }
        let generationName = generationID.uuidString.lowercased()
        guard generationName == String(activeComponents[1]).lowercased() else {
            throw unsafeEntryError(activePath)
        }
        let generationPath = bundleURL
            .appendingPathComponent("artifacts")
            .appendingPathComponent("genotype-annotations")
            .appendingPathComponent("generations")
            .appendingPathComponent(generationName).path
        let generationFD = try openDirectory(
            named: String(activeComponents[1]),
            at: generationsFD,
            path: generationPath
        )
        defer { Darwin.close(generationFD) }

        let filePath = URL(fileURLWithPath: generationPath)
            .appendingPathComponent(filename).path
        let descriptor = try openRegularFile(
            named: filename,
            at: generationFD,
            path: filePath
        )
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw systemError(operation: "inspect linked annotation file", path: filePath)
        }
        return try readAll(from: descriptor, status: status, path: filePath)
    }

    private static func openBundleDirectory(_ bundleURL: URL) throws -> Int32 {
        let descriptor = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw systemError(
                operation: "open genotype result bundle without following links",
                path: bundleURL.path
            )
        }
        return descriptor
    }

    private static func openDirectory(
        named name: String,
        at directoryFD: Int32,
        path: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryFD,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw systemError(
                operation: "open internal annotation directory without following links",
                path: path
            )
        }
        return descriptor
    }

    private static func openRegularFile(
        named name: String,
        at directoryFD: Int32,
        path: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw systemError(
                operation: "open genotype annotation file without following links",
                path: path
            )
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            Darwin.close(descriptor)
            throw unsafeEntryError(path)
        }
        return descriptor
    }

    private static func readLink(
        named name: String,
        at directoryFD: Int32,
        path: String
    ) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = name.withCString { namePointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                Darwin.readlinkat(
                    directoryFD,
                    namePointer,
                    bufferPointer.baseAddress,
                    bufferPointer.count - 1
                )
            }
        }
        guard count >= 0 else {
            throw systemError(operation: "read internal annotation link", path: path)
        }
        guard count < buffer.count - 1,
              let target = String(
                  bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) },
                  encoding: .utf8
              )
        else {
            throw unsafeEntryError(path)
        }
        return target
    }

    private static func readAll(
        from descriptor: Int32,
        status: stat,
        path: String
    ) throws -> Data {
        var data = Data()
        if status.st_size > 0, status.st_size <= Int.max {
            data.reserveCapacity(Int(status.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError(operation: "read genotype annotation file", path: path)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/")
        else {
            throw unsafeEntryError(filename)
        }
    }

    private static func unsafeEntryError(_ path: String) -> Error {
        NSError(
            domain: "GenotypeAnnotationPublicationFileAccess",
            code: Int(ELOOP),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Genotype annotation publication rejected an unsafe linked file at \(path).",
            ]
        )
    }

    private static func systemError(operation: String, path: String) -> Error {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not \(operation) at \(path): \(String(cString: strerror(code)))",
            ]
        )
    }
}
