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

private final class GenotypeExportRollbackWitnessTracker:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private let afterMutation:
        ((ProvenanceWriterMutation) throws -> Void)?
    private let beforeObservation:
        ((ProvenanceWriterMutation) throws -> Void)?
    private var witness: ProvenancePublicationRollbackWitness

    init(
        snapshot: ProvenancePublicationSnapshot,
        beforeObservation:
            ((ProvenanceWriterMutation) throws -> Void)?,
        afterMutation:
            ((ProvenanceWriterMutation) throws -> Void)?
    ) throws {
        self.snapshot = snapshot
        self.beforeObservation = beforeObservation
        self.afterMutation = afterMutation
        witness = try snapshot.captureRollbackWitness()
    }

    var currentWitness: ProvenancePublicationRollbackWitness {
        lock.withLock { witness }
    }

    func observe(
        _ mutation: ProvenanceWriterMutation
    ) throws {
        try beforeObservation?(mutation)
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(
                witness,
                after: mutation
            )
        }
        do {
            try afterMutation?(mutation)
        } catch {
            throw ProvenanceWriterMutationAcceptedError(error)
        }
    }

    func publishReplacement(
        from stagedURL: URL,
        to destinationURL: URL,
        replacingExisting: Bool,
        beforeExistingArtifactClaim: (() throws -> Void)?
    ) throws -> URL? {
        let publication = try snapshot.publishReplacement(
            from: stagedURL,
            to: destinationURL,
            replacingExisting: replacingExisting,
            witness: currentWitness,
            beforeExistingArtifactClaim:
                beforeExistingArtifactClaim
        )
        lock.withLock { witness = publication.witness }
        return publication.displacedURL
    }
}

/// Unified genotype-bundle export.
///
/// Where `export-xlsx` / `export-pivot-xlsx` / `export-labkey` are each
/// flagless single-shape exporters, this command takes the same lens /
/// filter flags the 12S exporter exposes plus an optional
/// `--view-projection <path>` describing exactly what the GUI viewport
/// rendered (visible sample columns, rows, cell/row colors). When a
/// projection is supplied the produced report reproduces that captured view.
/// XLSX routes use the immutable scientific snapshot service; CSV and TSV
/// retain their existing delimiter renderer and publication path.
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

    @Option(name: .customLong("min-percent"), help: "Drop calls below this support percent in the Filtered XLSX matrix.")
    var minPercent: Double?

    @Option(name: .customLong("percent-basis"), help: "Known-call denominator for --min-percent: viewed-locus or sample-retained.")
    var percentBasis: GenotypeExportPivotXlsxSubcommand.PercentBasis = .viewedLocus

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
        if let minReads, minReads < 0 {
            throw ValidationError("--min-reads must not be negative.")
        }
        if let minPercent, minPercent < 0 || minPercent > 100 {
            throw ValidationError("--min-percent must be between 0 and 100.")
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
        beforeOutputReplacementClaim: (() throws -> Void)? = nil,
        beforeProvenancePublication: (() throws -> Void)? = nil,
        beforeProvenanceArtifactObservation:
            ((ProvenanceWriterMutation) throws -> Void)? = nil,
        afterProvenanceArtifactPublication:
            ((ProvenanceWriterMutation) throws -> Void)? = nil,
        afterRollbackArtifactDetached: ((URL) throws -> Void)? = nil,
        afterExcelManifestDecode: (@Sendable () throws -> Void)? = nil,
        afterExcelAuthorityCapture: (@Sendable () throws -> Void)? = nil,
        managedPythonResolver: @escaping @Sendable () async throws -> URL = {
            try await CondaManager.shared.toolPath(
                name: "python",
                environment: "openpyxl"
            )
        }
    ) async throws -> [String] {
        if format == .xlsx {
            return try await runExcel(
                afterManifestDecode: afterExcelManifestDecode,
                afterAuthorityCapture: afterExcelAuthorityCapture,
                managedPythonResolver: managedPythonResolver
            )
        }
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
        let loadedResult = try? ONTGenotypeResultBundle.loadResult(from: bundleURL)

        let resolvedColumns: [String]
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
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: ",")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: "\t")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .xlsx:
                preconditionFailure("XLSX is routed before delimiter export")
            }
        } else {
            // No projection: export the full-bundle matrix.
            let matrix = makeMatrix(result: loadedResult, sidecar: sidecar)
            resolvedColumns = matrix.rows.map(\.sample)
            switch format {
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: ",")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: "\t")
                    .write(to: stagedOutputURL, atomically: true, encoding: .utf8)
            case .xlsx:
                preconditionFailure("XLSX is routed before delimiter export")
            }
        }

        try beforeOutputPublication?()
        try await publishStagedOutputAndProvenance(
            stagedOutputURL: stagedOutputURL,
            outputURL: outputURL,
            beforeOutputReplacementClaim:
                beforeOutputReplacementClaim,
            beforeProvenanceArtifactObservation:
                beforeProvenanceArtifactObservation,
            afterProvenanceArtifactPublication:
                afterProvenanceArtifactPublication,
            afterRollbackArtifactDetached: afterRollbackArtifactDetached
        ) { publicationArtifactDidWrite in
            try beforeProvenancePublication?()
            try await recordProvenance(
                bundleURL: bundleURL,
                outputURL: outputURL,
                loadedResult: loadedResult,
                sidecar: sidecar,
                loadedAnnotation: loadedAnnotation,
                loadedProjection: loadedProjection,
                startedAt: startedAt,
                publicationArtifactDidWrite: publicationArtifactDidWrite
            )
        }

        emitSummary(bundleURL: bundleURL, outputURL: outputURL, resolvedColumns: resolvedColumns)
        return resolvedColumns
    }

    private func runExcel(
        afterManifestDecode: (@Sendable () throws -> Void)?,
        afterAuthorityCapture: (@Sendable () throws -> Void)?,
        managedPythonResolver: @escaping @Sendable () async throws -> URL
    ) async throws -> [String] {
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
            .standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let projectionURL = viewProjection.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let annotationURL = annotations.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let reads = minReads ?? 0
        let percent = minPercent ?? 0
        let scientificFilter = GenotypeMatrixBaseProjection.Filter(
            matrixMinimumReads: reads,
            matrixMinimumPercent: percent,
            matrixDenominator: percentBasis.denominator
        )
        var argv = [
            CLICommandIdentity.executableName, "genotype", "export",
            "--bundle", bundleURL.path,
            "--export-format", ExportFormat.xlsx.rawValue,
            "--output", outputURL.path,
        ]
        if let lens { argv += ["--lens", lens] }
        if let minReads { argv += ["--min-reads", String(minReads)] }
        if let minPercent {
            argv += [
                "--min-percent", String(minPercent),
                "--percent-basis", percentBasis.rawValue,
            ]
        }
        if let filter { argv += ["--filter", filter] }
        for sample in samples { argv += ["--sample", sample] }
        if let activeHaplotypeDefinition {
            argv += ["--active-haplotype-definition", activeHaplotypeDefinition]
        }
        if let projectionURL { argv += ["--view-projection", projectionURL.path] }
        if let annotationURL { argv += ["--annotations", annotationURL.path] }
        if force { argv.append("--force") }

        let outcome = try await GenotypeExcelCLIExportSupport.export(
            .init(
                bundleURL: bundleURL,
                outputURL: outputURL,
                annotationURL: annotationURL,
                projectionURL: projectionURL,
                samples: samples,
                activeHaplotypeDefinitionID: activeHaplotypeDefinition,
                filter: scientificFilter,
                workflowName: "lungfish genotype export",
                argv: GenotypeExcelCLIExportSupport.invocation(fallback: argv),
                options: [
                    "bundle": bundleURL.path,
                    "output": outputURL.path,
                    "exportFormat": ExportFormat.xlsx.rawValue,
                    "lens": lens ?? "none",
                    "minReads": String(reads),
                    "minPercent": String(percent),
                    "percentBasis": percentBasis.rawValue,
                    "namedFilter": filter ?? "none",
                    "sampleScope": samples.isEmpty ? "all" : samples.joined(separator: ","),
                    "activeHaplotypeDefinition": activeHaplotypeDefinition ?? "captured bundle authority",
                    "viewProjection": projectionURL?.path ?? "none",
                    "annotations": annotationURL?.path ?? "bundle annotations.json when present",
                    "force": String(force),
                    "filteredEvidenceRowPolicy": GenotypeExcelSnapshotBuilder.filteredEvidenceRowPolicy,
                ],
                defaults: [
                    "exportFormat": ExportFormat.xlsx.rawValue,
                    "lens": "none",
                    "minReads": "0",
                    "minPercent": "0",
                    "percentBasis": GenotypeExportPivotXlsxSubcommand.PercentBasis.viewedLocus.rawValue,
                    "namedFilter": "none",
                    "sampleScope": "all",
                    "activeHaplotypeDefinition": "captured bundle authority",
                    "viewProjection": "none",
                    "annotations": "bundle annotations.json when present",
                    "force": "false",
                ],
                runtimeContext: [
                    "candidatePercentBasis": "positive supporting samples / full logical sample roster",
                    "knownPercentBasis": percentBasis.denominator.rawValue,
                    "namedFilterSemantics": "descriptive captured viewport label; numeric filters are authoritative",
                ],
                replacingExisting: force
            ),
            afterManifestDecode: afterManifestDecode,
            afterAuthorityCapture: afterAuthorityCapture,
            managedPythonResolver: managedPythonResolver
        )
        emitExcelSummary(bundleURL: bundleURL, outcome: outcome)
        return outcome.visibleSamples
    }

    private func publishStagedOutputAndProvenance(
        stagedOutputURL: URL,
        outputURL: URL,
        beforeOutputReplacementClaim: (() throws -> Void)?,
        beforeProvenanceArtifactObservation:
            ((ProvenanceWriterMutation) throws -> Void)?,
        afterProvenanceArtifactPublication:
            ((ProvenanceWriterMutation) throws -> Void)?,
        afterRollbackArtifactDetached: ((URL) throws -> Void)?,
        recordProvenance: (
            _ publicationArtifactDidWrite:
                @escaping @Sendable (ProvenanceWriterMutation) throws -> Void
        ) async throws -> Void
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
        let rollbackWitnessTracker = try GenotypeExportRollbackWitnessTracker(
            snapshot: snapshot,
            beforeObservation:
                beforeProvenanceArtifactObservation,
            afterMutation: afterProvenanceArtifactPublication
        )
        var displacedOutputURL: URL?
        do {
            displacedOutputURL =
                try rollbackWitnessTracker.publishReplacement(
                    from: stagedOutputURL,
                    to: outputURL,
                    replacingExisting: force,
                    beforeExistingArtifactClaim:
                        beforeOutputReplacementClaim
                )
            publicationMutated = true
            try await recordProvenance { mutation in
                try rollbackWitnessTracker.observe(mutation)
            }
            if let displaced = displacedOutputURL {
                try fileManager.removeItem(at: displaced)
                displacedOutputURL = nil
            }
        } catch {
            guard publicationMutated else {
                throw error
            }
            try throwAfterProvenancePublicationFailure(error) {
                let preserved: [URL]
                do {
                    preserved = try snapshot.restore(
                        ifCurrentMatches:
                            rollbackWitnessTracker.currentWitness,
                        afterArtifactDetached:
                            afterRollbackArtifactDetached
                    )
                } catch {
                    guard let displacedOutputURL else {
                        throw error
                    }
                    throw ProvenancePublicationRollbackError(
                        originalError: error,
                        rollbackError:
                            ProvenancePublicationPreservedChangesError(
                                urls: [displacedOutputURL]
                            )
                    )
                }
                if !preserved.isEmpty {
                    let preservedURLs = preserved
                        + (displacedOutputURL.map { [$0] } ?? [])
                    throw ProvenancePublicationPreservedChangesError(
                        urls: preservedURLs
                    )
                }
                if let displacedOutputURL {
                    do {
                        try fileManager.removeItem(
                            at: displacedOutputURL
                        )
                    } catch {
                        throw ProvenancePublicationRollbackError(
                            originalError: error,
                            rollbackError:
                                ProvenancePublicationPreservedChangesError(
                                    urls: [displacedOutputURL]
                                )
                        )
                    }
                }
            }
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
                rawGenotype: row.rawGenotype,
                locus: row.locus,
                stableClusterID: row.stableClusterID,
                cells: cells,
                cellColorsHex: colors,
                rowColorHex: row.rowColorHex,
                rowStyle: row.rowStyle,
                cellStyles: row.cellStyles.map { source in keptIndices.map { $0 < source.count ? source[$0] : nil } }
            )
        }
        return GenotypeViewProjection(
            lens: projection.lens,
            sampleColumns: keptColumns,
            rows: rows,
            cellColorMode: projection.cellColorMode,
            genotypeLocusDisplayOrder: projection.genotypeLocusDisplayOrder,
            genotypeNumericPrefixOrder: projection.genotypeNumericPrefixOrder,
            diagnosticAllelesOnly: projection.diagnosticAllelesOnly,
            includeTotalReads: projection.includeTotalReads
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
        startedAt: Date,
        publicationArtifactDidWrite:
            (@Sendable (ProvenanceWriterMutation) throws -> Void)? = nil
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
        if let order = loadedProjection?.projection.genotypeLocusDisplayOrder {
            explicitOptions["genotypeLocusDisplayOrder"] = .array(order.map(ParameterValue.string))
        }
        if let numericOrder = loadedProjection?.projection.genotypeNumericPrefixOrder {
            explicitOptions["genotypeNumericPrefixOrder"] = .boolean(numericOrder)
        }
        if let projection = loadedProjection?.projection {
            explicitOptions["diagnosticAllelesOnly"] = .boolean(projection.diagnosticAllelesOnly ?? false)
            explicitOptions["includeTotalReads"] = .boolean(projection.includeTotalReads ?? false)
            if let colorMode = projection.cellColorMode {
                explicitOptions["cellColorMode"] = .string(colorMode)
            }
        }
        var resolvedOptions = explicitOptions
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
            startedAt: startedAt,
            publicationArtifactDidWrite: publicationArtifactDidWrite
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
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

    private func emitExcelSummary(
        bundleURL: URL,
        outcome: GenotypeExcelCLIExportSupport.Outcome
    ) {
        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outcome.result.outputURL.path,
            "receipt": outcome.result.receiptURL.path,
            "snapshot": outcome.result.snapshotURL.path,
            "replay": outcome.result.replayScriptURL.path,
            "format": ExportFormat.xlsx.rawValue,
            "sampleColumns": outcome.visibleSamples,
            "usedProjection": viewProjection != nil,
            "hasHaplotypeContent": outcome.hasHaplotypeContent,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.sortedKeys]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
