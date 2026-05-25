import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct HaplotypeDefinitionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "haplotypes",
        abstract: "Manage ONT genotyping haplotype definition sets",
        discussion: """
            Import, export, list, duplicate, and delete haplotype definition sets
            before running ONT genotyping workflows. Project definitions override
            global definitions, and global definitions override built-in definitions
            with the same assay and definition id.
            """,
        subcommands: [
            HaplotypeDefinitionsListSubcommand.self,
            HaplotypeDefinitionsValidateSubcommand.self,
            HaplotypeDefinitionsImportSubcommand.self,
            HaplotypeDefinitionsSaveSubcommand.self,
            HaplotypeDefinitionsExportSubcommand.self,
            HaplotypeDefinitionsDuplicateSubcommand.self,
            HaplotypeDefinitionsDeleteSubcommand.self,
        ]
    )
}

struct HaplotypeDefinitionsListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List haplotype definition sets"
    )

    @Option(name: .customLong("project"), help: "Project root whose project-scoped definitions should be included")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    @Option(name: .customLong("assay"), help: "Filter to an assay/amplicon id")
    var assay: String?

    @Option(name: .customLong("species"), help: "Filter to a species code, such as MCM or MAMU")
    var species: String?

    @Option(name: .customLong("scope"), help: "Filter to all, built-in, global, or project")
    var scope: String?

    @Flag(name: .customLong("include-shadowed"), help: "Include definitions overridden by a higher-precedence scope")
    var includeShadowed = false

    func run() async throws {
        let service = makeService(project: project, globalRoot: globalRoot)
        let records = service.listDefinitions(
            assayID: assay,
            speciesCode: species,
            scope: try parseOptionalScope(scope),
            includeShadowed: includeShadowed
        )
        try emitJSON(records.map(HaplotypeDefinitionListPayload.init(record:)))
    }
}

struct HaplotypeDefinitionsValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a haplotype definition JSON file"
    )

    @Argument(help: "Definition JSON file to validate")
    var input: String

    func run() async throws {
        let service = HaplotypeDefinitionCommandService(projectRoot: nil)
        let definition = try service.validateDefinition(at: URL(fileURLWithPath: input))
        try emitJSON(HaplotypeDefinitionValidatePayload(definition: definition))
    }
}

struct HaplotypeDefinitionsImportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a haplotype definition JSON file"
    )

    @Argument(help: "Definition JSON file to import")
    var input: String

    @Option(name: .customLong("scope"), help: "Destination scope: global or project")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this import")
    var changeNote: String?

    func run() async throws {
        let service = makeService(project: project, globalRoot: globalRoot)
        let result = try service.importDefinition(
            from: URL(fileURLWithPath: input),
            scope: try parseRequiredScope(scope),
            changeNote: changeNote,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionWritePayload(result: result))
    }
}

struct HaplotypeDefinitionsSaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save or update a writable haplotype definition from a JSON file"
    )

    @Argument(help: "Definition JSON file to save")
    var input: String

    @Option(name: .customLong("scope"), help: "Destination scope: global or project")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this edit")
    var changeNote: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: inputURL)
        )
        let service = makeService(project: project, globalRoot: globalRoot)
        let result = try service.saveDefinition(
            definition,
            scope: try parseRequiredScope(scope),
            changeNote: changeNote,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionWritePayload(result: result))
    }
}

struct HaplotypeDefinitionsExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a haplotype definition set to a JSON file"
    )

    @Argument(help: "Definition set id to export")
    var definitionID: String

    @Option(name: .customLong("output"), help: "Destination JSON path")
    var output: String

    @Option(name: .customLong("project"), help: "Project root whose project-scoped definitions should be included")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    @Option(name: .customLong("assay"), help: "Assay/amplicon id used to disambiguate duplicate definition ids")
    var assay: String?

    @Option(name: .customLong("scope"), help: "Definition scope to export: built-in, global, or project")
    var scope: String?

    func run() async throws {
        let service = makeService(project: project, globalRoot: globalRoot)
        try service.exportDefinition(
            definitionID: definitionID,
            assayID: assay,
            scope: try parseOptionalScope(scope),
            to: URL(fileURLWithPath: output),
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(["output": URL(fileURLWithPath: output).standardizedFileURL.path])
    }
}

struct HaplotypeDefinitionsDuplicateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Duplicate a built-in/global/project definition into a writable scope"
    )

    @Argument(help: "Definition set id to duplicate")
    var definitionID: String

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    @Option(name: .customLong("assay"), help: "Assay/amplicon id used to disambiguate duplicate definition ids")
    var assay: String?

    @Option(name: .customLong("source-scope"), help: "Optional source scope: built-in, global, or project")
    var sourceScope: String?

    @Option(name: .customLong("target-scope"), help: "Destination scope: global or project")
    var targetScope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("new-definition-id"), help: "Optional id for the duplicate; omit to override/shadow the source id")
    var newDefinitionID: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this duplication")
    var changeNote: String?

    func run() async throws {
        let service = makeService(project: project, globalRoot: globalRoot)
        let result = try service.duplicateDefinition(
            definitionID: definitionID,
            assayID: assay,
            fromScope: try parseOptionalScope(sourceScope),
            toScope: try parseRequiredScope(targetScope),
            newDefinitionID: newDefinitionID,
            changeNote: changeNote,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionWritePayload(result: result))
    }
}

struct HaplotypeDefinitionsDeleteSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a global or project haplotype definition set"
    )

    @Argument(help: "Definition set id to delete")
    var definitionID: String

    @Option(name: .customLong("scope"), help: "Definition scope to delete: global or project")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("global-root"), help: "Global haplotype definition library root")
    var globalRoot: String?

    func run() async throws {
        let service = makeService(project: project, globalRoot: globalRoot)
        try service.deleteDefinition(
            definitionID: definitionID,
            scope: try parseRequiredScope(scope),
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(["deleted": definitionID, "scope": scope])
    }
}

private struct HaplotypeDefinitionListPayload: Encodable {
    let scope: String
    let assayID: String
    let assayDisplayName: String
    let definitionID: String
    let displayName: String
    let speciesName: String
    let speciesCode: String
    let filePath: String?
    let isShadowed: Bool

    init(record: HaplotypeDefinitionRecord) {
        self.scope = record.scope.rawValue
        self.assayID = record.definitionSet.assayID
        self.assayDisplayName = record.assayDisplayName
        self.definitionID = record.definitionSet.id
        self.displayName = record.definitionSet.displayName
        self.speciesName = record.definitionSet.speciesName
        self.speciesCode = record.definitionSet.speciesCode
        self.filePath = record.fileURL?.path
        self.isShadowed = record.isShadowed
    }
}

private struct HaplotypeDefinitionWritePayload: Encodable {
    let scope: String
    let definitionID: String
    let assayID: String
    let displayName: String
    let speciesCode: String
    let definitionPath: String

    init(result: HaplotypeDefinitionCommandResult) {
        self.scope = result.scope.rawValue
        self.definitionID = result.definitionSet.id
        self.assayID = result.definitionSet.assayID
        self.displayName = result.definitionSet.displayName
        self.speciesCode = result.definitionSet.speciesCode
        self.definitionPath = result.definitionURL.path
    }
}

private struct HaplotypeDefinitionValidatePayload: Encodable {
    let valid: Bool
    let definitionID: String
    let assayID: String
    let displayName: String
    let speciesCode: String

    init(definition: GenotypeHaplotypeDefinitionSet) {
        self.valid = true
        self.definitionID = definition.id
        self.assayID = definition.assayID
        self.displayName = definition.displayName
        self.speciesCode = definition.speciesCode
    }
}

private func makeService(project: String?, globalRoot: String?) -> HaplotypeDefinitionCommandService {
    HaplotypeDefinitionCommandService(
        projectRoot: project.map { URL(fileURLWithPath: $0, isDirectory: true) },
        globalRoot: globalRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? HaplotypeDefinitionLibrary.defaultGlobalRoot()
    )
}

private func parseOptionalScope(_ rawValue: String?) throws -> HaplotypeDefinitionScope? {
    guard let rawValue else { return nil }
    if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "all" {
        return nil
    }
    return try parseScope(rawValue)
}

private func parseRequiredScope(_ rawValue: String) throws -> HaplotypeDefinitionScope {
    try parseScope(rawValue)
}

private func parseScope(_ rawValue: String) throws -> HaplotypeDefinitionScope {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "builtin" {
        return .builtIn
    }
    guard let scope = HaplotypeDefinitionScope(rawValue: normalized) else {
        throw ValidationError("Unknown haplotype definition scope '\(rawValue)'. Use all, built-in, global, or project.")
    }
    return scope
}

private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
