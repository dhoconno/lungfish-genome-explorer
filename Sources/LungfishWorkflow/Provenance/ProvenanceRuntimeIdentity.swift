// ProvenanceRuntimeIdentity.swift - App, executable and host details recorded for a run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - ProvenanceRuntimeIdentity

/// The app, executable and host that produced a record.
///
/// A writer builds it with the initializer whose defaults are its own process's facts. It records
/// its own executable as `<external>/<file name>` and no process ID, because a process ID names
/// nothing once the process has exited and an install path names a folder on one Mac. A reader
/// builds it with the initializer that takes `processIdentifier`, the one fact only a record can
/// hold. That initializer keeps only what the record holds, so a field the record never held is nil
/// and reads Not recorded, never a value from the Mac that reads it.
public struct ProvenanceRuntimeIdentity: Codable, Sendable, Equatable {
    public let appVersion: String?
    /// The executable that ran. A writer records its own executable as `<external>/<file name>`, and
    /// an executable it names for a tool keeps the path it gave.
    public let executablePath: String?
    /// The process ID an older record holds. No writer records one and the encoder never writes it.
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
    /// The SHA-256 of the bundled managed tool lock file's exact bytes, which names the pins in force
    /// beside `dependencySet`. A writer records it when the dependency set it records is the bundled
    /// lock's. A record written before schema version 2 holds none.
    public let managedToolLockSHA256: String?
    /// The site facts the program that started a Linux run passed in, in the order given and as the run record keeps
    /// them, never observed or checked (C4-02). Only an adopted record of a run that had some holds them.
    public let siteFacts: [ProvenanceSiteFact]?

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
        case managedToolLockSHA256
        case siteFacts
    }

    /// A writer's identity. Each default is a fact of the writing process, and a blank value takes the
    /// default as before. The writer's own executable, whether taken from the default or passed as
    /// `argv[0]`, is recorded as `<external>/<file name>`, and no process ID is recorded. The bundled
    /// lock's hash is recorded with the bundled lock's dependency set.
    public init(
        appVersion: String? = WorkflowRun.currentAppVersion,
        executablePath: String? = Self.currentExecutablePath,
        operatingSystemVersion: String? = WorkflowRun.currentHostOS,
        architecture: String? = Self.currentArchitecture,
        gitRevision: String? = nil,
        user: String? = WorkflowRun.currentUser,
        condaEnvironment: String? = nil,
        condaPrefix: String? = nil,
        pluginPack: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        dependencySet: String? = ManagedToolLock.bundled.resolvedDependencySet,
        siteFacts: [ProvenanceSiteFact]? = nil
    ) {
        self.appVersion = appVersion.map { ProvenanceVersion.required($0, fallback: WorkflowRun.currentAppVersion) }
        self.executablePath = executablePath.map {
            Self.recordedExecutablePath(ProvenanceVersion.required($0, fallback: Self.currentExecutablePath))
        }
        self.processIdentifier = nil
        self.operatingSystemVersion = operatingSystemVersion.map {
            ProvenanceVersion.required($0, fallback: WorkflowRun.currentHostOS)
        }
        self.architecture = architecture.map { ProvenanceVersion.required($0, fallback: Self.currentArchitecture) }
        self.gitRevision = gitRevision
        self.user = Self.recorded(user)
        self.condaEnvironment = condaEnvironment
        self.condaPrefix = condaPrefix
        self.pluginPack = pluginPack
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.dependencySet = dependencySet
        self.managedToolLockSHA256 = Self.bundledLockSHA256(recordingDependencySet: dependencySet)
        self.siteFacts = siteFacts
    }

    /// The identity a record holds, for a reader. It takes the process ID the record holds, or nil,
    /// with every other fact the record holds, and a fact it is not given is nil. A text value is kept
    /// trimmed, and a blank one is nil.
    public init(
        appVersion: String?,
        executablePath: String?,
        processIdentifier: Int?,
        operatingSystemVersion: String?,
        architecture: String?,
        gitRevision: String? = nil,
        user: String?,
        condaEnvironment: String? = nil,
        condaPrefix: String? = nil,
        pluginPack: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil,
        dependencySet: String?,
        managedToolLockSHA256: String? = nil,
        siteFacts: [ProvenanceSiteFact]? = nil
    ) {
        self.appVersion = Self.recorded(appVersion)
        self.executablePath = Self.recorded(executablePath)
        self.processIdentifier = processIdentifier
        self.operatingSystemVersion = Self.recorded(operatingSystemVersion)
        self.architecture = Self.recorded(architecture)
        self.gitRevision = gitRevision
        self.user = Self.recorded(user)
        self.condaEnvironment = condaEnvironment
        self.condaPrefix = condaPrefix
        self.pluginPack = pluginPack
        self.containerImage = containerImage
        self.containerDigest = containerDigest
        self.dependencySet = dependencySet
        self.managedToolLockSHA256 = Self.recorded(managedToolLockSHA256)
        self.siteFacts = siteFacts
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
        managedToolLockSHA256 = Self.recorded(try container.decodeIfPresent(String.self, forKey: .managedToolLockSHA256))
        siteFacts = try container.decodeIfPresent([ProvenanceSiteFact].self, forKey: .siteFacts)
    }

    /// Writes every fact the identity holds except the process ID, which no record written since
    /// schema version 2 holds, even one rebuilt from an older record that held it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        try container.encodeIfPresent(operatingSystemVersion, forKey: .operatingSystemVersion)
        try container.encodeIfPresent(architecture, forKey: .architecture)
        try container.encodeIfPresent(gitRevision, forKey: .gitRevision)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encodeIfPresent(condaEnvironment, forKey: .condaEnvironment)
        try container.encodeIfPresent(condaPrefix, forKey: .condaPrefix)
        try container.encodeIfPresent(pluginPack, forKey: .pluginPack)
        try container.encodeIfPresent(containerImage, forKey: .containerImage)
        try container.encodeIfPresent(containerDigest, forKey: .containerDigest)
        try container.encodeIfPresent(dependencySet, forKey: .dependencySet)
        try container.encodeIfPresent(managedToolLockSHA256, forKey: .managedToolLockSHA256)
        try container.encodeIfPresent(siteFacts, forKey: .siteFacts)
    }

    /// The bundled lock file's SHA-256 when `dependencySet` is the bundled lock's dependency set, and nil
    /// for any other set or when the lock could not be read. The hash names the bundled lock only.
    static func bundledLockSHA256(recordingDependencySet dependencySet: String?) -> String? {
        guard let identity = ManagedToolLock.bundledIdentity, dependencySet == identity.dependencySet else {
            return nil
        }
        return identity.fileSHA256
    }

    /// A recorded text value trimmed, or nil when the record holds none or only blanks.
    static func recorded(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// How a writer records `path` as an executable. The running process's own executable, which
    /// `Bundle.main.executablePath` or `argv[0]` names, becomes `<external>/<file name>` inside and
    /// outside projects, so no record holds the install path of the app or CLI that wrote it. The
    /// name, the app version and the lock identity say which build ran. Any other executable, such as
    /// a managed tool's, keeps the path the writer gave.
    static func recordedExecutablePath(_ path: String) -> String {
        guard namesRunningExecutable(path) else { return path }
        return PortablePath.externalPlaceholder + "/" + URL(fileURLWithPath: path).lastPathComponent
    }

    private static func namesRunningExecutable(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return [Bundle.main.executablePath, CommandLine.arguments.first].contains { candidate in
            guard let candidate else { return false }
            return candidate == path || URL(fileURLWithPath: candidate).standardizedFileURL.path == standardized
        }
    }

    /// The running process's executable as the system names it, or `argv[0]`. A writer records it
    /// through ``recordedExecutablePath(_:)``, never as is.
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
