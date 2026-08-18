import Foundation
import LungfishCore

public actor ManagedStorageCoordinator {
    public enum Error: Swift.Error, LocalizedError {
        case nestedRootRelationship(currentRoot: URL, requestedRoot: URL)

        public var errorDescription: String? {
            switch self {
            case .nestedRootRelationship(let currentRoot, let requestedRoot):
                return "Managed storage roots must not be nested: \(currentRoot.path) and \(requestedRoot.path)"
            }
        }
    }

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
        try validateNoNestedRelationship(currentRoot: current.rootURL, requestedRoot: validated.rootURL)

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
            copyDependencyReceipt(from: current, to: validated)
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
        try validateNoNestedRelationship(currentRoot: activeRoot, requestedRoot: previousRoot)

        if previousRoot != activeRoot, fileManager.fileExists(atPath: previousRoot.path) {
            let previousLocation = ManagedStorageLocation(rootURL: previousRoot)
            for managedURL in [
                previousLocation.condaRootURL,
                previousLocation.databaseRootURL,
                previousLocation.dependencyReceiptURL,
            ] {
                if fileManager.fileExists(atPath: managedURL.path) {
                    try fileManager.removeItem(at: managedURL)
                }
            }

            let remainingContents = try? fileManager.contentsOfDirectory(
                at: previousRoot,
                includingPropertiesForKeys: nil
            )
            if remainingContents?.isEmpty == true {
                try fileManager.removeItem(at: previousRoot)
            }
        }

        config.previousRootPath = nil
        config.migrationState = nil
        try saveBootstrapConfig(config)
    }

    /// Carries the dependency receipt to the new root.
    ///
    /// Best-effort on purpose: the tools and databases are already in place by this point, and
    /// a missing receipt only costs the next launch a re-plan (which will synthesize one from
    /// disk). Failing the whole relocation over a bookkeeping file would be worse.
    private func copyDependencyReceipt(
        from previous: ManagedStorageLocation,
        to destination: ManagedStorageLocation
    ) {
        let source = previous.dependencyReceiptURL
        let target = destination.dependencyReceiptURL
        guard source.standardizedFileURL != target.standardizedFileURL,
              fileManager.fileExists(atPath: source.path) else {
            return
        }
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: target)
        }
        try? fileManager.copyItem(at: source, to: target)
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

    private func validateNoNestedRelationship(currentRoot: URL, requestedRoot: URL) throws {
        let currentRoot = currentRoot.standardizedFileURL
        let requestedRoot = requestedRoot.standardizedFileURL

        if Self.isAncestor(currentRoot, of: requestedRoot) || Self.isAncestor(requestedRoot, of: currentRoot) {
            throw Error.nestedRootRelationship(currentRoot: currentRoot, requestedRoot: requestedRoot)
        }
    }

    private static func isAncestor(_ candidateAncestor: URL, of candidateDescendant: URL) -> Bool {
        let ancestorComponents = candidateAncestor.standardizedFileURL.pathComponents
        let descendantComponents = candidateDescendant.standardizedFileURL.pathComponents

        guard ancestorComponents.count < descendantComponents.count else {
            return false
        }

        return zip(ancestorComponents, descendantComponents).allSatisfy(==)
    }
}
