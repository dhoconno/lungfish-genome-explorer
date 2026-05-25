import Foundation

public enum HaplotypeDefinitionScope: String, Codable, CaseIterable, Sendable {
    case builtIn = "built-in"
    case global
    case project

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .global: return "Global"
        case .project: return "Project"
        }
    }

    var precedence: Int {
        switch self {
        case .builtIn: return 0
        case .global: return 1
        case .project: return 2
        }
    }
}

public struct HaplotypeDefinitionRecord: Equatable, Sendable, Identifiable {
    public let scope: HaplotypeDefinitionScope
    public let assayDisplayName: String
    public let definitionSet: GenotypeHaplotypeDefinitionSet
    public let fileURL: URL?
    public let isShadowed: Bool

    public var id: String {
        "\(scope.rawValue):\(definitionSet.assayID):\(definitionSet.id)"
    }

    public init(
        scope: HaplotypeDefinitionScope,
        assayDisplayName: String,
        definitionSet: GenotypeHaplotypeDefinitionSet,
        fileURL: URL?,
        isShadowed: Bool = false
    ) {
        self.scope = scope
        self.assayDisplayName = assayDisplayName
        self.definitionSet = definitionSet
        self.fileURL = fileURL
        self.isShadowed = isShadowed
    }
}

public struct HaplotypeDefinitionLibrary: Sendable {
    public let projectRoot: URL?
    public let globalRoot: URL

    public init(
        projectRoot: URL?,
        globalRoot: URL = HaplotypeDefinitionLibrary.defaultGlobalRoot()
    ) {
        self.projectRoot = projectRoot?.standardizedFileURL
        self.globalRoot = globalRoot.standardizedFileURL
    }

    public static func defaultGlobalRoot(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Lungfish Genome Explorer", isDirectory: true)
            .appendingPathComponent("Haplotype Definitions Library", isDirectory: true)
    }

    public func records() -> [HaplotypeDefinitionRecord] {
        let rawRecords = builtInRecords() + globalRecords() + projectRecords()
        let activeKeys = Set(
            Dictionary(grouping: rawRecords, by: definitionKey(_:))
                .compactMap { _, grouped in
                    grouped.max { lhs, rhs in
                        lhs.scope.precedence < rhs.scope.precedence
                    }?.id
                }
        )
        return rawRecords.map { record in
            HaplotypeDefinitionRecord(
                scope: record.scope,
                assayDisplayName: record.assayDisplayName,
                definitionSet: record.definitionSet,
                fileURL: record.fileURL,
                isShadowed: !activeKeys.contains(record.id)
            )
        }
        .sorted { lhs, rhs in
            let keys = [
                lhs.definitionSet.assayID.localizedStandardCompare(rhs.definitionSet.assayID),
                lhs.definitionSet.speciesName.localizedStandardCompare(rhs.definitionSet.speciesName),
                lhs.definitionSet.displayName.localizedStandardCompare(rhs.definitionSet.displayName),
                lhs.scope.rawValue.localizedStandardCompare(rhs.scope.rawValue),
            ]
            return keys.first { $0 != .orderedSame } == .orderedAscending
        }
    }

    public func activeRecords(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil
    ) -> [HaplotypeDefinitionRecord] {
        records().filter { record in
            guard !record.isShadowed else { return false }
            if let assayID, !assayID.isEmpty, record.definitionSet.assayID != assayID {
                return false
            }
            if let speciesCode = speciesCode?.trimmingCharacters(in: .whitespacesAndNewlines),
               !speciesCode.isEmpty,
               record.definitionSet.speciesCode.caseInsensitiveCompare(speciesCode) != .orderedSame {
                return false
            }
            if let scope, record.scope != scope {
                return false
            }
            return true
        }
    }

    public func mergedRegistry() -> GenotypeHaplotypeDefinitionRegistry {
        let active = activeRecords()
        let builtIn = GenotypeHaplotypeDefinitionRegistry.builtIn
        let assayNames = Dictionary(
            uniqueKeysWithValues: builtIn.assays.map { ($0.id, $0.displayName) }
        )
        let grouped = Dictionary(grouping: active.map(\.definitionSet), by: \.assayID)
        let assays = grouped.keys.sorted().map { assayID in
            GenotypeHaplotypeAssay(
                id: assayID,
                displayName: assayNames[assayID] ?? assayID,
                definitionSets: (grouped[assayID] ?? []).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
        return GenotypeHaplotypeDefinitionRegistry(
            assays: assays,
            defaultDefinitionSetID: builtIn.defaultDefinitionSetID
        )
    }

    public func store(for scope: HaplotypeDefinitionScope) -> HaplotypeDefinitionStore? {
        switch scope {
        case .builtIn:
            return nil
        case .global:
            return HaplotypeDefinitionStore(projectRoot: globalRoot)
        case .project:
            return HaplotypeDefinitionStore(projectRoot: projectRoot)
        }
    }

    public func record(
        definitionID: String,
        assayID: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeShadowed: Bool = false
    ) -> HaplotypeDefinitionRecord? {
        records().first { record in
            if !includeShadowed, record.isShadowed { return false }
            if record.definitionSet.id != definitionID { return false }
            if let assayID, record.definitionSet.assayID != assayID { return false }
            if let scope, record.scope != scope { return false }
            return true
        }
    }

    private func builtInRecords() -> [HaplotypeDefinitionRecord] {
        GenotypeHaplotypeDefinitionRegistry.builtIn.assays.flatMap { assay in
            assay.definitionSets.map { definitionSet in
                HaplotypeDefinitionRecord(
                    scope: .builtIn,
                    assayDisplayName: assay.displayName,
                    definitionSet: definitionSet,
                    fileURL: nil
                )
            }
        }
    }

    private func globalRecords() -> [HaplotypeDefinitionRecord] {
        storeRecords(scope: .global, root: globalRoot)
    }

    private func projectRecords() -> [HaplotypeDefinitionRecord] {
        guard let projectRoot else { return [] }
        return storeRecords(scope: .project, root: projectRoot)
    }

    private func storeRecords(scope: HaplotypeDefinitionScope, root: URL) -> [HaplotypeDefinitionRecord] {
        let store = HaplotypeDefinitionStore(projectRoot: root)
        return store.loadAllUserSets().map { definitionSet in
            HaplotypeDefinitionRecord(
                scope: scope,
                assayDisplayName: assayDisplayName(for: definitionSet.assayID),
                definitionSet: definitionSet,
                fileURL: store.definitionURL(for: definitionSet.id)
            )
        }
    }

    private func assayDisplayName(for assayID: String) -> String {
        GenotypeHaplotypeDefinitionRegistry.builtIn.assay(id: assayID)?.displayName ?? assayID
    }

    private func definitionKey(_ record: HaplotypeDefinitionRecord) -> String {
        "\(record.definitionSet.assayID)\u{1F}\(record.definitionSet.id)"
    }
}
