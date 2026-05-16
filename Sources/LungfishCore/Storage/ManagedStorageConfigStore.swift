import Foundation

public struct ManagedStorageBootstrapConfig: Codable, Equatable, Sendable {
    public var activeRootPath: String
    public var previousRootPath: String?
    public var migrationState: MigrationState?

    public enum MigrationState: String, Codable, Equatable, Sendable {
        case pending
        case completed
    }

    public init(
        activeRootPath: String,
        previousRootPath: String? = nil,
        migrationState: MigrationState? = nil
    ) {
        self.activeRootPath = activeRootPath
        self.previousRootPath = previousRootPath
        self.migrationState = migrationState
    }
}

public final class ManagedStorageConfigStore: @unchecked Sendable {
    @MainActor public static var shared = ManagedStorageConfigStore()
    private static let legacyDatabaseStorageLocationKey = "DatabaseStorageLocation"

    public enum BootstrapConfigLoadState: Sendable, Equatable {
        case missing
        case malformed
        case loaded(ManagedStorageBootstrapConfig)
    }

    public let configURL: URL

    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.configURL = self.homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("lungfish", isDirectory: true)
            .appendingPathComponent("storage-location.json")
    }

    public var defaultLocation: ManagedStorageLocation {
        ManagedStorageLocation.defaultLocation(homeDirectory: homeDirectory)
    }

    public func bootstrapConfigLoadState() -> BootstrapConfigLoadState {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(ManagedStorageBootstrapConfig.self, from: data)
            return .loaded(config)
        } catch {
            return .malformed
        }
    }

    public func currentLocation() -> ManagedStorageLocation {
        switch bootstrapConfigLoadState() {
        case .loaded(let config) where !config.activeRootPath.isEmpty:
            return ManagedStorageLocation(rootURL: URL(fileURLWithPath: config.activeRootPath, isDirectory: true))
        case .missing:
            return legacyLocation() ?? defaultLocation
        case .malformed:
            return defaultLocation
        case .loaded:
            return defaultLocation
        }
    }

    public func currentCondaRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["LUNGFISH_CONDA_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            guard case .valid = ManagedStorageLocation.validateSelection(overrideURL) else {
                return currentLocation().condaRootURL
            }
            return overrideURL
        }
        return currentLocation().condaRootURL
    }

    public func resetToDefaultLocation() throws {
        try removeBootstrapConfigIfPresent()
        UserDefaults.standard.removeObject(forKey: Self.legacyDatabaseStorageLocationKey)
    }

    public func setActiveRoot(_ rootURL: URL) throws {
        let location = ManagedStorageLocation(rootURL: rootURL)
        switch ManagedStorageLocation.validateSelection(location.rootURL) {
        case .valid:
            break
        case .invalid(let error):
            throw error
        }

        try saveBootstrapConfig(ManagedStorageBootstrapConfig(activeRootPath: location.rootURL.path))
    }

    private func legacyLocation() -> ManagedStorageLocation? {
        guard let path = UserDefaults.standard.string(forKey: Self.legacyDatabaseStorageLocationKey),
              !path.isEmpty else {
            return nil
        }

        let location = ManagedStorageLocation(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        guard case .valid = ManagedStorageLocation.validateSelection(location.rootURL) else {
            return nil
        }
        return location
    }

    private func saveBootstrapConfig(_ config: ManagedStorageBootstrapConfig) throws {
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    private func removeBootstrapConfigIfPresent() throws {
        if fileManager.fileExists(atPath: configURL.path) {
            try fileManager.removeItem(at: configURL)
        }
    }
}
