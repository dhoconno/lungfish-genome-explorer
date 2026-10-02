import Darwin
import Foundation

public struct FileSystemObjectIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public static func noFollow(_ url: URL) throws -> Self {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, !standardized.path.utf8.contains(0) else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(url.path)
        }
        if standardized.path == "/" {
            let descriptor: Int32
            do {
                descriptor = try NoFollowFileSystem.openDirectoryHierarchy(standardized)
            } catch {
                throw OwnedWorkDirectoryMarkerError.unsafePath(standardized.path)
            }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0 else {
                throw OwnedWorkDirectoryMarkerError.systemFailure(
                    path: standardized.path,
                    operation: "inspect filesystem identity",
                    code: errno
                )
            }
            return Self(info)
        }

        let parentURL = standardized.deletingLastPathComponent()
        let leafName = standardized.lastPathComponent
        guard DurableAtomicFileStore.isSinglePathComponent(leafName) else {
            throw OwnedWorkDirectoryMarkerError.unsafePath(standardized.path)
        }
        let parentDescriptor: Int32
        do {
            parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(parentURL)
        } catch {
            throw OwnedWorkDirectoryMarkerError.unsafePath(parentURL.path)
        }
        defer { Darwin.close(parentDescriptor) }
        var info = stat()
        let status = leafName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            throw OwnedWorkDirectoryMarkerError.systemFailure(
                path: standardized.path,
                operation: "inspect filesystem identity",
                code: errno
            )
        }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    init(_ info: stat) {
        self.init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    public init(from info: stat) {
        self.init(info)
    }
}
