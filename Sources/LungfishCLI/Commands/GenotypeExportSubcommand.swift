import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

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
    func runReturningResolvedColumns() async throws -> [String] {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let outputURL = URL(fileURLWithPath: output)

        if FileManager.default.fileExists(atPath: outputURL.path), !force {
            throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
        }

        let annotationURL = resolvedAnnotationURL(bundleURL: bundleURL)
        let sidecar = try loadSidecar(bundleURL: bundleURL, annotationURL: annotationURL)
        let loadedResult = try? ONTGenotypeResultBundle.loadResult(from: bundleURL)

        let writer = GenotypeXlsxWorkbookWriter()
        let resolvedColumns: [String]

        if let projectionPath = viewProjection {
            // Reproduce exactly what the GUI rendered. The projection's
            // visible sample columns are intersected with any --sample
            // filters so the CLI never widens the view past what the GUI
            // showed.
            let projection = try loadProjection(at: projectionPath)
            let filtered = filterProjection(projection)
            resolvedColumns = filtered.sampleColumns
            switch format {
            case .xlsx:
                try writer.writeViewProjection(filtered, to: outputURL, annotations: sidecar)
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: ",")
                    .write(to: outputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(filtered, separator: "\t")
                    .write(to: outputURL, atomically: true, encoding: .utf8)
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
                    to: outputURL,
                    matrix: matrix,
                    overrides: overrides,
                    audit: audit,
                    annotations: sidecar
                )
            case .csv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: ",")
                    .write(to: outputURL, atomically: true, encoding: .utf8)
            case .tsv:
                try GenotypeXlsxWorkbookWriter
                    .renderDelimited(matrix, separator: "\t")
                    .write(to: outputURL, atomically: true, encoding: .utf8)
            }
        }

        try await recordProvenance(
            bundleURL: bundleURL,
            outputURL: outputURL,
            loadedResult: loadedResult,
            sidecar: sidecar,
            startedAt: startedAt
        )

        emitSummary(bundleURL: bundleURL, outputURL: outputURL, resolvedColumns: resolvedColumns)
        return resolvedColumns
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

    private func loadProjection(at path: String) throws -> GenotypeViewProjection {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GenotypeViewProjection.self, from: data)
    }

    private func resolvedAnnotationURL(bundleURL: URL) -> URL? {
        if let annotations {
            return URL(fileURLWithPath: annotations).standardizedFileURL
        }
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        return sidecarURL.standardizedFileURL
    }

    private func loadSidecar(
        bundleURL: URL,
        annotationURL: URL?
    ) throws -> GenotypeAnnotationSidecar {
        guard let annotationURL else {
            return try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        }
        guard FileManager.default.fileExists(atPath: annotationURL.path) else {
            throw ValidationError("--annotations does not exist: \(annotationURL.path)")
        }
        return try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL))
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
        if let viewProjection {
            let projectionURL = URL(fileURLWithPath: viewProjection)
            command += ["--view-projection", projectionURL.path]
            optionPaths["viewProjection"] = projectionURL
            additionalInputURLs.append(projectionURL)
        }
        if let annotationURL = resolvedAnnotationURL(bundleURL: bundleURL) {
            command += ["--annotations", annotationURL.path]
            optionPaths["annotations"] = annotationURL
            additionalInputURLs.append(annotationURL)
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
                "force": .boolean(false),
            ],
            additionalInputURLs: additionalInputURLs,
            startedAt: startedAt
        )
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
