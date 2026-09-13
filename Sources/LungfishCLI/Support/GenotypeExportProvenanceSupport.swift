import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum GenotypeExportProvenanceSupport {
    static func record(
        workflowName: String,
        toolName: String,
        command: [String],
        bundleURL: URL,
        outputURLs: [URL],
        outputDirectory: URL,
        optionPaths: [String: URL],
        explicitOptions: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedOptions: [String: ParameterValue]? = nil,
        additionalInputURLs: [URL] = [],
        additionalInputRecords: [FileRecord] = [],
        excludedInputURLs: [URL] = [],
        extraSteps: [ProvenanceStep] = [],
        startedAt: Date,
        publicationArtifactDidWrite:
            (@Sendable (ProvenanceWriterMutation) throws -> Void)? = nil
    ) async throws {
        guard !outputURLs.isEmpty else { return }
        var parameters = optionPaths.mapValues { ParameterValue.file($0) }
        parameters.merge(explicitOptions) { _, explicit in explicit }
        parameters["outputCount"] = .integer(outputURLs.count)
        let consumedInputSnapshotPaths = Set(
            additionalInputRecords.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            }
        )

        let excludedInputPaths = Set(
            excludedInputURLs.map(\.standardizedFileURL.path)
                + additionalInputRecords.map {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                }
        )

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: workflowName,
            parameters: parameters,
            defaults: defaults,
            resolved: resolvedOptions,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            extraSteps: extraSteps,
            inputs: inputRecords(
                bundleURL: bundleURL,
                excluding: excludedInputPaths
            ) + additionalInputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, role: .input)
            } + additionalInputRecords,
            outputs: outputURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, role: .output)
            },
            consumedInputSnapshotPaths: consumedInputSnapshotPaths,
            exitCode: 0,
            wallTime: max(0, Date().timeIntervalSince(startedAt)),
            stderr: nil,
            status: .completed,
            outputDirectory: outputDirectory,
            writeFileSidecars: true,
            publicationArtifactDidWrite: publicationArtifactDidWrite
        )
    }

    private static func inputRecords(
        bundleURL: URL,
        excluding excludedPaths: Set<String> = []
    ) -> [FileRecord] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory) else {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "missing",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }
        guard isDirectory.boolValue else {
            return [ProvenanceRecorder.fileRecord(url: bundleURL, role: .input)]
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        ) else {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "unreadable-directory",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }

        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            guard !excludedPaths.contains(url.standardizedFileURL.path) else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true,
                  values.isHidden != true else {
                continue
            }
            records.append(ProvenanceRecorder.fileRecord(url: url, role: .input))
        }
        if records.isEmpty {
            return [
                FileRecord(
                    path: bundleURL.path,
                    sha256: "empty-directory",
                    sizeBytes: 0,
                    format: .unknown,
                    role: .input
                )
            ]
        }
        return records.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}

/// The CLI boundary for every ordinary genotype Excel export. It captures the
/// mutable bundle/annotation/definition authority once, creates one immutable
/// scientific snapshot, and delegates rendering and publication to the shared
/// workflow service.
enum GenotypeExcelCLIExportSupport {
    struct Outcome: Sendable {
        let result: GenotypeExcelExportService.ExportResult
        let visibleSamples: [String]
        let hasHaplotypeContent: Bool
    }

    struct Request: Sendable {
        let bundleURL: URL
        let outputURL: URL
        let annotationURL: URL?
        let projectionURL: URL?
        let samples: [String]
        let activeHaplotypeDefinitionID: String?
        let filter: GenotypeMatrixBaseProjection.Filter
        let workflowName: String
        let argv: [String]
        let options: [String: String]
        let defaults: [String: String]
        let runtimeContext: [String: String]
        let replacingExisting: Bool
    }

    /// Preserve the literal process invocation in production while allowing
    /// command-boundary tests that call `parse(...).run()` to provide the
    /// equivalent canonical invocation explicitly.
    static func invocation(fallback: [String]) -> [String] {
        guard let executable = CommandLine.arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent
                == CLICommandIdentity.executableName else {
            return fallback
        }
        return CommandLine.arguments
    }

    static func export(
        _ request: Request,
        afterManifestDecode: (@Sendable () throws -> Void)? = nil,
        afterAuthorityCapture: (@Sendable () throws -> Void)? = nil,
        managedPythonResolver: @escaping @Sendable () async throws -> URL
    ) async throws -> Outcome {
        let bundle = request.bundleURL.standardizedFileURL
        let output = request.outputURL.standardizedFileURL
        let generatedAt = ISO8601DateFormatter().string(from: Date())

        let manifestURL = ONTGenotypeResultBundle.manifestURL(
            in: bundle
        ).standardizedFileURL
        let manifestData = try ONTGenotypeResultBundle.readManifestDataNoFollow(
            from: bundle
        )
        let manifest = try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: manifestData
        )
        try afterManifestDecode?()
        var witnessed = try scientificFileWitnesses(
            at: resolvedScientificInputURLs(
                manifest: manifest,
                bundleURL: bundle,
                includeAutomaticSidecar: request.annotationURL == nil
            ) + [request.annotationURL, request.projectionURL].compactMap { $0 },
            capturedDataByPath: [manifestURL.path: manifestData]
        )
        let result = try ONTGenotypeResultBundle.loadResult(
            from: bundle,
            requiring: manifest
        )
        try verify(witnessed)
        var sidecar = try loadSidecar(
            bundleURL: bundle,
            explicitURL: request.annotationURL,
            generatedAt: generatedAt
        )
        if let definitionID = request.activeHaplotypeDefinitionID {
            sidecar.settings.activeHaplotypeDefinitionSetID = definitionID
            sidecar.settings.activeHaplotypeAssayID = nil
        }

        let loadedProjection = try request.projectionURL.map { url in
            try JSONDecoder().decode(
                GenotypeViewProjection.self,
                from: Data(contentsOf: url.standardizedFileURL)
            )
        }
        let scopedProjection = try loadedProjection.map {
            try self.projection($0, retainingSamples: request.samples)
        }
        let definition = GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(
            for: result,
            bundleURL: bundle,
            sidecar: sidecar
        )
        let analysis = GenotypeHaplotypeAnalysisResolver.activeAnalysis(
            for: result,
            sidecar: sidecar,
            definitionSet: definition
        )
        let referenceOrderCapture: ONTGenotypeResultBundle
            .ReferenceGenotypeLocusDisplayOrderCapture?
        if sidecar.settings.genotypeLocusDisplayOrder == nil,
           result.manifest.genotypeLocusDisplayOrder == nil {
            let provenancePath = result.artifacts.provenanceURL.standardizedFileURL.path
            let provenanceData = witnessed.first { $0.path == provenancePath }?.data
            referenceOrderCapture = try ONTGenotypeResultBundle
                .referenceGenotypeLocusDisplayOrderCapture(
                    manifest: result.manifest,
                    in: bundle,
                    provenanceData: provenanceData
                )
        } else {
            referenceOrderCapture = nil
        }
        if let referenceOrderCapture,
           !witnessed.contains(where: {
               URL(fileURLWithPath: $0.path).standardizedFileURL
                   == referenceOrderCapture.manifestURL
           }) {
            witnessed.append(
                .init(
                    path: referenceOrderCapture.manifestURL.path,
                    data: referenceOrderCapture.manifestData
                )
            )
        }
        let order = sidecar.settings.genotypeLocusDisplayOrder
            ?? result.manifest.genotypeLocusDisplayOrder
            ?? referenceOrderCapture?.order
        let authority = GenotypeExcelSnapshotBuilder.CapturedAuthority(
            analysis: analysis,
            definitionSet: definition,
            locusDisplayOrder: order,
            colors: scopedProjection?.presentationColors ?? []
        )
        var snapshot: GenotypeWorkbookPresentation.Snapshot
        if let scopedProjection {
            // The shared builder validates every captured cell against raw or
            // per-occurrence authority before applying any active numeric
            // thresholds. Denominator-only defaults never transform evidence.
            snapshot = try GenotypeExcelSnapshotBuilder.capture(
                result: result,
                sidecar: sidecar,
                allProjection: nil,
                filteredProjection: scopedProjection,
                generatedAt: generatedAt,
                authority: authority,
                filter: request.filter
            )
        } else {
            snapshot = try GenotypeExcelSnapshotBuilder.capture(
                result: result,
                sidecar: sidecar,
                allProjection: nil,
                filteredProjection: nil,
                generatedAt: generatedAt,
                authority: authority,
                filter: request.filter
            )
        }

        // A sample-only CLI scope narrows the Filtered matrix without ever
        // narrowing All. The projection is made from the already validated
        // common snapshot, so no independent threshold or evidence formula is
        // introduced at the command boundary.
        if loadedProjection == nil, !request.samples.isEmpty {
            let narrowed = try self.projection(
                from: snapshot,
                retainingSamples: request.samples,
                authority: authority,
                filter: request.filter
            )
            snapshot = try GenotypeExcelSnapshotBuilder.capture(
                result: result,
                sidecar: sidecar,
                allProjection: nil,
                filteredProjection: narrowed,
                generatedAt: generatedAt,
                authority: authority,
                filter: request.filter
            )
        }

        if let definition {
            guard let definitionURL = GenotypeHaplotypeAnalysisResolver
                    .activeDefinitionFileURL(
                        for: result,
                        bundleURL: bundle,
                        sidecar: sidecar
                    ) else {
                throw GenotypeExcelExportService.ExportError.invalidInput(
                    "captured haplotype definition source changed or disappeared"
                )
            }
            let definitionData = try Data(contentsOf: definitionURL.standardizedFileURL)
            guard try JSONDecoder().decode(
                GenotypeHaplotypeDefinitionSet.self,
                from: definitionData
            ) == definition else {
                throw GenotypeExcelExportService.ExportError.invalidInput(
                    "captured haplotype definition source changed"
                )
            }
            if !witnessed.contains(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL
                    == definitionURL.standardizedFileURL
            }) {
                witnessed.append(
                    .init(
                        path: definitionURL.standardizedFileURL.path,
                        data: definitionData
                    )
                )
            }
        }
        try afterAuthorityCapture?()
        try verify(witnessed)

        let python = try await managedPythonResolver()
        var runtime = request.runtimeContext
        runtime["cliExecutable"] = Bundle.main.executableURL?.path
            ?? CLICommandIdentity.executableName
        runtime["platform"] = ProcessInfo.processInfo.operatingSystemVersionString
        runtime["captureMode"] = "immutable-native-scientific-snapshot"
        let provenance = GenotypeExcelExportService.ProvenanceRequest(
            workflowName: request.workflowName,
            toolVersion: LungfishAppVersion.short,
            argv: request.argv,
            options: request.options,
            defaults: request.defaults,
            runtimeContext: runtime,
            inputs: witnessed
        )
        let export = try await GenotypeExcelExportService(
            pythonExecutableURL: python,
            replayExecutableURL: Bundle.main.executableURL
        ).export(
            snapshot: snapshot,
            outputURL: output,
            provenance: provenance,
            replacingExisting: request.replacingExisting
        )
        return .init(
            result: export,
            visibleSamples: snapshot.filteredMatrix.samples.map(\.id),
            hasHaplotypeContent: snapshot.hasHaplotypeContent
        )
    }

    private static func loadSidecar(
        bundleURL: URL,
        explicitURL: URL?,
        generatedAt: String
    ) throws -> GenotypeAnnotationSidecar {
        if let explicitURL {
            return try GenotypeAnnotationSidecar.decode(
                Data(contentsOf: explicitURL.standardizedFileURL)
            )
        }
        let captured = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
        return captured.data == nil
            ? .empty(generatedAt: generatedAt)
            : captured.sidecar
    }

    private static func projection(
        _ source: GenotypeViewProjection,
        retainingSamples requested: [String]
    ) throws -> GenotypeViewProjection {
        guard source.rows.allSatisfy({ row in
            row.cells.count == source.sampleColumns.count
                && (row.cellColorsHex?.count == source.sampleColumns.count
                    || row.cellColorsHex == nil)
                && (row.cellStyles?.count == source.sampleColumns.count
                    || row.cellStyles == nil)
        }) else {
            throw ValidationError(
                "The supplied projection must contain exactly one value/style per sample column."
            )
        }
        guard !requested.isEmpty else { return source }
        guard Set(requested).count == requested.count else {
            throw ValidationError("--sample values must be unique.")
        }
        let requestedSet = Set(requested)
        let unknown = requestedSet.subtracting(source.sampleColumns)
        guard unknown.isEmpty else {
            throw ValidationError(
                "--sample is not present in the supplied projection: "
                    + unknown.sorted().joined(separator: ", ")
            )
        }
        let indices = source.sampleColumns.indices.filter {
            requestedSet.contains(source.sampleColumns[$0])
        }
        return GenotypeViewProjection(
            lens: source.lens,
            sampleColumns: indices.map { source.sampleColumns[$0] },
            rows: source.rows.map { row in
                GenotypeViewProjectionRow(
                    label: row.label,
                    rawGenotype: row.rawGenotype,
                    locus: row.locus,
                    stableClusterID: row.stableClusterID,
                    cells: indices.map { row.cells[$0] },
                    cellColorsHex: row.cellColorsHex.map { values in
                        indices.map { values.indices.contains($0) ? values[$0] : nil }
                    },
                    rowColorHex: row.rowColorHex,
                    rowStyle: row.rowStyle,
                    cellStyles: row.cellStyles.map { values in
                        indices.map { values.indices.contains($0) ? values[$0] : nil }
                    }
                )
            },
            cellColorMode: source.cellColorMode,
            genotypeLocusDisplayOrder: source.genotypeLocusDisplayOrder,
            genotypeNumericPrefixOrder: source.genotypeNumericPrefixOrder,
            diagnosticAllelesOnly: source.diagnosticAllelesOnly,
            includeTotalReads: source.includeTotalReads,
            haplotypeCalls: source.haplotypeCalls?.filter {
                requestedSet.contains($0.sample)
            },
            haplotypeLocusScope: source.haplotypeLocusScope,
            sourceRevision: source.sourceRevision,
            filterContext: source.filterContext,
            presentationColors: source.presentationColors
        )
    }

    private static func projection(
        from snapshot: GenotypeWorkbookPresentation.Snapshot,
        retainingSamples requested: [String],
        authority: GenotypeExcelSnapshotBuilder.CapturedAuthority,
        filter: GenotypeMatrixBaseProjection.Filter
    ) throws -> GenotypeViewProjection {
        guard Set(requested).count == requested.count else {
            throw ValidationError("--sample values must be unique.")
        }
        let available = Set(snapshot.filteredMatrix.samples.map(\.id))
        let requestedSet = Set(requested)
        let unknown = requestedSet.subtracting(available)
        guard unknown.isEmpty else {
            throw ValidationError(
                "Unknown --sample value: " + unknown.sorted().joined(separator: ", ")
            )
        }
        let samples = snapshot.filteredMatrix.samples.map(\.id).filter {
            requestedSet.contains($0)
        }
        return GenotypeViewProjection(
            lens: "allele",
            sampleColumns: samples,
            rows: snapshot.filteredMatrix.rows.map { row in
                let values = Dictionary(uniqueKeysWithValues: row.cells.map {
                    ($0.sampleID, $0)
                })
                return GenotypeViewProjectionRow(
                    label: row.displayName,
                    rawGenotype: row.target.genotype,
                    locus: row.target.locus,
                    stableClusterID: row.target.stableClusterID,
                    cells: samples.map { values[$0]?.displayValue.map(String.init) ?? "" },
                    cellColorsHex: samples.map { values[$0]?.fillHex },
                    rowColorHex: row.fillHex,
                    rowStyle: row.style,
                    cellStyles: samples.map { values[$0]?.style }
                )
            },
            haplotypeCalls: snapshot.calls.filter {
                requestedSet.contains($0.sampleID)
            }.map {
                GenotypeViewProjectionHaplotypeCall(
                    sample: $0.sampleID,
                    locus: $0.locus,
                    haplotype1: $0.h1.effective,
                    haplotype2: $0.h2.effective,
                    haplotype1Status: $0.h1.status,
                    haplotype2Status: $0.h2.status,
                    haplotype1Source: $0.h1.source,
                    haplotype2Source: $0.h2.source,
                    baselineHaplotype1: $0.h1.pipeline ?? "",
                    baselineHaplotype2: $0.h2.pipeline ?? "",
                    comment: $0.comment,
                    baselineHaplotype1Available: $0.h1.baselineAvailable,
                    baselineHaplotype2Available: $0.h2.baselineAvailable
                )
            },
            haplotypeLocusScope: snapshot.filteredMatrix.loci,
            sourceRevision: authority.analysis.map {
                .init(
                    assayID: $0.assayID,
                    analysisRevisionID: $0.analysisRevisionID,
                    definitionSetID: $0.definitionSetID
                )
            },
            filterContext: [
                "Sample scope": samples.joined(separator: ", "),
                "Minimum reads": String(filter.matrixMinimumReads),
                "Minimum percent": String(filter.matrixMinimumPercent),
            ],
            presentationColors: snapshot.colors
        )
    }

    private static func scientificFileWitnesses(
        at sourceURLs: [URL],
        capturedDataByPath: [String: Data] = [:]
    ) throws -> [GenotypeExcelExportService.InputWitness] {
        let urls = sourceURLs.map(\.standardizedFileURL)
        var seen = Set<String>()
        return try urls.sorted { $0.path < $1.path }.compactMap { url in
            guard seen.insert(url.path).inserted else { return nil }
            return .init(
                path: url.path,
                data: try capturedDataByPath[url.path] ?? Data(contentsOf: url)
            )
        }
    }

    /// Exact paths the result loader consumes. Core CSV/JSON paths may be
    /// absolute and may use any filename extension; declared artifact paths
    /// remain bundle-relative under the loader's integrity contract.
    private static func resolvedScientificInputURLs(
        manifest: ONTGenotypeResultBundleManifest,
        bundleURL: URL,
        includeAutomaticSidecar: Bool
    ) throws -> [URL] {
        var urls = [
            ONTGenotypeResultBundle.manifestURL(in: bundleURL),
            ONTGenotypeResultBundle.resolvedURL(
                for: manifest.longSummaryCSVPath,
                in: bundleURL
            ),
            ONTGenotypeResultBundle.resolvedURL(
                for: manifest.sampleSummaryCSVPath,
                in: bundleURL
            ),
            ONTGenotypeResultBundle.resolvedURL(
                for: manifest.statsJSONPath,
                in: bundleURL
            ),
            ONTGenotypeResultBundle.resolvedURL(
                for: manifest.provenancePath,
                in: bundleURL
            ),
        ]
        if let path = manifest.haplotypeAnalysisPath {
            let url = ONTGenotypeResultBundle.resolvedURL(for: path, in: bundleURL)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }

        var references: [ONTMHCArtifactReference] = []
        if let candidate = manifest.mhcCandidateArtifacts {
            references += [
                candidate.genotypingEvidence?.bam,
                candidate.genotypingEvidence?.bai,
                candidate.reciprocalEvidence?.bam,
                candidate.reciprocalEvidence?.bai,
                candidate.candidateJSON,
                candidate.candidateFASTA,
                candidate.candidateGenBank,
                candidate.candidateEMBL,
                candidate.unnameableJSON,
                candidate.unnameableFASTA,
                candidate.unnameableGenBank,
                candidate.unnameableEMBL,
                candidate.rawUnmatchedFASTA,
                candidate.sourceIdentityMap,
            ].compactMap { $0 }
        }
        if let alignment = manifest.alignmentArtifacts {
            references += [
                alignment.genotypingEvidence?.bam,
                alignment.genotypingEvidence?.bai,
                alignment.reciprocalEvidence?.bam,
                alignment.reciprocalEvidence?.bai,
            ].compactMap { $0 }
        }
        if let provisional = manifest.provisionalExon2Artifacts {
            references += [provisional.catalogJSON, provisional.sequencesFASTA]
        }
        if let visualization = manifest.mhcReferenceVisualizations {
            references.append(visualization.recordsJSON)
        }
        if let catalog = manifest.reviewableRowCatalog { references.append(catalog) }
        urls += try references.map {
            try BundleManifest.validatedBundleMemberURL(
                for: $0.path,
                in: bundleURL,
                field: "genotype scientific artifact"
            )
        }
        if let store = manifest.referenceRecordStore {
            urls.append(
                try BundleManifest.validatedBundleMemberURL(
                    for: store.databasePath,
                    in: bundleURL,
                    field: "reference_record_store.database_path"
                )
            )
        }
        let automaticSidecar = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundleURL
        )
        if includeAutomaticSidecar,
           FileManager.default.fileExists(atPath: automaticSidecar.path) {
            urls.append(automaticSidecar)
        }
        return urls
    }

    private static func verify(
        _ witnesses: [GenotypeExcelExportService.InputWitness]
    ) throws {
        for witness in witnesses where witness.verifyCurrentFile {
            guard try Data(contentsOf: URL(fileURLWithPath: witness.path))
                    == witness.data else {
                throw GenotypeExcelExportService.ExportError.invalidInput(
                    "scientific input changed during capture: \(witness.path)"
                )
            }
        }
    }
}
