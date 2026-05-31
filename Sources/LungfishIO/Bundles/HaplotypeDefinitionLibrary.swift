import Foundation

public enum HaplotypeDefinitionScope: String, Codable, CaseIterable, Sendable {
    case project

    public var displayName: String { "Project" }

    public var precedence: Int { 0 }
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

    public init(projectRoot: URL?) {
        self.projectRoot = projectRoot?.standardizedFileURL
    }

    /// All haplotype definitions visible to this project. Every definition
    /// is now sourced from a project-scoped `.lungfishmhcref` bundle, so the
    /// returned records always carry `referenceBundleURL`/`referenceFASTAURL`.
    /// `includeReferenceBundles` is retained for source-compatibility but is
    /// effectively always on — bundle records are the sole source.
    public func records(includeReferenceBundles: Bool = true) -> [HaplotypeDefinitionRecord] {
        _ = includeReferenceBundles
        return projectMHCReferenceBundleRecords()
            .sorted { lhs, rhs in
                lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    public func activeRecords(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeReferenceBundles: Bool = true
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

    public func mergedRegistry(includeReferenceBundles: Bool = true) -> GenotypeHaplotypeDefinitionRegistry {
        let active = activeRecords(includeReferenceBundles: includeReferenceBundles)
        let grouped = Dictionary(grouping: active.map(\.definitionSet), by: \.assayID)
        let assays = grouped.keys.sorted().map { assayID in
            GenotypeHaplotypeAssay(
                id: assayID,
                displayName: assayDisplayName(for: assayID),
                definitionSets: (grouped[assayID] ?? []).sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            )
        }
        return GenotypeHaplotypeDefinitionRegistry(
            assays: assays,
            defaultDefinitionSetID: nil
        )
    }

    public func store(for scope: HaplotypeDefinitionScope) -> HaplotypeDefinitionStore? {
        switch scope {
        case .project:
            guard let projectRoot else { return nil }
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

    private func assayDisplayName(for assayID: String) -> String {
        assayID
    }
}
