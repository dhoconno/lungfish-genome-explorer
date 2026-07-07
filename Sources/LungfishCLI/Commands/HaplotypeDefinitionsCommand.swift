import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct HaplotypeDefinitionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "haplotypes",
        abstract: "Manage ONT genotyping haplotype definition sets",
        discussion: """
            Import, export, list, duplicate, and delete project haplotype definition
            sets before running ONT genotyping workflows. Definitions may be stored
            as project JSON definition files or embedded in project .lungfishmhcref
            reference bundles.
            """,
        subcommands: [
            HaplotypeDefinitionsListSubcommand.self,
            HaplotypeDefinitionsValidateSubcommand.self,
            HaplotypeDefinitionsImportSubcommand.self,
            HaplotypeDefinitionsSaveSubcommand.self,
            HaplotypeDefinitionsBundleInstallSubcommand.self,
            HaplotypeDefinitionsBundleCreateSubcommand.self,
            HaplotypeDefinitionsBundleSaveSubcommand.self,
            HaplotypeDefinitionsBundleReplaceReferenceSubcommand.self,
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

    @Option(name: .customLong("assay"), help: "Filter to an assay/amplicon id")
    var assay: String?

    @Option(name: .customLong("species"), help: "Filter to a species code, such as MCM or MAMU")
    var species: String?

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String?

    @Flag(name: .customLong("include-shadowed"), help: "Include definitions overridden by a higher-precedence scope")
    var includeShadowed = false

    @Flag(name: .customLong("include-reference-bundles"), help: "Include haplotype definitions embedded in project .lungfishmhcref bundles")
    var includeReferenceBundles = false

    func run() async throws {
        let service = makeService(project: project)
        let records = service.listDefinitions(
            assayID: assay,
            speciesCode: species,
            scope: try parseOptionalScope(scope),
            includeShadowed: includeShadowed,
            includeReferenceBundles: includeReferenceBundles
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

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this import")
    var changeNote: String?

    func run() async throws {
        let service = makeService(project: project)
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

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this edit")
    var changeNote: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: inputURL)
        )
        let service = makeService(project: project)
        let result = try service.saveDefinition(
            definition,
            scope: try parseRequiredScope(scope),
            changeNote: changeNote,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionWritePayload(result: result))
    }
}

struct HaplotypeDefinitionsBundleInstallSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-install",
        abstract: "Install an existing .lungfishmhcref bundle into a project"
    )

    @Argument(help: "Source .lungfishmhcref bundle to install")
    var source: String

    @Option(name: .customLong("project"), help: "Project root that will receive the bundle")
    var project: String

    func run() async throws {
        let service = makeService(project: project)
        let installedURL = try service.installMHCReferenceBundle(
            from: URL(fileURLWithPath: source, isDirectory: true),
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionBundleInstallPayload(bundleURL: installedURL))
    }
}

struct HaplotypeDefinitionsBundleCreateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-create",
        abstract: "Create an MHC reference bundle from managed haplotype definitions and a reference FASTA"
    )

    @Option(name: .customLong("definition"), help: "Managed haplotype definition id to embed")
    var definitions: [String] = []

    @Option(name: .customLong("assay"), help: "Assay/amplicon id used to disambiguate definition ids")
    var assay: String?

    @Option(name: .customLong("species"), help: "Species code used to disambiguate definition ids")
    var species: String?

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String?

    @Option(name: .customLong("reference-fasta"), help: "MHC amplicon reference FASTA to embed")
    var referenceFASTA: String

    @Option(name: .customLong("output"), help: "Output .lungfishmhcref bundle")
    var output: String

    @Option(name: .customLong("name"), help: "Display name stored in the bundle manifest")
    var name: String?

    @Option(name: .customLong("default-definition"), help: "Default embedded haplotype definition set ID")
    var defaultDefinition: String?

    @Option(name: .customLong("project"), help: "Project root whose project-scoped definitions should be included")
    var project: String?

    @Flag(name: .customLong("force"), help: "Replace an existing .lungfishmhcref bundle")
    var force = false

    func run() async throws {
        let service = makeService(project: project)
        let result = try await service.createMHCReferenceBundle(
            definitionIDs: definitions,
            assayID: assay,
            speciesCode: species,
            scope: try parseOptionalScope(scope),
            referenceFASTA: URL(fileURLWithPath: referenceFASTA),
            outputURL: URL(fileURLWithPath: output, isDirectory: true),
            name: name,
            defaultDefinitionID: defaultDefinition,
            forceOverwrite: force,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionBundleCreatePayload(result: result))
    }
}

struct HaplotypeDefinitionsBundleSaveSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-save",
        abstract: "Save or update a haplotype definition embedded in an MHC reference bundle"
    )

    @Argument(help: "Definition JSON file to save into the bundle")
    var input: String

    @Option(name: .customLong("bundle"), help: "Destination .lungfishmhcref bundle")
    var bundle: String

    @Option(name: .customLong("project"), help: "Project root used for provenance context")
    var project: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this edit")
    var changeNote: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let definition = try JSONDecoder().decode(
            GenotypeHaplotypeDefinitionSet.self,
            from: Data(contentsOf: inputURL)
        )
        let service = makeService(project: project)
        let result = try service.saveDefinition(
            definition,
            inMHCReferenceBundle: URL(fileURLWithPath: bundle, isDirectory: true),
            changeNote: changeNote,
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(HaplotypeDefinitionWritePayload(result: result))
    }
}

struct HaplotypeDefinitionsBundleReplaceReferenceSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-replace-reference",
        abstract: "Replace the reference FASTA embedded in an MHC reference bundle"
    )

    @Argument(help: "Replacement reference FASTA")
    var referenceFASTA: String

    @Option(name: .customLong("bundle"), help: "Destination .lungfishmhcref bundle")
    var bundle: String

    @Option(name: .customLong("project"), help: "Project root used for provenance context")
    var project: String?

    func run() async throws {
        let service = makeService(project: project)
        let referenceURL = try service.replaceReferenceFASTA(
            inMHCReferenceBundle: URL(fileURLWithPath: bundle, isDirectory: true),
            with: URL(fileURLWithPath: referenceFASTA),
            argv: Array(CommandLine.arguments)
        )
        try emitJSON(["referencePath": referenceURL.path])
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

    @Option(name: .customLong("assay"), help: "Assay/amplicon id used to disambiguate duplicate definition ids")
    var assay: String?

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String?

    func run() async throws {
        let service = makeService(project: project)
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
        abstract: "Duplicate a project definition into the project scope"
    )

    @Argument(help: "Definition set id to duplicate")
    var definitionID: String

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    @Option(name: .customLong("assay"), help: "Assay/amplicon id used to disambiguate duplicate definition ids")
    var assay: String?

    @Option(name: .customLong("source-scope"), help: "project (the only supported scope)")
    var sourceScope: String?

    @Option(name: .customLong("target-scope"), help: "project (the only supported scope)")
    var targetScope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("new-definition-id"), help: "Optional id for the duplicate; omit to override/shadow the source id")
    var newDefinitionID: String?

    @Option(name: .customLong("change-note"), help: "Human-readable provenance note for this duplication")
    var changeNote: String?

    func run() async throws {
        let service = makeService(project: project)
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
        abstract: "Delete a project haplotype definition set"
    )

    @Argument(help: "Definition set id to delete")
    var definitionID: String

    @Option(name: .customLong("scope"), help: "project (the only supported scope)")
    var scope: String = HaplotypeDefinitionScope.project.rawValue

    @Option(name: .customLong("project"), help: "Project root for project-scoped definitions")
    var project: String?

    func run() async throws {
        let service = makeService(project: project)
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
    let source: String
    let assayID: String
    let assayDisplayName: String
    let definitionID: String
    let displayName: String
    let speciesName: String
    let speciesCode: String
    let filePath: String?
    let referenceBundlePath: String?
    let referenceFASTAPath: String?
    let isShadowed: Bool

    init(record: HaplotypeDefinitionRecord) {
        self.scope = record.scope.rawValue
        self.source = record.sourceDisplayName
        self.assayID = record.definitionSet.assayID
        self.assayDisplayName = record.assayDisplayName
        self.definitionID = record.definitionSet.id
        self.displayName = record.definitionSet.displayName
        self.speciesName = record.definitionSet.speciesName
        self.speciesCode = record.definitionSet.speciesCode
        self.filePath = record.fileURL?.path
        self.referenceBundlePath = record.referenceBundleURL?.path
        self.referenceFASTAPath = record.referenceFASTAURL?.path
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

private struct HaplotypeDefinitionBundleCreatePayload: Encodable {
    let bundlePath: String
    let provenancePath: String

    init(result: MHCAmpliconReferenceBundleBuildResult) {
        self.bundlePath = result.bundleURL.path
        self.provenancePath = result.provenanceURL.path
    }
}

private struct HaplotypeDefinitionBundleInstallPayload: Encodable {
    let bundlePath: String
    let provenancePath: String

    init(bundleURL: URL) {
        self.bundlePath = bundleURL.path
        self.provenancePath = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
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

private func makeService(project: String?) -> HaplotypeDefinitionCommandService {
    HaplotypeDefinitionCommandService(
        projectRoot: project.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
}

private func parseOptionalScope(_ rawValue: String?) throws -> HaplotypeDefinitionScope? {
    guard let rawValue else { return nil }
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty {
        return nil
    }
    return try parseScope(normalized)
}

private func parseRequiredScope(_ rawValue: String) throws -> HaplotypeDefinitionScope {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty {
        return .project
    }
    return try parseScope(normalized)
}

private func parseScope(_ normalized: String) throws -> HaplotypeDefinitionScope {
    guard normalized == HaplotypeDefinitionScope.project.rawValue else {
        throw ValidationError("Only the 'project' scope is supported")
    }
    return .project
}

private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
