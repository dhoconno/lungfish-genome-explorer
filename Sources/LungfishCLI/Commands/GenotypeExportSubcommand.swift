import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

private enum GenotypeExportPublicationLockError: Error, LocalizedError {
    case unsafeLock(String)
    case systemFailure(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeLock(let path):
            return "Genotype export publication lock is unsafe: \(path)"
        case .systemFailure(let path, let code):
            return "Could not lock genotype export publication directory at "
                + "\(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Serializes payload, root-provenance, and output-sidecar publication for
/// every genotype export targeting the same directory. The lock is
/// process-independent: separate CLI processes coordinate through `flock`.
private final class GenotypeExportDirectoryPublicationLock:
    @unchecked Sendable
{
    static let filename = ".lungfish-genotype-export-publication.lock"

    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(
        in outputDirectory: URL
    ) throws -> GenotypeExportDirectoryPublicationLock {
        let directory = outputDirectory.standardizedFileURL
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try NoFollowFileSystem
                .openDirectoryHierarchy(directory)
        } catch {
            throw GenotypeExportPublicationLockError.systemFailure(
                path: directory.path,
                code: (error as? POSIXError)?.code.rawValue ?? EIO
            )
        }
        defer { Darwin.close(directoryDescriptor) }

        let lockURL = directory.appendingPathComponent(filename)
        let descriptor = filename.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw GenotypeExportPublicationLockError.unsafeLock(
                    lockURL.path
                )
            }
            throw GenotypeExportPublicationLockError.systemFailure(
                path: lockURL.path,
                code: code
            )
        }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw GenotypeExportPublicationLockError.unsafeLock(lockURL.path)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            Darwin.close(descriptor)
            throw GenotypeExportPublicationLockError.systemFailure(
                path: lockURL.path,
                code: code
            )
        }
        return GenotypeExportDirectoryPublicationLock(
            descriptor: descriptor
        )
    }

    func release() {
        let value = stateLock.withLock { () -> Int32 in
            defer { descriptor = -1 }
            return descriptor
        }
        guard value >= 0 else { return }
        _ = flock(value, LOCK_UN)
        Darwin.close(value)
    }

    deinit { release() }
}

/// Unified genotype-bundle export.
///
/// Where `export-xlsx` / `export-pivot-xlsx` / `export-labkey` are each
/// flagless single-shape exporters, this command takes the same lens /
/// filter flags the 12S exporter exposes plus an optional
/// `--view-projection <path>` describing exactly what the GUI viewport
/// rendered (visible sample columns, rows, cell/row colors). When a
/// projection is supplied the produced workbook reproduces that colored
/// view; otherwise the full-bundle matrix is exported (the `export-xlsx`
/// shape, via the shared ``GenotypeXlsxWorkbookWriter``).
///
/// This lets the GUI export shell out to a headless `lungfish-cli` run and
/// reproduce the analyst's on-screen view with canonical provenance. It is
/// provenance-`inspectOnly` (`cli.genotype` policy) — it never modifies the
/// bundle or its sidecar.
struct GenotypeExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a genotype bundle (or a rendered view projection) as XLSX/CSV/TSV."
    )

    /// Export container format.
    enum ExportFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
        case xlsx
        case csv
        case tsv

        static var allValueStrings: [String] { allCases.map(\.rawValue) }
    }

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(
        name: .customLong("export-format"),
        help: "Export container format: xlsx, csv, tsv (default: xlsx)."
    )
    var format: ExportFormat = .xlsx

    @Option(name: [.long, .customShort("o")], help: "Output file path.")
    var output: String

    @Option(name: .long, help: "Viewport lens to record in provenance (e.g. haplotype, allele).")
    var lens: String?

    @Option(name: .customLong("min-reads"), help: "Drop calls below this unique-read count.")
    var minReads: Int?

    @Option(name: .long, help: "Named filter applied to the view (recorded in provenance).")
    var filter: String?

    @Option(name: .customLong("sample"), parsing: .singleValue, help: "Restrict to this sample (repeatable).")
    var samples: [String] = []

    @Option(
        name: .customLong("active-haplotype-definition"),
        help: "Active haplotype definition set ID to resolve calls against."
    )
    var activeHaplotypeDefinition: String?

    @Option(
        name: .customLong("view-projection"),
        help: "Path to a GenotypeViewProjection JSON describing the rendered viewport."
    )
    var viewProjection: String?

    @Option(
        name: .customLong("annotations"),
        help: "Annotation sidecar to include in annotation-bearing exports; defaults to bundle annotations.json when present."
    )
    var annotations: String?

    @Flag(name: .customLong("force"), help: "Overwrite an existing output file.")
    var force: Bool = false

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty.")
        }
    }

    func run() async throws {
        _ = try await runReturningResolvedColumns()
    }

    /// Runs the export and returns the resolved visible sample columns. The
    /// command's `run()` ignores the return value; tests use it to assert
    /// the projection filtered to exactly the visible columns.
    @discardableResult
    func runReturningResolvedColumns(
        beforeAnnotationSnapshot: (() throws -> Void)? = nil,
        beforeOutputPublication: (() throws -> Void)? = nil,
        beforeProvenancePublication: (() throws -> Void)? = nil
    ) async throws -> [String] {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let outputURL = URL(fileURLWithPath: output)
        let stagedOutputURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.lastPathComponent).export-staging-\(UUID().uuidString)"
            )
        defer {
            if FileManager.default.fileExists(atPath: stagedOutputURL.path) {
                try? FileManager.default.removeItem(at: stagedOutputURL)
            }
        }

        if FileManager.default.fileExists(atPath: outputURL.path), !force {
            throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
        }

        try beforeAnnotationSnapshot?()
        let loadedAnnotation = try loadSidecar(
            bundleURL: bundleURL
        )
        let sidecar = loadedAnnotation.sidecar
        let requiresFalseNegativeAuthority = format == .xlsx
            && viewProjection != nil
            && sidecar.matrixReviews.contains {
                $0.disposition == .falseNegative
            }
        let loadedResult: ONTGenotypeResultBundleData?
        if requiresFalseNegativeAuthority {
            loadedResult = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
            guard loadedResult?.reviewableRowCatalog != nil else {
                throw ValidationError(
                    "False-negative workbook export requires the bundle's attested reviewable-row catalog."
                )
            }
        } else {
            loadedResult = try? ONTGenotypeResultBundle.loadResult(from: bundleURL)
        }

        let writer = GenotypeXlsxWorkbookWriter()
        let resolvedColumns: [String]
        var nativeWriteReport: GenotypeXlsxWorkbookWriter.ViewProjectionWriteReport?
        var loadedProjection: LoadedViewProjection?

        if let projectionPath = viewProjection {
            // Reproduce exactly what the GUI rendered. The projection's
            // visible sample columns are intersected with any --sample
            // filters so the CLI never widens the view past what the GUI
            // showed.
            let projectionSnapshot = try loadProjection(at: projectionPath)
            loadedProjection = projectionSnapshot
            let filtered = filterProjection(projectionSnapshot.projection)
            resolvedColumns = filtered.sampleColumns
            switch format {
            case .xlsx:
                nativeWriteReport = try writer.writeViewProjection(
                    filtered,
                    to: stagedOutputURL,
                    annotations: sidecar,
                    reviewableRowCatalog: loadedResult?.reviewableRowCatalog
                )
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: ",")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: "\t")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            }
        } else {
            // No projection: export the full-bundle matrix.
            let matrix = makeMatrix(result: loadedResult, sidecar: sidecar)
            resolvedColumns = matrix.rows.map(\.sample)
            switch format {
            case .xlsx:
                let overrides = sidecar.callOverrides.map { o in
                    GenotypeXlsxWorkbookWriter.OverrideRow(
                        sample: o.sample, locus: o.locus, slot: o.slot.rawValue,
                        originalCall: o.originalCall, overrideCall: o.overrideCall,
                        reason: o.reasonTag.rawValue, rationale: o.rationale,
                        author: o.author, timestamp: o.timestamp
                    )
                }
                let audit = sidecar.auditLog.map { e in
                    GenotypeXlsxWorkbookWriter.AuditRow(
                        action: e.action, sample: e.sample,
                        locus: e.locus ?? "", slot: e.slot?.rawValue ?? "",
                        before: e.before ?? "", after: e.after ?? "",
                        author: e.author, timestamp: e.timestamp
                    )
                }
                try writer.writeMatrix(
                    to: stagedOutputURL,
                    matrix: matrix,
                    overrides: overrides,
                    audit: audit,
                    annotations: sidecar
                )
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: ",")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: "\t")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            }
        }

        try beforeOutputPublication?()
        try await publishStagedOutputAndProvenance(
            stagedOutputURL: stagedOutputURL,
            outputURL: outputURL
        ) {
            try beforeProvenancePublication?()
            try await recordProvenance(
                bundleURL: bundleURL,
                outputURL: outputURL,
                loadedResult: loadedResult,
                sidecar: sidecar,
                loadedAnnotation: loadedAnnotation,
                loadedProjection: loadedProjection,
                nativeWriteReport: nativeWriteReport,
                startedAt: startedAt
            )
        }

        emitSummary(bundleURL: bundleURL, outputURL: outputURL, resolvedColumns: resolvedColumns)
        return resolvedColumns
    }

    private func publishStagedOutputAndProvenance(
        stagedOutputURL: URL,
        outputURL: URL,
        recordProvenance: () async throws -> Void
    ) async throws {
        let fileManager = FileManager.default
        let outputDirectory = outputURL.deletingLastPathComponent()
        let publicationLock =
            try GenotypeExportDirectoryPublicationLock.acquire(
                in: outputDirectory
            )
        defer { publicationLock.release() }

        if !force, fileManager.fileExists(atPath: outputURL.path) {
            throw ValidationError(
                "Output file already exists: \(outputURL.path). Use --force to overwrite."
            )
        }
        let protectedURLs = [outputURL]
            + ProvenancePublicationArtifacts.bundleRootArtifacts(
                for: outputDirectory
            )
            + ProvenancePublicationArtifacts.fileSidecarArtifacts(
                for: outputURL
            )
        let snapshot = try ProvenancePublicationSnapshot(
            urls: protectedURLs,
            backupNamePrefix: "lungfish-genotype-export"
        )
        defer { snapshot.discard() }

        var publicationMutated = false
        do {
            if force, fileManager.fileExists(atPath: outputURL.path) {
                publicationMutated = true
                try fileManager.removeItem(at: outputURL)
            }
            if force {
                try fileManager.moveItem(at: stagedOutputURL, to: outputURL)
            } else {
                try moveItemExclusively(
                    from: stagedOutputURL,
                    to: outputURL
                )
            }
            publicationMutated = true
            try await recordProvenance()
        } catch {
            guard publicationMutated else {
                throw error
            }
            try throwAfterProvenancePublicationFailure(error) {
                try snapshot.restore()
            }
        }
    }

    private func moveItemExclusively(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST {
                throw ValidationError(
                    "Output file already exists: \(destinationURL.path). Use --force to overwrite."
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    // MARK: - Matrix / projection helpers

    private func makeMatrix(
        result: ONTGenotypeResultBundleData?,
        sidecar: GenotypeAnnotationSidecar
    ) -> GenotypeXlsxWorkbookWriter.Matrix {
        guard let result else {
            return GenotypeXlsxWorkbookWriter.Matrix(loci: [], rows: [])
        }
        let full = GenotypeXlsxWorkbookWriter.MatrixBuilder.build(from: result, sidecar: sidecar)
        guard !samples.isEmpty else { return full }
        let allowed = Set(samples)
        return GenotypeXlsxWorkbookWriter.Matrix(
            loci: full.loci,
            rows: full.rows.filter { allowed.contains($0.sample) }
        )
    }

    private struct LoadedViewProjection {
        let projection: GenotypeViewProjection
        let url: URL
        let data: Data
        let sha256: String
    }

    private func loadProjection(at path: String) throws -> LoadedViewProjection {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let data = try Data(contentsOf: url)
        return LoadedViewProjection(
            projection: try JSONDecoder().decode(
                GenotypeViewProjection.self,
                from: data
            ),
            url: url,
            data: data,
            sha256: Self.sha256Hex(data)
        )
    }

    private struct LoadedAnnotationSidecar {
        let sidecar: GenotypeAnnotationSidecar
        let url: URL?
        let data: Data?
        let sha256: String?
    }

    private func loadSidecar(
        bundleURL: URL
    ) throws -> LoadedAnnotationSidecar {
        let bundleSidecarURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: bundleURL)
            .standardizedFileURL
        if let annotations {
            let annotationURL = URL(fileURLWithPath: annotations)
                .standardizedFileURL
            if annotationURL == bundleSidecarURL {
                let snapshot = try ONTGenotypeResultBundleData
                    .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
                guard let data = snapshot.data else {
                    throw ValidationError(
                        "--annotations does not exist: \(annotationURL.path)"
                    )
                }
                return LoadedAnnotationSidecar(
                    sidecar: snapshot.sidecar,
                    url: bundleSidecarURL,
                    data: data,
                    sha256: Self.sha256Hex(data)
                )
            }
            let data: Data
            do {
                data = try Data(contentsOf: annotationURL)
            } catch {
                throw ValidationError(
                    "--annotations could not be read: \(annotationURL.path)"
                )
            }
            return LoadedAnnotationSidecar(
                sidecar: try GenotypeAnnotationSidecar.decode(data),
                url: annotationURL,
                data: data,
                sha256: Self.sha256Hex(data)
            )
        } else {
            let snapshot = try ONTGenotypeResultBundleData
                .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
            return LoadedAnnotationSidecar(
                sidecar: snapshot.sidecar,
                url: snapshot.data == nil ? nil : bundleSidecarURL,
                data: snapshot.data,
                sha256: snapshot.data.map(Self.sha256Hex)
            )
        }
    }

    /// Intersect the projection's columns with any `--sample` filters,
    /// preserving the projection's display order. An empty `--sample` set
    /// leaves the projection unchanged.
    private func filterProjection(_ projection: GenotypeViewProjection) -> GenotypeViewProjection {
        guard !samples.isEmpty else { return projection }
        let allowed = Set(samples)
        let keptIndices = projection.sampleColumns.enumerated()
            .filter { allowed.contains($0.element) }
            .map(\.offset)
        let keptColumns = keptIndices.map { projection.sampleColumns[$0] }
        let rows = projection.rows.map { row -> GenotypeViewProjectionRow in
            let cells = keptIndices.map { idx in idx < row.cells.count ? row.cells[idx] : "" }
            let colors: [String?]? = row.cellColorsHex.map { source in
                keptIndices.map { idx in idx < source.count ? source[idx] : nil }
            }
            return GenotypeViewProjectionRow(
                label: row.label,
                locus: row.locus,
                stableClusterID: row.stableClusterID,
                cells: cells,
                cellColorsHex: colors,
                rowColorHex: row.rowColorHex
            )
        }
        return GenotypeViewProjection(
            lens: projection.lens,
            sampleColumns: keptColumns,
            rows: rows,
            cellColorMode: projection.cellColorMode
        )
    }

    // MARK: - Provenance + summary

    private func recordProvenance(
        bundleURL: URL,
        outputURL: URL,
        loadedResult: ONTGenotypeResultBundleData?,
        sidecar: GenotypeAnnotationSidecar,
        loadedAnnotation: LoadedAnnotationSidecar,
        loadedProjection: LoadedViewProjection?,
        nativeWriteReport: GenotypeXlsxWorkbookWriter.ViewProjectionWriteReport?,
        startedAt: Date
    ) async throws {
        var command = [
            CLICommandIdentity.executableName, "genotype", "export",
            "--bundle", bundleURL.path,
            "--export-format", format.rawValue,
            "--output", outputURL.path,
        ]
        if let lens { command += ["--lens", lens] }
        if let minReads { command += ["--min-reads", String(minReads)] }
        if let filter { command += ["--filter", filter] }
        for sample in samples { command += ["--sample", sample] }
        if let activeHaplotypeDefinition {
            command += ["--active-haplotype-definition", activeHaplotypeDefinition]
        }
        var optionPaths: [String: URL] = [
            "bundle": bundleURL,
            "output": outputURL,
        ]
        var additionalInputURLs: [URL] = []
        var additionalInputRecords: [FileRecord] = []
        if let loadedProjection {
            let projectionURL = loadedProjection.url
            command += ["--view-projection", projectionURL.path]
            optionPaths["viewProjection"] = projectionURL
            additionalInputRecords.append(
                FileRecord(
                    path: projectionURL.path,
                    sha256: loadedProjection.sha256,
                    sizeBytes: UInt64(loadedProjection.data.count),
                    format: .json,
                    role: .input
                )
            )
        }
        if let annotationURL = loadedAnnotation.url {
            command += ["--annotations", annotationURL.path]
            optionPaths["annotations"] = annotationURL
            if let data = loadedAnnotation.data,
               let sha256 = loadedAnnotation.sha256 {
                additionalInputRecords.append(
                    FileRecord(
                        path: annotationURL.path,
                        sha256: sha256,
                        sizeBytes: UInt64(data.count),
                        format: .json,
                        role: .input
                    )
                )
            }
        }
        if force {
            command.append("--force")
        }
        if let activeDefinitionURL = loadedResult.flatMap({
            GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                for: $0,
                bundleURL: bundleURL,
                sidecar: sidecar
            )
        }) {
            additionalInputURLs.append(activeDefinitionURL)
        }
        if let reference = loadedResult?.manifest.reviewableRowCatalog {
            let catalogURL = ONTGenotypeResultBundle.resolvedURL(
                for: reference.path,
                in: bundleURL
            )
            optionPaths["reviewableRowCatalog"] = catalogURL
            additionalInputRecords.append(
                FileRecord(
                    path: catalogURL.path,
                    sha256: reference.sha256,
                    sizeBytes: UInt64(clamping: reference.sizeBytes),
                    format: .json,
                    role: .input
                )
            )
        }
        var explicitOptions: [String: ParameterValue] = [
            "exportFormat": .string(format.rawValue),
            "samples": .array(samples.map { .string($0) }),
            "force": .boolean(force),
        ]
        if let lens {
            explicitOptions["lens"] = .string(lens)
        }
        if let minReads {
            explicitOptions["minReads"] = .integer(minReads)
        }
        if let filter {
            explicitOptions["filter"] = .string(filter)
        }
        if let activeHaplotypeDefinition {
            explicitOptions["activeHaplotypeDefinition"] = .string(activeHaplotypeDefinition)
        }
        var resolvedOptions = explicitOptions
        if let nativeWriteReport {
            resolvedOptions["nativeWorkbookAdapterVersion"] = .string(
                nativeWriteReport.adapterVersion
            )
            resolvedOptions["nativeFalseNegativeSynthesisDecisions"] = .array(
                nativeWriteReport.synthesizedRows.map(Self.parameterValue)
            )
            resolvedOptions["nativeFalseNegativeTargetCellDecisions"] = .array(
                nativeWriteReport.targetCells.map(Self.parameterValue)
            )
            resolvedOptions["nativeFalseNegativeRestorationDecision"] = .string(
                nativeWriteReport.restorationDecision
            )
        }
        if loadedAnnotation.url != nil,
           let annotationSHA256 = loadedAnnotation.sha256 {
            resolvedOptions["annotationSidecarRevisionSHA256"] = .string(
                annotationSHA256
            )
            resolvedOptions["annotationSidecarSchemaVersion"] = .integer(
                sidecar.schemaVersion
            )
        }
        if let reference = loadedResult?.manifest.reviewableRowCatalog,
           let catalog = loadedResult?.reviewableRowCatalog {
            resolvedOptions["reviewableRowCatalogDescriptor"] = .dictionary([
                "path": .string(reference.path),
                "sizeBytes": .integer(Int(clamping: reference.sizeBytes)),
                "sha256": .string(reference.sha256),
                "schemaID": .string(catalog.schemaID),
                "schemaVersion": .integer(catalog.schemaVersion),
            ])
        }

        try await GenotypeExportProvenanceSupport.record(
            workflowName: "lungfish genotype export",
            toolName: CLICommandIdentity.executableName,
            command: command,
            bundleURL: bundleURL,
            outputURLs: [outputURL],
            outputDirectory: outputURL.deletingLastPathComponent(),
            optionPaths: optionPaths,
            explicitOptions: explicitOptions,
            defaults: [
                "exportFormat": .string(ExportFormat.xlsx.rawValue),
                "lens": .null,
                "minReads": .null,
                "filter": .null,
                "samples": .array([]),
                "activeHaplotypeDefinition": .null,
                "viewProjection": .null,
                "annotations": .string("bundle annotations.json when present"),
                "reviewableRowCatalog": .string(
                    "manifest-attested catalog when false-negative projection reviews exist"
                ),
                "force": .boolean(false),
            ],
            resolvedOptions: resolvedOptions,
            additionalInputURLs: additionalInputURLs,
            additionalInputRecords: additionalInputRecords,
            excludedInputURLs: [
                ONTGenotypeResultBundleData.annotationSidecarURL(
                    forBundleAt: bundleURL
                ),
            ],
            startedAt: startedAt
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func parameterValue(
        _ decision: GenotypeXlsxWorkbookWriter.NativeSynthesizedRowDecision
    ) -> ParameterValue {
        .dictionary([
            "identity": .dictionary([
                "kind": .string(decision.identity.kind),
                "callID": .string(decision.identity.callID),
                "displayName": .string(decision.identity.displayName),
                "locus": .string(decision.identity.locus),
                "stableID": decision.identity.stableID.map(ParameterValue.string)
                    ?? .null,
            ]),
            "cells": .array(decision.cells.map(ParameterValue.string)),
        ])
    }

    private static func parameterValue(
        _ decision: GenotypeXlsxWorkbookWriter.NativeTargetCellDecision
    ) -> ParameterValue {
        .dictionary([
            "target": .dictionary(targetFields(decision.target)),
            "cell": decision.cell.map(ParameterValue.string) ?? .null,
            "status": .string(decision.status),
            "reason": .string(decision.reason),
            "synthetic": .boolean(decision.synthetic),
            "presentationPrecedence": .string(
                decision.presentationPrecedence
            ),
        ])
    }

    private static func targetFields(
        _ target: GenotypeAnnotationSidecar.MatrixTarget
    ) -> [String: ParameterValue] {
        switch target {
        case let .row(locus, genotype, stableClusterID):
            return [
                "kind": .string("row"),
                "locus": .string(locus),
                "genotype": .string(genotype),
                "stableClusterID":
                    stableClusterID.map(ParameterValue.string) ?? .null,
            ]
        case let .column(sample):
            return [
                "kind": .string("column"),
                "sample": .string(sample),
            ]
        case let .cell(locus, genotype, sample, stableClusterID):
            return [
                "kind": .string("cell"),
                "sample": .string(sample),
                "locus": .string(locus),
                "genotype": .string(genotype),
                "stableClusterID":
                    stableClusterID.map(ParameterValue.string) ?? .null,
            ]
        }
    }

    private func emitSummary(bundleURL: URL, outputURL: URL, resolvedColumns: [String]) {
        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "format": format.rawValue,
            "sampleColumns": resolvedColumns,
            "usedProjection": viewProjection != nil,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
