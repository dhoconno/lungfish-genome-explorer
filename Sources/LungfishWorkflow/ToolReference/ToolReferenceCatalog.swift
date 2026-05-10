import Foundation

public enum ToolReferenceSource: String, Codable, Sendable {
    case bundled
    case managed

    public var displayName: String {
        switch self {
        case .bundled: return "bundled"
        case .managed: return "managed"
        }
    }
}

public struct ToolReferenceEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let version: String
    public let source: ToolReferenceSource
    public let environment: String?
    public let packageSpec: String?
    public let executables: [String]
    public let license: String?
    public let sourceURL: String?

    public init(
        id: String,
        displayName: String,
        version: String,
        source: ToolReferenceSource,
        environment: String? = nil,
        packageSpec: String? = nil,
        executables: [String],
        license: String? = nil,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.source = source
        self.environment = environment
        self.packageSpec = packageSpec
        self.executables = executables
        self.license = license
        self.sourceURL = sourceURL
    }
}

public enum ToolReferenceCatalog {
    public static func entries() -> [ToolReferenceEntry] {
        bundledEntries() + managedEntries()
    }

    public static func sortedEntries() -> [ToolReferenceEntry] {
        entries().sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceSortKey(lhs.source) < sourceSortKey(rhs.source)
            }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func bundledEntries() -> [ToolReferenceEntry] {
        guard let manifest = ToolVersionsManifest.loadFromBundle() else { return [] }
        return manifest.tools.map { tool in
            ToolReferenceEntry(
                id: tool.name,
                displayName: tool.displayName,
                version: tool.version,
                source: .bundled,
                executables: tool.executables,
                license: tool.licenseId,
                sourceURL: tool.sourceUrl
            )
        }
    }

    private static func managedEntries() -> [ToolReferenceEntry] {
        guard let lock = try? ManagedToolLock.loadFromBundle() else { return [] }
        return lock.tools.map { tool in
            ToolReferenceEntry(
                id: tool.id,
                displayName: tool.displayName,
                version: tool.version ?? "unknown",
                source: .managed,
                environment: tool.environment,
                packageSpec: tool.packageSpec,
                executables: tool.executables,
                license: tool.license,
                sourceURL: tool.sourceUrl
            )
        }
    }

    private static func sourceSortKey(_ source: ToolReferenceSource) -> Int {
        switch source {
        case .bundled: return 0
        case .managed: return 1
        }
    }
}
