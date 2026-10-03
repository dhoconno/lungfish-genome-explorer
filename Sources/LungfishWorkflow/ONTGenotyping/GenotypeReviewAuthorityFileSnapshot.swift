import Darwin
import CryptoKit
import Foundation
import LungfishIO

struct GenotypeReviewAuthorityFileSnapshot: Equatable, Sendable {
    let url: URL
    let data: Data
    let sha256: String
    let fileSize: UInt64
    let identity: FileSystemObjectIdentity
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static func capture(
        _ url: URL,
        retainingData: Bool = true,
        readObserver: ((Int) -> Void)? = nil
    ) throws -> Self {
        let standardized = url.standardizedFileURL
        let parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            standardized.deletingLastPathComponent()
        )
        defer { Darwin.close(parentDescriptor) }
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw GenotypeReviewableRowCatalogPublisherError
                .invalidInputDescriptor(standardized.path)
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw GenotypeReviewableRowCatalogPublisherError
                .invalidInputDescriptor(standardized.path)
        }
        var data = Data()
        if retainingData {
            data.reserveCapacity(Int(before.st_size))
        }
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            if retainingData {
                data.append(chunk)
            }
            bytesRead += UInt64(count)
            readObserver?(count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              FileSystemObjectIdentity(from: before)
                == FileSystemObjectIdentity(from: after),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              bytesRead == UInt64(after.st_size) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
        return Self(
            url: standardized,
            data: data,
            sha256: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined(),
            fileSize: bytesRead,
            identity: FileSystemObjectIdentity(from: after),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            changeSeconds: Int64(after.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(after.st_ctimespec.tv_nsec)
        )
    }

    func requireUnchanged() throws {
        let current = try Self.capture(url, retainingData: false)
        guard current.identity == identity,
              current.fileSize == fileSize,
              current.sha256 == sha256,
              current.modificationSeconds == modificationSeconds,
              current.modificationNanoseconds == modificationNanoseconds,
              current.changeSeconds == changeSeconds,
              current.changeNanoseconds == changeNanoseconds else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(url.path)
        }
    }

    func requireMetadataUnchanged() throws {
        let standardized = url.standardizedFileURL
        let parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            standardized.deletingLastPathComponent()
        )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = standardized.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              FileSystemObjectIdentity(from: info) == identity,
              UInt64(info.st_size) == fileSize,
              Int64(info.st_mtimespec.tv_sec) == modificationSeconds,
              Int64(info.st_mtimespec.tv_nsec) == modificationNanoseconds,
              Int64(info.st_ctimespec.tv_sec) == changeSeconds,
              Int64(info.st_ctimespec.tv_nsec) == changeNanoseconds else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
    }

    func descriptor(
        format: FileFormat?,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: sha256,
            fileSize: fileSize,
            format: format,
            role: role
        )
    }
}
