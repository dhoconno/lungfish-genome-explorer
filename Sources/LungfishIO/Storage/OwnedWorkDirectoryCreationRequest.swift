import Darwin
import Foundation

public struct OwnedWorkDirectoryCreationRequest: Sendable {
    public let projectURL: URL
    public let parentDirectoryURL: URL
    public let prefix: String
    public let runID: UUID
    public let processIdentity: OwnedProcessIdentity
    public let state: OwnedWorkDirectoryMarker.State
    public let lockRelativePath: String?
    public let keepIntermediates: Bool
    public let toolName: String
    public let toolVersion: String

    public init(
        projectURL: URL,
        parentDirectoryURL: URL,
        prefix: String,
        runID: UUID,
        processIdentity: OwnedProcessIdentity,
        state: OwnedWorkDirectoryMarker.State,
        lockRelativePath: String?,
        keepIntermediates: Bool,
        toolName: String,
        toolVersion: String
    ) {
        self.projectURL = projectURL
        self.parentDirectoryURL = parentDirectoryURL
        self.prefix = prefix
        self.runID = runID
        self.processIdentity = processIdentity
        self.state = state
        self.lockRelativePath = lockRelativePath
        self.keepIntermediates = keepIntermediates
        self.toolName = toolName
        self.toolVersion = toolVersion
    }
}
