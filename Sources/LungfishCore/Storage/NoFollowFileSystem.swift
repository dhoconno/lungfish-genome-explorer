// NoFollowFileSystem.swift - Directory opens that never follow a link planted below their anchor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

public enum NoFollowFileSystem {
    /// Opens an absolute directory path without following caller-controlled
    /// symbolic links. The caller owns the returned descriptor and must close
    /// it.
    ///
    /// ## Anchoring and threat model
    ///
    /// When the path lies inside an LGE project (`*.lungfish`) or an LGE
    /// bundle (any `*.lungfish…` directory such as `.lungfishref` or
    /// `.lungfishfastq`), the no-follow walk is anchored at the outermost such
    /// directory (see ``trustedAnchor(for:)``). The anchor is opened by its
    /// full path, and only the components below it are walked one at a time
    /// with `O_NOFOLLOW`.
    ///
    /// Symbolic links above the anchor belong to the user's own filesystem
    /// layout (for example a home folder on another volume, or `/var` and
    /// `/tmp`). LGE only needs to guard against links planted inside the
    /// project or bundle, which could redirect writes outside it. Those are
    /// still rejected, and so is an anchor whose final component is itself a
    /// symbolic link.
    ///
    /// Anchoring also avoids opening protected folders such as `~/Desktop`,
    /// `~/Documents` or `~/Downloads` as directories. macOS requires the
    /// folder-level privacy (TCC) grant for that even when the user opened a
    /// project inside them, and without it `openat` blocks indefinitely.
    ///
    /// A path outside every project and bundle is anchored at the folder
    /// itself (plan decision V3). Links above it are the user's layout, such
    /// as a conda root under a storage folder moved to an external drive and
    /// linked back, and the folder must be a real directory. Before V3 such a
    /// path was walked from `/`, which refused every link but `/var` and
    /// `/tmp`, rolled back verified installs and opened protected folders.
    public static func openDirectoryHierarchy(_ url: URL) throws -> Int32 {
        try openDirectoryHierarchy(url, anchoredAt: trustedAnchor(for: url) ?? url)
    }

    /// Opens `url` without following symbolic links below `anchor`.
    ///
    /// `anchor` must be `url` itself or one of its ancestors. It is opened by
    /// full path, so symbolic links in its ancestors are followed, but its
    /// final component must be a real directory. Every component between
    /// `anchor` and `url` is opened with `O_NOFOLLOW`. Passing `nil` performs
    /// the full walk from `/`.
    public static func openDirectoryHierarchy(
        _ url: URL,
        anchoredAt anchor: URL?
    ) throws -> Int32 {
        let requested = url.standardizedFileURL
        guard requested.isFileURL, requested.path.hasPrefix("/") else {
            throw POSIXError(.EINVAL)
        }
        guard let anchor else {
            return try openFullHierarchy(requested)
        }
        let anchorURL = anchor.standardizedFileURL
        guard anchorURL.isFileURL, anchorURL.path.hasPrefix("/") else {
            throw POSIXError(.EINVAL)
        }
        let anchorComponents = NSString(string: anchorURL.path).pathComponents
        let requestedComponents = NSString(string: requested.path).pathComponents
        guard requestedComponents.count >= anchorComponents.count,
              Array(requestedComponents.prefix(anchorComponents.count))
                == anchorComponents else {
            throw POSIXError(.EINVAL)
        }
        // O_NOFOLLOW applies only to the final component here: ancestors of
        // the anchor are resolved normally, and an anchor that is `/var` or
        // `/tmp` itself opens through its platform alias.
        let anchorDescriptor = Darwin.open(
            resolvingPlatformAliases(anchorURL.path),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard anchorDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try walk(
            from: anchorDescriptor,
            components: requestedComponents.dropFirst(anchorComponents.count)
        )
    }

    /// The directory at which ``openDirectoryHierarchy(_:)`` anchors its walk:
    /// the outermost path component whose extension starts with `lungfish`
    /// (a `.lungfish` project or a `.lungfish…` bundle), or `nil` when the
    /// path is not inside one.
    public static func trustedAnchor(for url: URL) -> URL? {
        let requested = url.standardizedFileURL
        guard requested.isFileURL else { return nil }
        let components = NSString(string: requested.path).pathComponents
        guard components.first == "/" else { return nil }
        for index in components.indices.dropFirst() {
            let pathExtension = NSString(string: components[index])
                .pathExtension
                .lowercased()
            if pathExtension.hasPrefix("lungfish") {
                let path = NSString.path(
                    withComponents: Array(components[...index])
                )
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    /// `/var` and `/tmp` are immutable compatibility links installed by macOS
    /// itself. Only these two platform aliases are canonicalized before a
    /// no-follow open, whether the walk starts at `/` or at an anchor.
    /// `standardizedFileURL` spells `/private/tmp` as `/tmp`, so without this
    /// an anchor at either would be refused as a link. Arbitrary
    /// caller-controlled symbolic links remain rejected.
    private static func resolvingPlatformAliases(_ path: String) -> String {
        for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func openFullHierarchy(_ requested: URL) throws -> Int32 {
        let traversalPath = resolvingPlatformAliases(requested.path)
        let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try walk(
            from: descriptor,
            components: NSString(string: traversalPath).pathComponents.dropFirst()
        )
    }

    /// Walks `components` below `start` with `O_NOFOLLOW`. Takes ownership of
    /// `start` and returns the descriptor of the final directory.
    private static func walk(
        from start: Int32,
        components: ArraySlice<String>
    ) throws -> Int32 {
        var descriptor = start
        do {
            for component in components where component != "/" {
                let next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(.ENOTDIR)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    package static func readRegularFile(
        named fileName: String,
        inDirectory directoryDescriptor: Int32,
        displayPath: String,
        maximumSize: Int = 1_048_576
    ) throws -> Data {
        let descriptor = fileName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumSize else {
            throw POSIXError(.EINVAL)
        }

        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            guard result.count + count <= maximumSize else {
                throw POSIXError(.EFBIG)
            }
            result.append(buffer, count: count)
        }
        return result
    }
}
