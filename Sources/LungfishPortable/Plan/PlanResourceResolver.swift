// PlanResourceResolver.swift - Resolves a plan's files under the plan's folder and opens outputs without following links
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Why the resolver refused a plan path.
package enum PlanResourceRefusal: Error, Equatable, Sendable, LocalizedError {
    case emptyPath
    case absolutePath(String)
    case dotComponent(String)
    case leadingDash(String)
    case escapesWorkRoot(String)
    case missing(String)
    case notRegularFile(String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case digestMismatch(path: String, expected: String, actual: String)
    /// A component of an output path is a symbolic link or not a folder, or the output itself is a link.
    case linkInOutputPath(path: String, component: String)
    case systemError(path: String, operation: String, code: Int32)

    package var errorDescription: String? { reason }

    package var reason: String {
        switch self {
        case .emptyPath:
            return "A plan path is empty."
        case .absolutePath(let path):
            return "The plan path \(path) is absolute. Every plan path is relative to the plan's folder."
        case .dotComponent(let path):
            return "The plan path \(path) holds an empty, . or .. component."
        case .leadingDash(let path):
            return "The plan path \(path) begins with -, which a tool would read as an option."
        case .escapesWorkRoot(let path):
            return "The plan path \(path) leads outside the plan's folder through a symbolic link."
        case .missing(let path):
            return "The plan's file \(path) is missing."
        case .notRegularFile(let path):
            return "The plan's file \(path) is not a regular file."
        case .sizeMismatch(let path, let expected, let actual):
            return "The plan's file \(path) holds \(actual) bytes, and the plan pins \(expected)."
        case .digestMismatch(let path, let expected, let actual):
            return "The plan's file \(path) has SHA-256 \(actual), and the plan pins \(expected)."
        case .linkInOutputPath(let path, let component):
            return "The output \(path) passes through \(component), which is a symbolic link or not a folder. The executor never follows a link when it writes."
        case .systemError(let path, let operation, let code):
            return "Could not \(operation) \(path). \(String(cString: strerror(code)))"
        }
    }
}

/// An output the resolver created, open for writing, with the identity of the file the descriptor names.
package struct PlanOutputFile: Sendable, Equatable {
    package let relativePath: String
    package let fileDescriptor: Int32
    package let device: UInt64
    package let inode: UInt64

    /// Closes the descriptor. Call it once, after the step that wrote through it has ended.
    package func closeDescriptor() {
        _ = close(fileDescriptor)
    }
}

/// Resolves every plan path under the work root, the real path of the folder that holds the plan file, on Linux and on
/// macOS alike (ARCH A4, SWIFT N8). It never searches and reads no environment variable.
package struct PlanResourceResolver: Sendable {
    /// The real path of the plan's folder, resolved once.
    package let workRoot: String

    /// A resolver rooted at the folder that holds `planFile`.
    package init(planFile: URL) throws {
        try self.init(workRoot: planFile.deletingLastPathComponent())
    }

    package init(workRoot folder: URL) throws {
        guard let real = realpath(folder.path, nil) else {
            throw PlanResourceRefusal.systemError(path: folder.path, operation: "resolve", code: errno)
        }
        defer { free(real) }
        workRoot = String(cString: real)
    }

    /// The lexical rules of a plan path: relative, no empty, `.` or `..` component, and a first component that does not
    /// begin with `-`. Nil when the path passes.
    package static func refusal(forRelativePath path: String) -> PlanResourceRefusal? {
        guard !path.isEmpty else { return .emptyPath }
        guard !path.hasPrefix("/") else { return .absolutePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return .dotComponent(path) }
        if components[0].hasPrefix("-") { return .leadingDash(path) }
        return nil
    }

    /// Checks an entry's size and SHA-256 and returns the file's real URL. A symbolic link inside the plan's folder is
    /// followed, and one that leads outside it is refused. The digest is read from the descriptor that `fstat` checked.
    package func verify(_ entry: PlanEntry) throws -> URL {
        let path = entry.relativePath
        if let refusal = Self.refusal(forRelativePath: path) { throw refusal }
        guard let realPointer = realpath(workRoot + "/" + path, nil) else {
            let code = errno
            throw code == ENOENT ? PlanResourceRefusal.missing(path) : .systemError(path: path, operation: "resolve", code: code)
        }
        let real = String(cString: realPointer)
        free(realPointer)
        guard real.hasPrefix(workRoot == "/" ? "/" : workRoot + "/") else { throw PlanResourceRefusal.escapesWorkRoot(path) }
        let fd = open(real, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PlanResourceRefusal.systemError(path: path, operation: "open", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw PlanResourceRefusal.systemError(path: path, operation: "stat", code: errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw PlanResourceRefusal.notRegularFile(path) }
        let size = Int64(status.st_size)
        guard size == entry.size else { throw PlanResourceRefusal.sizeMismatch(path: path, expected: entry.size, actual: size) }
        let digest = try PortableDigest.sha256Hex(reading: handle)
        guard digest == entry.sha256 else {
            throw PlanResourceRefusal.digestMismatch(path: path, expected: entry.sha256, actual: digest)
        }
        return URL(fileURLWithPath: real)
    }

    /// Creates the folders of `relativePath` and the file itself, truncated, by a walk of directory descriptors from the
    /// work root that opens each component with `O_NOFOLLOW`, and returns the open descriptor. A link anywhere on the
    /// path is refused, and a file planted at the path later is never written, since the step writes through this
    /// descriptor (RUNNING-A-TOOL.md, Output into a descriptor you own).
    package func openOutput(_ relativePath: String) throws -> PlanOutputFile {
        if let refusal = Self.refusal(forRelativePath: relativePath) { throw refusal }
        let components = relativePath.split(separator: "/").map(String.init)
        let directory = try openDirectoryWalk(components.dropLast(), path: relativePath)
        defer { close(directory) }
        let name = components[components.count - 1]
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP { throw PlanResourceRefusal.linkInOutputPath(path: relativePath, component: name) }
            throw PlanResourceRefusal.systemError(path: relativePath, operation: "create", code: code)
        }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            let code = errno
            close(fd)
            throw PlanResourceRefusal.systemError(path: relativePath, operation: "stat", code: code)
        }
        return PlanOutputFile(
            relativePath: relativePath,
            fileDescriptor: fd,
            device: UInt64(truncatingIfNeeded: status.st_dev),
            inode: UInt64(truncatingIfNeeded: status.st_ino)
        )
    }

    /// Creates a folder under the work root, and its parents, without following a link.
    package func makeDirectory(_ relativePath: String) throws {
        if let refusal = Self.refusal(forRelativePath: relativePath) { throw refusal }
        let fd = try openDirectoryWalk(relativePath.split(separator: "/").map(String.init)[...], path: relativePath)
        close(fd)
    }

    /// Opens the work root and then each component as a folder with `O_NOFOLLOW`, creating a missing one.
    private func openDirectoryWalk(_ components: ArraySlice<String>, path: String) throws -> Int32 {
        var directory = open(workRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw PlanResourceRefusal.systemError(path: workRoot, operation: "open", code: errno) }
        for component in components {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var next = openat(directory, component, flags)
            if next < 0, errno == ENOENT {
                if mkdirat(directory, component, 0o755) != 0, errno != EEXIST {
                    let code = errno
                    close(directory)
                    throw PlanResourceRefusal.systemError(path: path, operation: "create the folder \(component) of", code: code)
                }
                next = openat(directory, component, flags)
            }
            let code = errno
            close(directory)
            guard next >= 0 else {
                if code == ELOOP || code == ENOTDIR { throw PlanResourceRefusal.linkInOutputPath(path: path, component: component) }
                throw PlanResourceRefusal.systemError(path: path, operation: "open the folder \(component) of", code: code)
            }
            directory = next
        }
        return directory
    }
}
