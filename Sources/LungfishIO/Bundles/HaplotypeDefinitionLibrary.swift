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
    public let referenceBundleURL: URL?
    public let referenceFASTAURL: URL?

    public var id: String {
        if let referenceBundleURL {
            return "mhc-reference-bundle:\(referenceBundleURL.path):\(definitionSet.assayID):\(definitionSet.id)"
        }
        return "\(scope.rawValue):\(definitionSet.assayID):\(definitionSet.id)"
    }

    public var sourceDisplayName: String {
        referenceBundleURL == nil ? scope.displayName : "MHC Reference Bundle"
    }

    public init(
        scope: HaplotypeDefinitionScope,
        assayDisplayName: String,
        definitionSet: GenotypeHaplotypeDefinitionSet,
        fileURL: URL?,
        isShadowed: Bool = false,
        referenceBundleURL: URL? = nil,
        referenceFASTAURL: URL? = nil
    ) {
        self.scope = scope
        self.assayDisplayName = assayDisplayName
        self.definitionSet = definitionSet
        self.fileURL = fileURL
        self.isShadowed = isShadowed
        self.referenceBundleURL = referenceBundleURL?.standardizedFileURL
        self.referenceFASTAURL = referenceFASTAURL?.standardizedFileURL
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

    public func records(includeReferenceBundles: Bool = false) -> [HaplotypeDefinitionRecord] {
        let rawRecords = builtInRecords()
            + globalRecords()
            + projectRecords()
            + (includeReferenceBundles ? projectMHCReferenceBundleRecords() : [])
        let activeKeys = Set(
            Dictionary(grouping: rawRecords.filter { $0.referenceBundleURL == nil }, by: definitionKey(_:))
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
                isShadowed: record.referenceBundleURL == nil && !activeKeys.contains(record.id),
                referenceBundleURL: record.referenceBundleURL,
                referenceFASTAURL: record.referenceFASTAURL
            )
        }
        .sorted { lhs, rhs in
            let keys = [
                lhs.definitionSet.assayID.localizedStandardCompare(rhs.definitionSet.assayID),
                lhs.definitionSet.speciesName.localizedStandardCompare(rhs.definitionSet.speciesName),
                lhs.definitionSet.displayName.localizedStandardCompare(rhs.definitionSet.displayName),
                lhs.sourceDisplayName.localizedStandardCompare(rhs.sourceDisplayName),
            ]
            return keys.first { $0 != .orderedSame } == .orderedAscending
        }
    }

    public func activeRecords(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeReferenceBundles: Bool = false
    ) -> [HaplotypeDefinitionRecord] {
        records(includeReferenceBundles: includeReferenceBundles).filter { record in
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

    public func mergedRegistry(includeReferenceBundles: Bool = false) -> GenotypeHaplotypeDefinitionRegistry {
        let active = activeRecords(includeReferenceBundles: includeReferenceBundles)
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

    private func projectMHCReferenceBundleRecords() -> [HaplotypeDefinitionRecord] {
        guard let projectRoot else { return [] }
        let fileManager = FileManager.default
        var bundleURLs: [URL] = []
        if MHCAmpliconReferenceBundle.isBundleURL(projectRoot) {
            bundleURLs.append(projectRoot.standardizedFileURL)
        }
        if let enumerator = fileManager.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if MHCAmpliconReferenceBundle.isBundleURL(url) {
                    bundleURLs.append(url.standardizedFileURL)
                    enumerator.skipDescendants()
                }
            }
        }
        return bundleURLs.flatMap { bundleURL -> [HaplotypeDefinitionRecord] in
            let definitionURLs = MHCAmpliconReferenceBundle.haplotypeDefinitionURLs(in: bundleURL)
            let referenceURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL)
            return definitionURLs.compactMap { definitionURL in
                guard let data = try? Data(contentsOf: definitionURL),
                      let definitionSet = try? JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data) else {
                    return nil
                }
                return HaplotypeDefinitionRecord(
                    scope: .project,
                    assayDisplayName: assayDisplayName(for: definitionSet.assayID),
                    definitionSet: definitionSet,
                    fileURL: definitionURL,
                    isShadowed: false,
                    referenceBundleURL: bundleURL,
                    referenceFASTAURL: referenceURL
                )
            }
        }
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
