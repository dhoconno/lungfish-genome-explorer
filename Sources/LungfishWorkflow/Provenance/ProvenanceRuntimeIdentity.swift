// ProvenanceRuntimeIdentity.swift - App, executable and host details recorded for a run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceRuntimeIdentity

/// The app, executable and host that produced a record.
///
/// A writer fills every field from its own process. A reader keeps only what the record holds,
/// so a field the record never held is nil and reads Not recorded, never a value from the Mac
/// that reads it (plan decision S4).
public struct ProvenanceRuntimeIdentity: Codable, Sendable, Equatable {
    public let appVersion: String?
    public let executablePath: String?
    public let processIdentifier: Int?
    public let operatingSystemVersion: String?
    public let architecture: String?
    public let gitRevision: String?
    public let user: String?
    public let condaEnvironment: String?
    public let condaPrefix: String?
    public let pluginPack: String?
    public let containerImage: String?
    public let containerDigest: String?
    public let dependencySet: String?

    private enum CodingKeys: String, CodingKey {
        case appVersion
        case executablePath
        case processIdentifier
        case operatingSystemVersion
        case architecture
        case gitRevision
        case user
        case condaEnvironment
        case condaPrefix
        case pluginPack
        case containerImage
        case containerDigest
        case dependencySet
    }

    /// A writer passes values or takes the defaults of its own process, and a blank value takes the
    /// default as before. A reader passes nil for a field the record never held.
    public init(
        appVersion: String? = WorkflowRun.currentAppVersion,
        executablePath: String? = Self.currentExecutablePath,
        processIdentifier: Int? = Int(ProcessInfo.processInfo.processIdentifier),
        operatingSystemVersion: String? = WorkflowRun.currentHostOS,
        architecture: String? = Self.currentArchitecture,
        gitRevision: String? = nil,
        user: String? = WorkflowRun.currentUser,
        condaEnvironment: String? = nil,
        condaPrefix: String? = nil,
        pluginPack: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        dependencySet: String? = ManagedToolLock.bundled.resolvedDependencySet
    ) {
        self.appVersion = appVersion.map { ProvenanceVersion.required($0, fallback: WorkflowRun.currentAppVersion) }
        self.executablePath = executablePath.map { ProvenanceVersion.required($0, fallback: Self.currentExecutablePath) }
        self.processIdentifier = processIdentifier
        self.operatingSystemVersion = operatingSystemVersion.map {
            ProvenanceVersion.required($0, fallback: WorkflowRun.currentHostOS)
        }
        self.architecture = architecture.map { ProvenanceVersion.required($0, fallback: Self.currentArchitecture) }
        self.gitRevision = gitRevision
        let normalizedUser = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = normalizedUser?.isEmpty == false ? normalizedUser : nil
        self.condaEnvironment = condaEnvironment
        self.condaPrefix = condaPrefix
        self.pluginPack = pluginPack
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.dependencySet = dependencySet
    }

    /// A missing or blank key decodes as nil. A present value decodes trimmed, as before.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = Self.recorded(try container.decodeIfPresent(String.self, forKey: .appVersion))
        executablePath = Self.recorded(try container.decodeIfPresent(String.self, forKey: .executablePath))
        processIdentifier = try container.decodeIfPresent(Int.self, forKey: .processIdentifier)
        operatingSystemVersion = Self.recorded(try container.decodeIfPresent(String.self, forKey: .operatingSystemVersion))
        architecture = Self.recorded(try container.decodeIfPresent(String.self, forKey: .architecture))
        gitRevision = try container.decodeIfPresent(String.self, forKey: .gitRevision)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        condaEnvironment = try container.decodeIfPresent(String.self, forKey: .condaEnvironment)
        condaPrefix = try container.decodeIfPresent(String.self, forKey: .condaPrefix)
        pluginPack = try container.decodeIfPresent(String.self, forKey: .pluginPack)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        containerDigest = try container.decodeIfPresent(String.self, forKey: .containerDigest)
        dependencySet = try container.decodeIfPresent(String.self, forKey: .dependencySet)
    }

    /// A recorded text value trimmed, or nil when the record holds none or only blanks.
    static func recorded(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static var currentExecutablePath: String {
        ProvenanceVersion.required(
            Bundle.main.executablePath ?? CommandLine.arguments.first,
            fallback: "unknown"
        )
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
