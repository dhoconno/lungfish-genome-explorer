// ProvenanceRuntimeIdentity.swift - App, executable and host details recorded for a run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceRuntimeIdentity

public struct ProvenanceRuntimeIdentity: Codable, Sendable, Equatable {
    public let appVersion: String
    public let executablePath: String
    public let processIdentifier: Int
    public let operatingSystemVersion: String
    public let architecture: String
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

    public init(
        appVersion: String = WorkflowRun.currentAppVersion,
        executablePath: String = Self.currentExecutablePath,
        processIdentifier: Int = Int(ProcessInfo.processInfo.processIdentifier),
        operatingSystemVersion: String = WorkflowRun.currentHostOS,
        architecture: String = Self.currentArchitecture,
        gitRevision: String? = nil,
        user: String? = WorkflowRun.currentUser,
        condaEnvironment: String? = nil,
        condaPrefix: String? = nil,
        pluginPack: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        dependencySet: String? = ManagedToolLock.bundled.resolvedDependencySet
    ) {
        self.appVersion = ProvenanceVersion.required(appVersion, fallback: WorkflowRun.currentAppVersion)
        self.executablePath = ProvenanceVersion.required(executablePath, fallback: Self.currentExecutablePath)
        self.processIdentifier = processIdentifier
        self.operatingSystemVersion = ProvenanceVersion.required(operatingSystemVersion, fallback: WorkflowRun.currentHostOS)
        self.architecture = ProvenanceVersion.required(architecture, fallback: Self.currentArchitecture)
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .appVersion),
            fallback: WorkflowRun.currentAppVersion
        )
        executablePath = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .executablePath),
            fallback: Self.currentExecutablePath
        )
        processIdentifier = try container.decodeIfPresent(Int.self, forKey: .processIdentifier)
            ?? Int(ProcessInfo.processInfo.processIdentifier)
        operatingSystemVersion = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .operatingSystemVersion),
            fallback: WorkflowRun.currentHostOS
        )
        architecture = ProvenanceVersion.required(
            try container.decodeIfPresent(String.self, forKey: .architecture),
            fallback: Self.currentArchitecture
        )
        gitRevision = try container.decodeIfPresent(String.self, forKey: .gitRevision)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        condaEnvironment = try container.decodeIfPresent(String.self, forKey: .condaEnvironment)
        condaPrefix = try container.decodeIfPresent(String.self, forKey: .condaPrefix)
        pluginPack = try container.decodeIfPresent(String.self, forKey: .pluginPack)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        containerDigest = try container.decodeIfPresent(String.self, forKey: .containerDigest)
        dependencySet = try container.decodeIfPresent(String.self, forKey: .dependencySet)
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
