import Darwin
import Foundation

public struct OwnedWorkDirectoryMarker: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case active
        case completed
        case failed
    }

    public static let schemaVersion = 2
    public static let fileName = ".lungfish-owned-work-directory.json"

    public let schemaVersion: Int
    public let projectIdentity: FileSystemObjectIdentity
    public let directoryIdentity: FileSystemObjectIdentity
    public let runID: UUID
    public let processIdentifier: Int32
    public let processStartTime: UInt64
    public let bootSessionID: String
    public let state: State
    public let lockRelativePath: String?
    public let keepIntermediates: Bool
    public let toolName: String
    public let toolVersion: String

    public init(
        projectIdentity: FileSystemObjectIdentity,
        directoryIdentity: FileSystemObjectIdentity,
        runID: UUID,
        processIdentifier: Int32,
        processStartTime: UInt64,
        bootSessionID: String,
        state: State,
        lockRelativePath: String?,
        keepIntermediates: Bool,
        toolName: String,
        toolVersion: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.projectIdentity = projectIdentity
        self.directoryIdentity = directoryIdentity
        self.runID = runID
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.bootSessionID = bootSessionID
        self.state = state
        self.lockRelativePath = lockRelativePath
        self.keepIntermediates = keepIntermediates
        self.toolName = toolName
        self.toolVersion = toolVersion
    }

    public func matchesProcessIdentity(_ identity: OwnedProcessIdentity) -> Bool {
        processIdentifier == identity.processIdentifier
            && processStartTime == identity.processStartTime
            && bootSessionID == identity.bootSessionID
    }
}
