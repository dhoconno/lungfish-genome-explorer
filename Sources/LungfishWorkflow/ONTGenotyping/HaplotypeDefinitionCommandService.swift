import CryptoKit
import Foundation
import LungfishCore
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

    public init(projectRoot: URL?) {
        self.projectRoot = projectRoot?.standardizedFileURL
    }

    public func listDefinitions(
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeShadowed: Bool = false,
        includeReferenceBundles: Bool = false
    ) -> [HaplotypeDefinitionRecord] {
        // CLI listing includes bare project-store defs AND bundle defs so that
        // freshly-imported/saved defs are visible for `bundle-create`, `export`,
        // `duplicate`, and `delete`. (The GUI uses `library.records()`, which is
        // bundle-only.) `includeReferenceBundles` is retained for source-compat.
        _ = includeReferenceBundles
        return library.allManagedRecords(
            assayID: assayID,
            speciesCode: speciesCode,
            scope: scope
        ).filter { record in
            includeShadowed || !record.isShadowed
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
        try canonicalizeProjectDefinitionProvenance(for: definitionURL)
        return HaplotypeDefinitionCommandResult(
            scope: scope,
            definitionSet: definition,
            definitionURL: definitionURL
        )
    }

    /// Installs an existing `.lungfishmhcref` bundle into the project by copying
    /// the whole directory into `<projectRoot>/Reference allele databases/` (the
    /// same location used by manager-created bundles), so it is immediately
    /// discoverable by `HaplotypeDefinitionLibrary.records()`.
    ///
    /// The install writes new provenance for the final stored project payload.
    /// If a bundle of the same name already exists in the destination directory,
    /// the name is disambiguated (` 2`, ` 3`, …) rather than overwriting. Returns
    /// the destination bundle URL.
    @discardableResult
    public func installMHCReferenceBundle(
        from sourceURL: URL,
        argv: [String]
    ) throws -> URL {
        let startedAt = Date()
        guard let projectRoot else {
            throw HaplotypeDefinitionCommandServiceError.missingProjectRoot
        }
        let sourceURL = sourceURL.standardizedFileURL
        guard MHCAmpliconReferenceBundle.isBundleURL(sourceURL) else {
            throw HaplotypeDefinitionCommandServiceError.invalidMHCReferenceBundle(sourceURL.path)
        }
        try MHCAmpliconReferenceBundle.validate(at: sourceURL)

        let destinationDirectory = projectRoot
            .appendingPathComponent("Reference allele databases", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        // If the source already lives at its disambiguated destination, leave it
        // in place rather than copying onto itself.
        let preferredDestination = destinationDirectory
            .appendingPathComponent(sourceURL.lastPathComponent)
            .standardizedFileURL
        if preferredDestination == sourceURL {
            return sourceURL
        }

        let destinationURL = disambiguatedBundleDestination(
            in: destinationDirectory,
            named: sourceURL.lastPathComponent
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        do {
            try writeMHCReferenceBundleInstallProvenance(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                destinationDirectory: destinationDirectory,
                argv: argv,
                startedAt: startedAt
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL.standardizedFileURL
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
        try canonicalizeProjectDefinitionProvenance(for: outputURL)
    }

    @discardableResult
    public func saveDefinition(
        _ definition: GenotypeHaplotypeDefinitionSet,
        scope: HaplotypeDefinitionScope,
        changeNote: String? = nil,
        argv: [String]
    ) throws -> HaplotypeDefinitionCommandResult {
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
        try canonicalizeProjectDefinitionProvenance(for: definitionURL)
        return HaplotypeDefinitionCommandResult(
            scope: scope,
            definitionSet: definition,
            definitionURL: definitionURL
        )
    }

    @discardableResult
    public func saveDefinition(
        _ definition: GenotypeHaplotypeDefinitionSet,
        inMHCReferenceBundle bundleURL: URL,
        changeNote: String? = nil,
        argv: [String]
    ) throws -> HaplotypeDefinitionCommandResult {
        let startedAt = Date()
        let bundleURL = bundleURL.standardizedFileURL
        guard MHCAmpliconReferenceBundle.isBundleURL(bundleURL) else {
            throw HaplotypeDefinitionCommandServiceError.invalidMHCReferenceBundle(bundleURL.path)
        }
        try validateDefinition(definition)
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        let manifestURL = MHCAmpliconReferenceBundle.manifestURL(in: bundleURL)
        guard let referenceURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL) else {
            throw HaplotypeDefinitionCommandServiceError.missingMHCReferenceBundleReference(manifest.referenceFastaPath)
        }
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw HaplotypeDefinitionCommandServiceError.missingMHCReferenceBundleReference(referenceURL.path)
        }
        try MHCAmpliconReferenceBundle.validate(at: bundleURL)

        let existingPath = try existingDefinitionRelativePath(
            definitionID: definition.id,
            manifest: manifest,
            bundleURL: bundleURL
        )
        let relativePath = existingPath ?? "haplotypes/\(safeFileName(definition.id)).lungfishhaplotypedef.json"
        let definitionURL = bundleURL.appendingPathComponent(relativePath).standardizedFileURL
        let priorDefinitionDescriptor = FileManager.default.fileExists(atPath: definitionURL.path)
            ? try ProvenanceFileDescriptor.file(url: definitionURL, format: .json, role: .input)
            : nil
        let priorManifestDescriptor = try? ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .input)
        let referenceDescriptor = try ProvenanceFileDescriptor.file(url: referenceURL, format: .fasta, role: .reference)

        let versioned = GenotypeHaplotypeDefinitionSet(
            id: definition.id,
            assayID: definition.assayID,
            displayName: definition.displayName,
            speciesName: definition.speciesName,
            speciesCode: definition.speciesCode,
            prefix: definition.prefix,
            locusDefinitions: definition.locusDefinitions,
            schemaVersion: (definition.schemaVersion ?? 0) + 1,
            lastModified: HaplotypeDefinitionStore.isoString(Date()),
            changeNote: changeNote ?? definition.changeNote
        )
        try FileManager.default.createDirectory(
            at: definitionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(versioned).write(to: definitionURL, options: .atomic)

        let updatedPaths = manifest.haplotypeDefinitionPaths.contains(relativePath)
            ? manifest.haplotypeDefinitionPaths
            : manifest.haplotypeDefinitionPaths + [relativePath]
        let updatedManifest = MHCAmpliconReferenceBundleManifest(
            schemaVersion: manifest.schemaVersion,
            name: manifest.name,
            referenceFastaPath: manifest.referenceFastaPath,
            haplotypeDefinitionPaths: updatedPaths,
            defaultHaplotypeDefinitionID: manifest.defaultHaplotypeDefinitionID ?? definition.id,
            sourceFiles: manifest.sourceFiles,
            metrics: MHCAmpliconReferenceBundleMetrics(
                referenceCount: try FASTAReader(url: referenceURL).readHeadersSync().count,
                haplotypeDefinitionCount: updatedPaths.count
            ),
            provenancePath: ProvenanceWriter.provenanceFilename,
            createdAt: manifest.createdAt
        )
        try MHCAmpliconReferenceBundle.writeManifest(updatedManifest, to: bundleURL)

        let outputs = try [
            ProvenanceFileDescriptor.file(url: definitionURL, format: .json, role: .output),
            ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
            directoryDescriptor(url: bundleURL, role: .output),
        ]
        try writeMHCReferenceBundleProvenance(
            workflowName: "Haplotype definition edit in MHC reference bundle",
            bundleURL: bundleURL,
            argv: argv,
            startedAt: startedAt,
            completedAt: Date(),
            explicit: [
                "bundle": .file(bundleURL),
                "definitionID": .string(versioned.id),
                "assayID": .string(versioned.assayID),
                "speciesCode": .string(versioned.speciesCode),
                "definitionPath": .file(definitionURL),
                "referenceFASTA": .file(referenceURL),
            ],
            inputs: [priorDefinitionDescriptor, priorManifestDescriptor, referenceDescriptor].compactMap { $0 },
            outputs: outputs
        )

        return HaplotypeDefinitionCommandResult(
            scope: .project,
            definitionSet: versioned,
            definitionURL: definitionURL
        )
    }

    @discardableResult
    public func replaceReferenceFASTA(
        inMHCReferenceBundle bundleURL: URL,
        with replacementFASTAURL: URL,
        argv: [String]
    ) throws -> URL {
        let startedAt = Date()
        let bundleURL = bundleURL.standardizedFileURL
        let replacementFASTAURL = replacementFASTAURL.standardizedFileURL
        guard MHCAmpliconReferenceBundle.isBundleURL(bundleURL) else {
            throw HaplotypeDefinitionCommandServiceError.invalidMHCReferenceBundle(bundleURL.path)
        }
        guard FileManager.default.fileExists(atPath: replacementFASTAURL.path) else {
            throw HaplotypeDefinitionCommandServiceError.missingInput(replacementFASTAURL.path)
        }
        let manifest = try MHCAmpliconReferenceBundle.loadManifest(from: bundleURL)
        let manifestURL = MHCAmpliconReferenceBundle.manifestURL(in: bundleURL)
        guard let referenceURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL) else {
            throw HaplotypeDefinitionCommandServiceError.missingMHCReferenceBundleReference(manifest.referenceFastaPath)
        }
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            throw HaplotypeDefinitionCommandServiceError.missingMHCReferenceBundleReference(referenceURL.path)
        }
        try MHCAmpliconReferenceBundle.validate(at: bundleURL)

        let priorReferenceDescriptor = try ProvenanceFileDescriptor.file(url: referenceURL, format: .fasta, role: .input)
        let priorManifestDescriptor = try? ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .input)
        let replacementDescriptor = try ProvenanceFileDescriptor.file(url: replacementFASTAURL, format: .fasta, role: .reference)
        let priorReferenceData = try Data(contentsOf: referenceURL)
        do {
            let replacementData = try Data(contentsOf: replacementFASTAURL)
            try replacementData.write(to: referenceURL, options: .atomic)

            let updatedManifest = MHCAmpliconReferenceBundleManifest(
                schemaVersion: manifest.schemaVersion,
                name: manifest.name,
                referenceFastaPath: manifest.referenceFastaPath,
                haplotypeDefinitionPaths: manifest.haplotypeDefinitionPaths,
                defaultHaplotypeDefinitionID: manifest.defaultHaplotypeDefinitionID,
                sourceFiles: updatedReferenceSourceFiles(
                    manifest.sourceFiles,
                    referencePath: manifest.referenceFastaPath,
                    replacementFASTAURL: replacementFASTAURL
                ),
                metrics: MHCAmpliconReferenceBundleMetrics(
                    referenceCount: try FASTAReader(url: referenceURL).readHeadersSync().count,
                    haplotypeDefinitionCount: manifest.haplotypeDefinitionPaths.count
                ),
                provenancePath: ProvenanceWriter.provenanceFilename,
                createdAt: manifest.createdAt
            )
            try MHCAmpliconReferenceBundle.writeManifest(updatedManifest, to: bundleURL)

            let outputs = try [
                ProvenanceFileDescriptor.file(url: referenceURL, format: .fasta, role: .output),
                ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
                directoryDescriptor(url: bundleURL, role: .output),
            ]
            try writeMHCReferenceBundleProvenance(
                workflowName: "MHC reference bundle FASTA replacement",
                bundleURL: bundleURL,
                argv: argv,
                startedAt: startedAt,
                completedAt: Date(),
                explicit: [
                    "bundle": .file(bundleURL),
                    "replacementFASTA": .file(replacementFASTAURL),
                    "referenceFASTA": .file(referenceURL),
                ],
                inputs: [replacementDescriptor, priorReferenceDescriptor, priorManifestDescriptor].compactMap { $0 },
                outputs: outputs
            )
            return referenceURL
        } catch {
            try? priorReferenceData.write(to: referenceURL, options: .atomic)
            throw error
        }
    }

    public func createMHCReferenceBundle(
        definitionIDs: [String],
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        referenceFASTA: URL,
        outputURL: URL,
        name: String? = nil,
        defaultDefinitionID: String? = nil,
        forceOverwrite: Bool = false,
        argv: [String]
    ) async throws -> MHCAmpliconReferenceBundleBuildResult {
        let trimmedIDs = definitionIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedIDs.isEmpty else {
            throw HaplotypeDefinitionCommandServiceError.missingHaplotypeDefinitions
        }
        let records = try trimmedIDs.map { id in
            try uniqueDefinitionRecord(
                definitionID: id,
                assayID: assayID,
                speciesCode: speciesCode,
                scope: scope,
                includeReferenceBundles: true
            )
        }
        return try await createMHCReferenceBundle(
            records: records,
            referenceFASTA: referenceFASTA,
            outputURL: outputURL,
            name: name,
            defaultDefinitionID: defaultDefinitionID,
            forceOverwrite: forceOverwrite,
            argv: argv
        )
    }

    public func createMHCReferenceBundle(
        records: [HaplotypeDefinitionRecord],
        referenceFASTA: URL,
        outputURL: URL,
        name: String? = nil,
        defaultDefinitionID: String? = nil,
        forceOverwrite: Bool = false,
        argv: [String]
    ) async throws -> MHCAmpliconReferenceBundleBuildResult {
        guard !records.isEmpty else {
            throw HaplotypeDefinitionCommandServiceError.missingHaplotypeDefinitions
        }
        for record in records {
            try validateDefinition(record.definitionSet)
        }
        let inputs = records.map { record in
            MHCAmpliconReferenceBundleDefinitionInput(
                definition: record.definitionSet,
                sourceURL: record.fileURL,
                sourceDescription: definitionSourceDescription(for: record),
                sourceScope: record.scope.rawValue
            )
        }
        return try await MHCAmpliconReferenceBundleBuilder().build(
            MHCAmpliconReferenceBundleBuildConfiguration(
                referenceFASTA: referenceFASTA,
                haplotypeDefinitionURLs: [],
                haplotypeDefinitionInputs: inputs,
                outputURL: outputURL,
                name: name,
                defaultHaplotypeDefinitionID: defaultDefinitionID,
                forceOverwrite: forceOverwrite,
                argv: argv,
                provenanceWorkflowName: "lungfish haplotypes bundle-create"
            )
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
        try canonicalizeProjectDefinitionProvenance(for: definitionURL)
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
        if let provenanceURL = store.provenanceURL(for: definitionID) {
            try canonicalizeProjectDefinitionProvenance(at: provenanceURL)
        }
    }

    private var library: HaplotypeDefinitionLibrary {
        HaplotypeDefinitionLibrary(projectRoot: projectRoot)
    }

    private func writableStore(scope: HaplotypeDefinitionScope) throws -> HaplotypeDefinitionStore {
        guard let store = library.store(for: scope) else {
            throw HaplotypeDefinitionCommandServiceError.missingProjectRoot
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

    private func uniqueDefinitionRecord(
        definitionID: String,
        assayID: String? = nil,
        speciesCode: String? = nil,
        scope: HaplotypeDefinitionScope? = nil,
        includeReferenceBundles: Bool = false
    ) throws -> HaplotypeDefinitionRecord {
        // Resolve against ALL managed records (bare project-store defs + bundle
        // defs) so a freshly-imported def can be bundled/exported/duplicated.
        // `includeReferenceBundles` is retained for source-compat.
        _ = includeReferenceBundles
        let matches = library.allManagedRecords(
            assayID: assayID,
            speciesCode: speciesCode,
            scope: scope
        ).filter { $0.definitionSet.id == definitionID }
        guard !matches.isEmpty else {
            throw HaplotypeDefinitionCommandServiceError.definitionNotFound(definitionID)
        }
        guard matches.count == 1 else {
            throw HaplotypeDefinitionCommandServiceError.ambiguousDefinition(definitionID)
        }
        return matches[0]
    }

    private func definitionSourceDescription(for record: HaplotypeDefinitionRecord) -> String {
        if let referenceBundleURL = record.referenceBundleURL {
            return "mhc-reference-bundle:\(referenceBundleURL.path):\(record.definitionSet.id)"
        }
        if let fileURL = record.fileURL {
            return fileURL.path
        }
        return "\(record.scope.rawValue):\(record.definitionSet.id)"
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
            "scope": scope.rawValue,
        ]
    }

    private func canonicalizeProjectDefinitionProvenance(for definitionURL: URL) throws {
        try canonicalizeProjectDefinitionProvenance(at: definitionURL.appendingPathExtension("provenance.json"))
    }

    private func canonicalizeProjectDefinitionProvenance(at provenanceURL: URL) throws {
        if (try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: provenanceURL)) != nil {
            return
        }
        let primitive = try JSONDecoder().decode(
            HaplotypeDefinitionEditProvenance.self,
            from: Data(contentsOf: provenanceURL)
        )
        try ProvenanceWriter(signingProvider: nil).write(
            canonicalEnvelope(from: primitive),
            toSidecar: provenanceURL
        )
    }

    private func canonicalEnvelope(from primitive: HaplotypeDefinitionEditProvenance) -> ProvenanceEnvelope {
        let startedAt = Self.parseHaplotypeProvenanceDate(primitive.startedAt) ?? Date()
        let endedAt = Self.parseHaplotypeProvenanceDate(primitive.endedAt)
            ?? startedAt.addingTimeInterval(primitive.wallTimeSeconds)
        let inputs = primitive.inputs.map(Self.canonicalDescriptor)
        let outputs = primitive.outputs.map(Self.canonicalDescriptor)
        let step = ProvenanceStep(
            toolName: primitive.toolName,
            toolVersion: primitive.toolVersion,
            argv: primitive.argv,
            durableReplayArgv: primitive.argv,
            reproducibleCommand: primitive.reproducibleCommand,
            inputs: inputs,
            outputs: outputs,
            exitStatus: primitive.exitStatus,
            wallTimeSeconds: primitive.wallTimeSeconds,
            stderr: primitive.stderr,
            startedAt: startedAt,
            completedAt: endedAt
        )
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: primitive.workflowName,
            workflowVersion: primitive.workflowVersion,
            toolName: primitive.toolName,
            toolVersion: primitive.toolVersion,
            tool: ProvenanceToolIdentity(
                name: primitive.toolName,
                version: primitive.toolVersion,
                kind: primitive.toolName == CLICommandIdentity.executableName ? "cli" : "gui"
            ),
            argv: primitive.argv,
            durableReplayArgv: primitive.argv,
            reproducibleCommand: primitive.reproducibleCommand,
            options: ProvenanceOptions(
                explicit: primitive.options.explicit.mapValues(ParameterValue.string),
                resolvedDefaults: primitive.options.resolvedDefaults.mapValues(ParameterValue.string)
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: primitive.workflowVersion,
                operatingSystemVersion: primitive.runtime.operatingSystem,
                user: primitive.runtime.user
            ),
            files: inputs + outputs,
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: primitive.wallTimeSeconds,
            exitStatus: primitive.exitStatus,
            stderr: primitive.stderr
        )
    }

    private static func canonicalDescriptor(
        from record: HaplotypeDefinitionEditProvenance.FileRecord
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: record.path,
            checksumSHA256: record.checksumSHA256,
            fileSize: record.fileSizeBytes,
            format: .json,
            role: canonicalFileRole(record.role)
        )
    }

    private static func canonicalFileRole(_ raw: String) -> FileRole {
        switch raw {
        case FileRole.output.rawValue:
            return .output
        case FileRole.reference.rawValue:
            return .reference
        case FileRole.index.rawValue:
            return .index
        case FileRole.log.rawValue:
            return .log
        case FileRole.report.rawValue:
            return .report
        default:
            return .input
        }
    }

    private static func parseHaplotypeProvenanceDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func existingDefinitionRelativePath(
        definitionID: String,
        manifest: MHCAmpliconReferenceBundleManifest,
        bundleURL: URL
    ) throws -> String? {
        for relativePath in manifest.haplotypeDefinitionPaths {
            guard let url = try? BundleManifest.validatedBundleMemberURL(
                for: relativePath,
                in: bundleURL,
                field: "haplotypeDefinitionPaths[]"
            ) else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let definition = try? JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self, from: data) else {
                continue
            }
            if definition.id == definitionID {
                return relativePath
            }
        }
        return nil
    }

    /// Resolves a non-colliding destination URL for a bundle named `name` in
    /// `directory`. If `name` is free it is used as-is; otherwise the base name is
    /// suffixed with ` 2`, ` 3`, … before the `.lungfishmhcref` extension. Never
    /// returns a URL that already exists on disk.
    private func disambiguatedBundleDestination(in directory: URL, named name: String) -> URL {
        let pathExtension = (name as NSString).pathExtension
        let baseName = (name as NSString).deletingPathExtension
        let fileManager = FileManager.default

        func candidate(_ suffix: Int) -> URL {
            let stem = suffix <= 1 ? baseName : "\(baseName) \(suffix)"
            let component = pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
            return directory.appendingPathComponent(component)
        }

        var suffix = 1
        var url = candidate(suffix)
        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = candidate(suffix)
        }
        return url
    }

    private func updatedReferenceSourceFiles(
        _ sourceFiles: [MHCAmpliconReferenceBundleSourceFile],
        referencePath: String,
        replacementFASTAURL: URL
    ) -> [MHCAmpliconReferenceBundleSourceFile] {
        let retained = sourceFiles.filter { source in
            source.path != referencePath && source.role != "reference_fasta"
        }
        return [
            MHCAmpliconReferenceBundleSourceFile(
                path: referencePath,
                role: "reference_fasta",
                originalPath: replacementFASTAURL.path
            ),
        ] + retained
    }

    private func writeMHCReferenceBundleProvenance(
        workflowName: String,
        bundleURL: URL,
        argv: [String],
        startedAt: Date,
        completedAt: Date,
        explicit: [String: ParameterValue],
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor]
    ) throws {
        let replayArgv = argv.isEmpty ? ["lungfish-gui", workflowName, bundleURL.path] : argv
        let step = ProvenanceStep(
            toolName: workflowName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: replayArgv,
            durableReplayArgv: replayArgv,
            reproducibleCommand: HaplotypeDefinitionStore.shellCommand(replayArgv),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish Genome Explorer",
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: replayArgv,
            durableReplayArgv: replayArgv,
            reproducibleCommand: HaplotypeDefinitionStore.shellCommand(replayArgv),
            options: ProvenanceOptions(
                explicit: explicit,
                resolvedDefaults: [
                    "projectRoot": .string(projectRoot?.path ?? ""),
                    "bundleFormat": .string(MHCAmpliconReferenceBundle.directoryExtension),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            files: inputs + outputs,
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func writeMHCReferenceBundleInstallProvenance(
        sourceURL: URL,
        destinationURL: URL,
        destinationDirectory: URL,
        argv: [String],
        startedAt: Date
    ) throws {
        let destination = destinationURL.standardizedFileURL
        let completedAt = Date()
        let sourceDescriptor = try directoryDescriptor(url: sourceURL.standardizedFileURL, role: .input)
        let destinationDescriptor = try directoryDescriptor(url: destination, role: .output)
        try writeMHCReferenceBundleProvenance(
            workflowName: "MHC reference bundle install",
            bundleURL: destination,
            argv: argv,
            startedAt: startedAt,
            completedAt: completedAt,
            explicit: [
                "sourceBundle": .file(sourceURL.standardizedFileURL),
                "destinationDirectory": .file(destinationDirectory.standardizedFileURL),
                "destinationBundle": .file(destination),
            ],
            inputs: [sourceDescriptor],
            outputs: [destinationDescriptor]
        )
    }

    private func directoryDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: role)
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: .unknown,
            role: role
        )
    }

    private func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars).trimmingCharacters(in: .init(charactersIn: ".-_"))
        return name.isEmpty ? "haplotype-definition" : name
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
            toolName: CLICommandIdentity.executableName,
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
    case missingProjectRoot
    case definitionNotFound(String)
    case invalidMHCReferenceBundle(String)
    case missingInput(String)
    case missingHaplotypeDefinitions
    case ambiguousDefinition(String)
    case missingMHCReferenceBundleReference(String)
    case missingDefinitionURL(String)
    case validationFailed([String])

    public var errorDescription: String? {
        switch self {
        case .missingProjectRoot:
            return "A project is required to write haplotype definitions. Open or create a project first."
        case .definitionNotFound(let id):
            return "Haplotype definition not found: \(id)"
        case .invalidMHCReferenceBundle(let path):
            return "Not an MHC reference bundle: \(path)"
        case .missingInput(let path):
            return "Input file does not exist: \(path)"
        case .missingHaplotypeDefinitions:
            return "MHC reference bundle creation requires at least one haplotype definition."
        case .ambiguousDefinition(let id):
            return "More than one haplotype definition matches \(id). Choose an assay, species, scope, or bundle."
        case .missingMHCReferenceBundleReference(let path):
            return "MHC reference bundle is missing its reference FASTA: \(path)"
        case .missingDefinitionURL(let id):
            return "Could not resolve stored haplotype definition URL for \(id)."
        case .validationFailed(let errors):
            return "Invalid haplotype definition:\n" + errors.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}
