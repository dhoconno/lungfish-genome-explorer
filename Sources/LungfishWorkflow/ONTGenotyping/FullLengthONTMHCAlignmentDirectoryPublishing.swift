import Foundation
import Darwin
import LungfishIO

public protocol FullLengthONTMHCAlignmentDirectoryPublishing: Sendable {
    func acquirePublicationLock(
        artifactsDirectoryURL: URL
    ) throws -> any FullLengthONTMHCAlignmentPublicationLock

    func publish(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    ) throws -> FullLengthONTMHCAlignmentDirectoryPublication

    func cleanupRetiredDirectory(at url: URL) throws
}

public extension FullLengthONTMHCAlignmentDirectoryPublishing {
    func acquirePublicationLock(
        artifactsDirectoryURL: URL
    ) throws -> any FullLengthONTMHCAlignmentPublicationLock {
        try DarwinFullLengthONTMHCAlignmentPublicationLock.acquire(
            artifactsDirectoryURL: artifactsDirectoryURL
        )
    }

    func cleanupRetiredDirectory(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
