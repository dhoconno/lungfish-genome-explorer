import Foundation
import LungfishCore

public actor ManagedStorageCoordinator {
    public typealias Validator = @Sendable (URL) throws -> ManagedStorageLocation
    public typealias DatabaseMigrator = @Sendable (_ from: URL, _ to: URL) async throws -> Void
    public typealias ToolInstaller = @Sendable (_ condaRoot: URL) async throws -> Void
    public typealias Verifier = @Sendable (_ location: ManagedStorageLocation) async throws -> Void

    private enum PersistedConfigState: Sendable {
        case missing
        case loaded(ManagedStorageBootstrapConfig)
    }

    private let configStore: ManagedStorageConfigStore
    private let validator: Validator
    private let databaseMigrator: DatabaseMigrator
    private let toolInstaller: ToolInstaller
    private let verifier: Verifier
    private let fileManager: FileManager

    public init(
        configStore: ManagedStorageConfigStore = ManagedStorageConfigStore(),
        validator: Validator? = nil,
        databaseMigrator: DatabaseMigrator? = nil,
        toolInstaller: ToolInstaller? = nil,
        verifier: Verifier? = nil,
        fileManager: FileManager = .default
    ) {
        self.configStore = configStore
        self.validator = validator ?? Self.defaultValidator
        self.databaseMigrator = databaseMigrator ?? { from, to in
            try await DatabaseRegistry.shared.copyManagedDatabases(from: from, to: to)
        }
        self.toolInstaller = toolInstaller ?? { _ in }
        self.verifier = verifier ?? { location in
            try await DatabaseRegistry.shared.verifyManagedDatabases(at: location.databaseRootURL)
        }
        self.fileManager = fileManager
    }

    public func changeLocation(to newRoot: URL) async throws {
        let validated = try validator(newRoot)
        let current = configStore.currentLocation()
        guard current.rootURL.standardizedFileURL != validated.rootURL.standardizedFileURL else {
            return
        }

        let originalState = persistedConfigState()
        try fileManager.createDirectory(at: validated.rootURL, withIntermediateDirectories: true)
        try saveBootstrapConfig(ManagedStorageBootstrapConfig(
            activeRootPath: current.rootURL.path,
            previousRootPath: current.rootURL.path,
            migrationState: .pending
        ))

        do {
            try await databaseMigrator(current.databaseRootURL, validated.databaseRootURL)
            try await toolInstaller(validated.condaRootURL)
            try await verifier(validated)
            try saveBootstrapConfig(ManagedStorageBootstrapConfig(
                activeRootPath: validated.rootURL.path,
                previousRootPath: current.rootURL.path,
                migrationState: .completed
            ))
        } catch {
            try restorePersistedConfigState(originalState)
            throw error
        }
    }

    public func removeOldLocalCopies() async throws {
        guard case .loaded(var config) = configStore.bootstrapConfigLoadState(),
              config.migrationState == .completed,
              let previousRootPath = config.previousRootPath,
              !previousRootPath.isEmpty else {
            return
        }

        let activeRoot = URL(fileURLWithPath: config.activeRootPath, isDirectory: true).standardizedFileURL
        let previousRoot = URL(fileURLWithPath: previousRootPath, isDirectory: true).standardizedFileURL

        if previousRoot != activeRoot, fileManager.fileExists(atPath: previousRoot.path) {
            try fileManager.removeItem(at: previousRoot)
        }

        config.previousRootPath = nil
        config.migrationState = nil
        try saveBootstrapConfig(config)
    }

    private func persistedConfigState() -> PersistedConfigState {
        switch configStore.bootstrapConfigLoadState() {
        case .loaded(let config):
            return .loaded(config)
        case .missing, .malformed:
            return .missing
        }
    }

    private func restorePersistedConfigState(_ state: PersistedConfigState) throws {
        switch state {
        case .missing:
            if fileManager.fileExists(atPath: configStore.configURL.path) {
                try fileManager.removeItem(at: configStore.configURL)
            }
        case .loaded(let config):
            try saveBootstrapConfig(config)
        }
    }

    private func saveBootstrapConfig(_ config: ManagedStorageBootstrapConfig) throws {
        try fileManager.createDirectory(
            at: configStore.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configStore.configURL, options: [.atomic])
    }

    private static func defaultValidator(_ url: URL) throws -> ManagedStorageLocation {
        let location = ManagedStorageLocation(rootURL: url)
        switch ManagedStorageLocation.validateSelection(location.rootURL) {
        case .valid:
            return location
        case .invalid(let error):
            throw error
        }
    }
}
