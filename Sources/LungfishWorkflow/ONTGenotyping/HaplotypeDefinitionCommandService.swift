import Foundation
import LungfishIO

public struct HaplotypeDefinitionCommandResult: Equatable, Sendable {
    public let scope: HaplotypeDefinitionScope
    public let definitionSet: GenotypeHaplotypeDefinitionSet
    public let definitionURL: URL

    public init(
        scope: HaplotypeDefinitionScope,
        definitionSet: GenotypeHaplotypeDefinitionSet,
        definitionURL: URL
    ) {
        self.scope = scope
        self.definitionSet = definitionSet
        self.definitionURL = definitionURL
    }
}

public struct HaplotypeDefinitionCommandService: Sendable {
    public let projectRoot: URL?
    public let globalRoot: URL

    public init(
        projectRoot: URL?,
        globalRoot: URL = HaplotypeDefinitionLibrary.defaultGlobalRoot()
    ) {
        self.projectRoot = projectRoot?.standardizedFileURL
        self.globalRoot = globalRoot.standardizedFileURL
    }

    public func listDefinitions(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeShadowed: Bool = false
    ) -> [HaplotypeDefinitionRecord] {
        library.records().filter { record in
            if !includeShadowed, record.isShadowed { return false }
            if let assayID = assayID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !assayID.isEmpty,
               record.definitionSet.assayID != assayID {
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

    @discardableResult
    public func validateDefinition(at inputURL: URL) throws -> GenotypeHaplotypeDefinitionSet {
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: inputURL.standardizedFileURL)
        )
        try validateDefinition(definition)
        return definition
    }

    public func validateDefinition(_ definition: GenotypeHaplotypeDefinitionSet) throws {
        var errors: [String] = []
        if definition.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Definition id is required.")
        }
        if definition.assayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Assay id is required.")
        }
        if definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Display name is required.")
        }
        if definition.speciesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Species name is required.")
        }
        if definition.speciesCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Species code is required.")
        }
        if definition.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Reference allele prefix is required.")
        }
        if definition.locusDefinitions.isEmpty {
            errors.append("At least one locus definition is required.")
        }
        for locus in definition.locusDefinitions {
            if locus.locus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Locus name is required.")
            }
            if locus.sourceLocus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Source locus is required for \(locus.locus).")
            }
            if locus.haplotypes.isEmpty {
                errors.append("At least one haplotype is required for \(locus.locus).")
            }
            for haplotype in locus.haplotypes {
                if haplotype.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("Haplotype name is required for \(locus.locus).")
                }
                if haplotype.diagnosticAlleles.isEmpty {
                    errors.append("At least one diagnostic allele is required for \(locus.locus) \(haplotype.name).")
                }
            }
        }
        if !errors.isEmpty {
            throw HaplotypeDefinitionCommandServiceError.validationFailed(errors)
        }
    }

    @discardableResult
    public func importDefinition(
        from inputURL: URL,
        scope: HaplotypeDefinitionScope,
        changeNote: String? = nil,
        argv: [String]
    ) throws -> HaplotypeDefinitionCommandResult {
        guard scope != .builtIn else {
            throw HaplotypeDefinitionCommandServiceError.cannotWriteBuiltIn
        }
        let inputURL = inputURL.standardizedFileURL
        let data = try Data(contentsOf: inputURL)
        let definition = try JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data)
        try validateDefinition(definition)
        let store = try writableStore(scope: scope)
        let inputRecord = try HaplotypeDefinitionStore.fileRecord(url: inputURL, role: "input")
        let context = provenanceContext(
            workflowName: "Haplotype definition import",
            argv: argv,
            scope: scope,
            definition: definition,
            explicitOptions: [
                "input": inputURL.path,
                "scope": scope.rawValue,
            ],
            inputFiles: [inputRecord]
        )
        try store.save(definition, changeNote: changeNote, provenanceContext: context)
        guard let definitionURL = store.definitionURL(for: definition.id) else {
            throw HaplotypeDefinitionCommandServiceError.missingDefinitionURL(definition.id)
        }
        return HaplotypeDefinitionCommandResult(
            scope: scope,
            definitionSet: definition,
            definitionURL: definitionURL
        )
    }

    public func exportDefinition(
        definitionID: String,
        assayID: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        to outputURL: URL,
        argv: [String]
    ) throws {
        let record = try definitionRecord(definitionID: definitionID, assayID: assayID, scope: scope)
        try validateDefinition(record.definitionSet)
        let outputURL = outputURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record.definitionSet).write(to: outputURL, options: .atomic)
        try writeExportProvenance(
            record: record,
            outputURL: outputURL,
            argv: argv
        )
    }

    @discardableResult
    public func saveDefinition(
        _ definition: GenotypeHaplotypeDefinitionSet,
        scope: HaplotypeDefinitionScope,
        changeNote: String? = nil,
        argv: [String]
    ) throws -> HaplotypeDefinitionCommandResult {
        guard scope != .builtIn else {
            throw HaplotypeDefinitionCommandServiceError.cannotWriteBuiltIn
        }
        try validateDefinition(definition)
        let store = try writableStore(scope: scope)
        let context = provenanceContext(
            workflowName: "Haplotype definition edit",
            argv: argv,
            scope: scope,
            definition: definition,
            explicitOptions: [
                "scope": scope.rawValue,
            ]
        )
        try store.save(definition, changeNote: changeNote, provenanceContext: context)
        guard let definitionURL = store.definitionURL(for: definition.id) else {
            throw HaplotypeDefinitionCommandServiceError.missingDefinitionURL(definition.id)
        }
        return HaplotypeDefinitionCommandResult(
            scope: scope,
            definitionSet: definition,
            definitionURL: definitionURL
        )
    }

    @discardableResult
    public func duplicateDefinition(
        definitionID: String,
        assayID: String? = nil,
        fromScope: HaplotypeDefinitionScope? = nil,
        toScope: HaplotypeDefinitionScope,
        newDefinitionID: String? = nil,
        changeNote: String? = nil,
        argv: [String]
    ) throws -> HaplotypeDefinitionCommandResult {
        guard toScope != .builtIn else {
            throw HaplotypeDefinitionCommandServiceError.cannotWriteBuiltIn
        }
        let source = try definitionRecord(
            definitionID: definitionID,
            assayID: assayID,
            scope: fromScope,
            includeShadowed: true
        )
        let targetID = newDefinitionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let copied = GenotypeHaplotypeDefinitionSet(
            id: targetID?.isEmpty == false ? targetID! : source.definitionSet.id,
            assayID: source.definitionSet.assayID,
            displayName: source.definitionSet.displayName,
            speciesName: source.definitionSet.speciesName,
            speciesCode: source.definitionSet.speciesCode,
            prefix: source.definitionSet.prefix,
            locusDefinitions: source.definitionSet.locusDefinitions,
            schemaVersion: source.definitionSet.schemaVersion,
            lastModified: source.definitionSet.lastModified,
            changeNote: changeNote ?? source.definitionSet.changeNote
        )
        try validateDefinition(copied)
        let store = try writableStore(scope: toScope)
        let context = provenanceContext(
            workflowName: "Haplotype definition duplicate",
            argv: argv,
            scope: toScope,
            definition: copied,
            explicitOptions: [
                "sourceScope": source.scope.rawValue,
                "sourceDefinitionID": source.definitionSet.id,
                "targetScope": toScope.rawValue,
                "targetDefinitionID": copied.id,
            ],
            inputFiles: try source.fileURL.map { [try HaplotypeDefinitionStore.fileRecord(url: $0, role: "input")] } ?? []
        )
        try store.save(copied, changeNote: changeNote, provenanceContext: context)
        guard let definitionURL = store.definitionURL(for: copied.id) else {
            throw HaplotypeDefinitionCommandServiceError.missingDefinitionURL(copied.id)
        }
        return HaplotypeDefinitionCommandResult(
            scope: toScope,
            definitionSet: copied,
            definitionURL: definitionURL
        )
    }

    public func deleteDefinition(
        definitionID: String,
        scope: HaplotypeDefinitionScope,
        argv: [String]
    ) throws {
        guard scope != .builtIn else {
            throw HaplotypeDefinitionCommandServiceError.cannotWriteBuiltIn
        }
        let store = try writableStore(scope: scope)
        let context = HaplotypeDefinitionProvenanceContext(
            workflowName: "Haplotype definition delete",
            argv: argv,
            explicitOptions: [
                "definitionID": definitionID,
                "scope": scope.rawValue,
            ],
            resolvedDefaults: resolvedDefaults(scope: scope)
        )
        try store.delete(id: definitionID, provenanceContext: context)
    }

    private var library: HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: projectRoot, globalRoot: globalRoot)
    }

    private func writableStore(scope: HaplotypeDefinitionScope) throws -> HaplotypeDefinitionStore {
        guard let store = library.store(for: scope) else {
            throw HaplotypeDefinitionCommandServiceError.cannotWriteBuiltIn
        }
        return store
    }

    private func definitionRecord(
        definitionID: String,
        assayID: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeShadowed: Bool = false
    ) throws -> HaplotypeDefinitionRecord {
        guard let record = library.record(
            definitionID: definitionID,
            assayID: assayID,
            scope: scope,
            includeShadowed: includeShadowed
        ) else {
            throw HaplotypeDefinitionCommandServiceError.definitionNotFound(definitionID)
        }
        return record
    }

    private func provenanceContext(
        workflowName: String,
        argv: [String],
        scope: HaplotypeDefinitionScope,
        definition: GenotypeHaplotypeDefinitionSet,
        explicitOptions: [String: String] = [:],
        inputFiles: [HaplotypeDefinitionEditProvenance.FileRecord] = []
    ) -> HaplotypeDefinitionProvenanceContext {
        var explicit = [
            "definitionID": definition.id,
            "assayID": definition.assayID,
            "speciesCode": definition.speciesCode,
            "scope": scope.rawValue,
        ]
        explicit.merge(explicitOptions) { _, new in new }
        return HaplotypeDefinitionProvenanceContext(
            workflowName: workflowName,
            argv: argv,
            explicitOptions: explicit,
            resolvedDefaults: resolvedDefaults(scope: scope),
            inputFiles: inputFiles
        )
    }

    private func resolvedDefaults(scope: HaplotypeDefinitionScope) -> [String: String] {
        [
            "projectRoot": projectRoot?.path ?? "",
            "globalRoot": globalRoot.path,
            "scope": scope.rawValue,
        ]
    }

    private func writeExportProvenance(
        record: HaplotypeDefinitionRecord,
        outputURL: URL,
        argv: [String]
    ) throws {
        let startedAt = Date()
        let inputFiles: [HaplotypeDefinitionEditProvenance.FileRecord]
        if let fileURL = record.fileURL {
            inputFiles = [try HaplotypeDefinitionStore.fileRecord(url: fileURL, role: "input")]
        } else {
            inputFiles = []
        }
        let endedAt = Date()
        let provenance = HaplotypeDefinitionEditProvenance(
            workflowName: "Haplotype definition export",
            workflowVersion: HaplotypeDefinitionStore.currentToolVersion,
            toolName: "lungfish-cli",
            toolVersion: HaplotypeDefinitionStore.currentToolVersion,
            argv: argv,
            reproducibleCommand: HaplotypeDefinitionStore.shellCommand(argv),
            options: .init(
                explicit: [
                    "definitionID": record.definitionSet.id,
                    "assayID": record.definitionSet.assayID,
                    "speciesCode": record.definitionSet.speciesCode,
                    "scope": record.scope.rawValue,
                    "output": outputURL.path,
                ],
                resolvedDefaults: resolvedDefaults(scope: record.scope)
            ),
            runtime: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                user: NSUserName().isEmpty ? nil : NSUserName()
            ),
            inputs: inputFiles,
            outputs: [try HaplotypeDefinitionStore.fileRecord(url: outputURL, role: "output")],
            exitStatus: 0,
            startedAt: HaplotypeDefinitionStore.isoString(startedAt),
            endedAt: HaplotypeDefinitionStore.isoString(endedAt),
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            stderr: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance)
            .write(to: outputURL.appendingPathExtension("provenance.json"), options: .atomic)
    }
}

public enum HaplotypeDefinitionCommandServiceError: Error, LocalizedError, Equatable {
    case cannotWriteBuiltIn
    case definitionNotFound(String)
    case missingDefinitionURL(String)
    case validationFailed([String])

    public var errorDescription: String? {
        switch self {
        case .cannotWriteBuiltIn:
            return "Built-in haplotype definitions cannot be modified. Duplicate them to the project or global library first."
        case .definitionNotFound(let id):
            return "Haplotype definition not found: \(id)"
        case .missingDefinitionURL(let id):
            return "Could not resolve stored haplotype definition URL for \(id)."
        case .validationFailed(let errors):
            return "Invalid haplotype definition:\n" + errors.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}
