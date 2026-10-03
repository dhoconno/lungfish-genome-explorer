@preconcurrency import Foundation
import LungfishCore
import os.log

public struct PackToolStatus: Sendable, Codable, Hashable, Identifiable {
    public let requirement: PackToolRequirement
    public let environmentExists: Bool
    public let missingExecutables: [String]
    public let smokeTestFailure: String?
    public let storageUnavailablePath: String?

    public init(
        requirement: PackToolRequirement,
        environmentExists: Bool,
        missingExecutables: [String],
        smokeTestFailure: String?,
        storageUnavailablePath: String?
    ) {
        self.requirement = requirement
        self.environmentExists = environmentExists
        self.missingExecutables = missingExecutables
        self.smokeTestFailure = smokeTestFailure
        self.storageUnavailablePath = storageUnavailablePath
    }

    public var id: String { requirement.id }
    public var isReady: Bool {
        storageUnavailablePath == nil && missingExecutables.isEmpty && smokeTestFailure == nil
    }
    public var needsReinstall: Bool { storageUnavailablePath == nil && environmentExists && !isReady }
    public var hasVolatileSmokeTestFailure: Bool {
        smokeTestFailure != nil && requirement.managedDatabaseID == nil
    }

    public var statusText: String {
        if storageUnavailablePath != nil {
            return "Storage unavailable"
        }
        if isReady {
            return "Ready"
        }
        if requirement.managedDatabaseID != nil {
            return environmentExists ? "Needs refresh" : "Needs download"
        }
        if needsReinstall {
            return "Needs reinstall"
        }
        return "Needs install"
    }
}
