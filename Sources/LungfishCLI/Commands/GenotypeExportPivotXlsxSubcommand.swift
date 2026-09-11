import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Exports the genotype bundle as a "pivot" XLSX matching the layout used
/// by the lab's notebook-style collaborator template.
///
/// Sheet layout (single sheet, named after the bundle's analysis):
///
///     Row 1: "Animal ID" |  -  |  -  | sample1 | sample2 | ...
///     Row 2: "GS ID"     | Total | Average | sample1 | sample2 | ...
///     Row 3: "Mapped Read Count" | total | average | per-sample counts
///     Row 4: "total_read_count"  |   -   |   -    | per-sample counts
///     Row 5: "percent_reads_unmapped" | - | - | per-sample %
///     Rows 6-19: "MHC-X Haplotype {1,2}" — 14 rows (A,B,DRB,DQA,DQB,DPA,DPB
///                × H1,H2) populated from `haplotypeAnalysis` if present.
///     Row 20: "Comments" | "Subtotal" | "# Obs." | per-sample noncalled
///             haplotype summary
///     Rows 21+: Allele groups. Each group starts with a bold "{species}-X
///             alleles" header row, followed by allele rows sorted by name.
///             Per-sample values are the `passed_unique_reads` count for that
///             allele in that sample (blank if zero).
///
/// Read counts honour the dropout-filtered evaluator (currently
/// `GenotypeDropoutEvaluator` with no thresholds — the persisted analysis
/// is authoritative for haplotype calls). Future work could expose CLI
/// flags to pass per-locus thresholds the same way the inspector does.
///
/// This is provenance-`inspectOnly` (`cli.genotype` policy) — it never
/// modifies the bundle or its sidecar.
struct GenotypeExportPivotXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-pivot-xlsx",
        abstract: "Export the genotype bundle as a pivot-format XLSX (samples across, alleles down)."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    @Option(
        name: .long,
        help: """
        Drop allele values supported by fewer than this many reads. \
        Mirrors the inspector's Min Reads control; 0 disables the filter.
        """
    )
    var minReads: Int = 0

    @Option(
        name: .long,
        help: """
        Drop allele values below this percent of the sample's retained reads. \
        Mirrors the inspector's Min Percent control; 0 disables the filter.
        """
    )
    var minPercent: Double = 0

    @Flag(
        name: .long,
        help: "Keep allele rows that are empty after filtering instead of removing them."
    )
    var keepEmptyRows: Bool = false

    @Option(
        name: .long,
        help: """
        Denominator for --min-percent: 'sample-retained' (the sample's retained \
        reads) or 'viewed-locus' (the sample's reads at the allele's locus, as \
        the inspector's Viewed Locus basis).
        """
    )
    var percentBasis: PivotWorkbookBuilder.PercentBasis = .sampleRetained

    @Option(
        name: .long,
        help: """
        Workbook to copy and filter. Defaults to the bundle's current.xlsx when \
        one exists, else its primary workbook. The export is that workbook with \
        only the pivot sheet changed; when the bundle has no workbook a pivot-only \
        workbook is written instead.
        """
    )
    var sourceWorkbook: String?

    @Option(
        name: .long,
        help: "Serialized genotype viewport whose visible samples, rows, and cell values define the filtered pivot."
    )
    var viewProjection: String?

    @Option(
        name: .long,
        help: "Genotype annotation sidecar supplying visible false-positive, false-negative, and comment annotations."
    )
    var annotations: String?

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty.")
        }
        if minReads < 0 {
            throw ValidationError("--min-reads must not be negative.")
        }
        if minPercent < 0 || minPercent > 100 {
            throw ValidationError("--min-percent must be between 0 and 100.")
        }
    }

    func run() async throws {
        try await run(managedPythonResolver: {
            try await CondaManager.shared.toolPath(name: "python", environment: "openpyxl")
        })
    }

    /// `managedPythonResolver` locates the managed openpyxl runtime used to
    /// rewrite the pivot sheet of a copied workbook; tests inject it.
    func run(
        managedPythonResolver: @escaping @Sendable () async throws -> URL
    ) async throws {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        // Pick up any analyst-saved dropout/per-locus EQ from the bundle
        // sidecar so the pivot xlsx reflects the same calls the GUI shows
        // — without requiring the analyst to re-export from the inspector.
        let requestedAnnotationURL = annotations.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let bundleAnnotationURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: bundleURL)
            .standardizedFileURL
        let annotationURL: URL?
        let annotationData: Data?
        let sidecar: GenotypeAnnotationSidecar?
        if let requestedAnnotationURL, requestedAnnotationURL != bundleAnnotationURL {
            let data = try Data(contentsOf: requestedAnnotationURL)
            annotationURL = requestedAnnotationURL
            annotationData = data
            sidecar = try GenotypeAnnotationSidecar.decode(data)
        } else {
            let snapshot = try ONTGenotypeResultBundleData
                .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
            annotationURL = snapshot.data == nil ? nil : bundleAnnotationURL
            annotationData = snapshot.data
            sidecar = snapshot.data == nil ? nil : snapshot.sidecar
        }
        let projectionURL = viewProjection.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let projectionData = try projectionURL.map { try Data(contentsOf: $0) }
        let projection = try projectionData.map {
            try JSONDecoder().decode(GenotypeViewProjection.self, from: $0)
        }
        let capturedInputRecords = [
            Self.capturedInputRecord(url: projectionURL, data: projectionData),
            Self.capturedInputRecord(url: annotationURL, data: annotationData),
        ].compactMap { $0 }
        let thresholds = PivotWorkbookBuilder.Thresholds(
            minimumReads: minReads,
            minimumPercent: minPercent,
            keepEmptyRows: keepEmptyRows,
            percentBasis: percentBasis
        )
        let outputURL = URL(fileURLWithPath: output)
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-genotype-pivot-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        if let sourceWorkbookURL = Self.resolveSourceWorkbookURL(
            explicit: sourceWorkbook,
            bundleURL: bundleURL,
            manifest: result.manifest
        ) {
            try await exportFilteredCopy(
                of: sourceWorkbookURL,
                result: result,
                sidecar: sidecar,
                thresholds: thresholds,
                projection: projection,
                projectionURL: projectionURL,
                annotationURL: annotationURL,
                capturedInputRecords: capturedInputRecords,
                bundleURL: bundleURL,
                outputURL: outputURL,
                buildDir: buildDir,
                managedPythonResolver: managedPythonResolver,
                startedAt: startedAt
            )
            return
        }

        if projection != nil {
            throw ValidationError("A source workbook is required for a viewport-projected pivot export.")
        }

        let workbook = PivotWorkbookBuilder.build(
            from: result,
            sidecar: sidecar,
            thresholds: thresholds
        )
        try Self.writeXLSX(to: outputURL, buildDir: buildDir, workbook: workbook)
        var command = [
            CLICommandIdentity.executableName, "genotype", "export-pivot-xlsx",
            "--bundle", bundle,
            "--output", output,
        ]
        if let annotations {
            command += ["--annotations", annotations]
        }
        command += thresholds.provenanceArguments
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "genotype.export.pivot-xlsx",
            toolName: "lungfish genotype export-pivot-xlsx",
            command: command,
            bundleURL: bundleURL,
            outputURLs: [outputURL],
            outputDirectory: outputURL.deletingLastPathComponent(),
            optionPaths: [
                "bundle": bundleURL,
                "output": outputURL,
            ].merging(
                annotations == nil ? [:] : (annotationURL.map { ["annotations": $0] } ?? [:])
            ) { _, new in new },
            explicitOptions: provenanceExplicitOptions(thresholds: thresholds),
            defaults: provenanceDefaults,
            resolvedOptions: provenanceOptions(
                thresholds: thresholds, sourceWorkbookURL: nil,
                projectionURL: nil, annotationURL: annotationURL
            ),
            additionalInputURLs: GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                for: result,
                bundleURL: bundleURL,
                sidecar: sidecar
            ).map { [$0] } ?? [],
            additionalInputRecords: capturedInputRecords,
            excludedInputURLs: capturedInputRecords.map { URL(fileURLWithPath: $0.path) },
            startedAt: startedAt
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "sampleCount": workbook.samples.count,
            "alleleCount": workbook.alleleRowCount,
            "alleleGroupCount": workbook.groups.count,
            "haplotypeAnalysisPresent": result.haplotypeAnalysis != nil,
            "minReads": thresholds.minimumReads,
            "minPercent": thresholds.minimumPercent,
            "filteredAlleleValueCount": workbook.filteredValueCount,
            "removedAlleleRowCount": workbook.removedRowCount
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(summaryData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private var provenanceDefaults: [String: ParameterValue] {
        [
            "minReads": .integer(0),
            "minPercent": .number(0),
            "keepEmptyRows": .boolean(false),
            "percentBasis": .string(PivotWorkbookBuilder.PercentBasis.sampleRetained.rawValue),
            "sourceWorkbook": .null,
            "viewProjection": .null,
            "annotations": .null,
        ]
    }

    private func provenanceOptions(
        thresholds: PivotWorkbookBuilder.Thresholds,
        sourceWorkbookURL: URL?,
        projectionURL: URL?,
        annotationURL: URL?
    ) -> [String: ParameterValue] {
        [
            "minReads": .integer(thresholds.minimumReads),
            "minPercent": .number(thresholds.minimumPercent),
            "keepEmptyRows": .boolean(thresholds.keepEmptyRows),
            "percentBasis": .string(thresholds.percentBasis.rawValue),
            "sourceWorkbook": sourceWorkbookURL.map(ParameterValue.file) ?? .null,
            "viewProjection": projectionURL.map(ParameterValue.file) ?? .null,
            "annotations": annotationURL.map(ParameterValue.file) ?? .null,
        ]
    }

    private func provenanceExplicitOptions(
        thresholds: PivotWorkbookBuilder.Thresholds
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [:]
        if thresholds.minimumReads != 0 {
            options["minReads"] = .integer(thresholds.minimumReads)
        }
        if thresholds.minimumPercent != 0 {
            options["minPercent"] = .number(thresholds.minimumPercent)
        }
        if thresholds.keepEmptyRows {
            options["keepEmptyRows"] = .boolean(true)
        }
        if thresholds.percentBasis != .sampleRetained {
            options["percentBasis"] = .string(thresholds.percentBasis.rawValue)
        }
        if let sourceWorkbook {
            options["sourceWorkbook"] = .file(URL(fileURLWithPath: sourceWorkbook))
        }
        if let viewProjection {
            options["viewProjection"] = .file(URL(fileURLWithPath: viewProjection))
        }
        if let annotations {
            options["annotations"] = .file(URL(fileURLWithPath: annotations))
        }
        return options
    }

    private static func capturedInputRecord(url: URL?, data: Data?) -> FileRecord? {
        guard let url, let data else { return nil }
        return FileRecord(
            path: url.path,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: UInt64(data.count),
            format: .json,
            role: .input
        )
    }

    // MARK: - Workbook shape

    struct PivotWorkbook: Equatable {
        let sheetName: String
        let samples: [String]
        /// Per-sample mapped read count (passed alignments after filtering).
        let mappedReadCounts: [Int?]
        /// Per-sample total reads from the sample summary (input).
        let totalReadCounts: [Int?]
        /// Per-sample percent of reads unmapped (`100 - retained_percent`).
        let percentReadsUnmapped: [Double?]
        /// 14 haplotype rows in canonical order (A H1/H2 ... DPB H1/H2).
        /// Each entry: row label, per-sample call (nil = blank).
        let haplotypeRows: [HaplotypeRow]
        /// Per-sample non-called haplotype summary string for the Comments row.
        let commentsRow: [String?]
        /// Allele groups in canonical numeric-prefix order.
        let groups: [AlleleGroup]
        /// Allele values suppressed by the Min Reads / Min Percent thresholds.
        var filteredValueCount: Int = 0
        /// Allele rows removed because every value fell below the thresholds.
        var removedRowCount: Int = 0

        var alleleRowCount: Int { groups.reduce(0) { $0 + $1.alleles.count } }
    }

    struct HaplotypeRow: Equatable {
        let label: String
        /// Per-sample call (matches `samples` order).
        let values: [String?]
    }

    struct AlleleGroup: Equatable {
        let label: String
        let alleles: [AlleleRow]
    }

    struct AlleleRow: Equatable {
        let name: String
        /// Per-sample read count; `nil` means blank (zero).
        let counts: [Int?]
    }

    // MARK: - Building the workbook

    enum PivotWorkbookBuilder {
        /// Background-suppression thresholds mirroring the inspector's
        /// Min Reads and Min Percent controls.
        ///
        /// Analysts otherwise strip low-support background by hand in Excel
        /// (bracketing values, then hiding the emptied rows). Applying the same
        /// cut at export time produces the filtered pivot directly.
        struct Thresholds: Equatable {
            var minimumReads: Int = 0
            var minimumPercent: Double = 0
            /// Keep rows whose values were all suppressed. Off by default so a
            /// filtered export omits rows that would otherwise be blank.
            var keepEmptyRows: Bool = false
            /// Denominator behind `minimumPercent`.
            var percentBasis: PercentBasis = .sampleRetained

            static let none = Thresholds()

            var isActive: Bool { minimumReads > 0 || minimumPercent > 0 }

            /// Whether `count` clears both thresholds for a sample whose
            /// retained-read total is `sampleTotal`.
            ///
            /// A percent threshold needs a positive denominator; when the
            /// sample total is missing or zero the read threshold alone decides,
            /// so a sample with unknown depth is never silently blanked.
            func admits(count: Int, sampleTotal: Int?) -> Bool {
                guard count > 0 else { return false }
                if minimumReads > 0, count < minimumReads { return false }
                if minimumPercent > 0, let total = sampleTotal, total > 0 {
                    let percent = Double(count) / Double(total) * 100
                    if percent < minimumPercent { return false }
                }
                return true
            }

            var provenanceArguments: [String] {
                var arguments: [String] = []
                if minimumReads > 0 {
                    arguments += ["--min-reads", String(minimumReads)]
                }
                if minimumPercent > 0 {
                    arguments += ["--min-percent", String(minimumPercent)]
                }
                if keepEmptyRows {
                    arguments.append("--keep-empty-rows")
                }
                if percentBasis != .sampleRetained {
                    arguments += ["--percent-basis", percentBasis.rawValue]
                }
                return arguments
            }
        }

        /// Denominator for the Min Percent threshold, matching the inspector's
        /// Percent Basis control.
        enum PercentBasis: String, CaseIterable, ExpressibleByArgument, Sendable {
            /// The sample's retained reads.
            case sampleRetained = "sample-retained"
            /// The sample's reads at the allele's locus group, the inspector's
            /// default.
            case viewedLocus = "viewed-locus"
        }

        /// Canonical split-locus layout used by the lab's reference workbook.
        static let canonicalSplitLoci: [String] = [
            "MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB",
        ]

        /// Map allele prefix → display label suffix. The species code prefix
        /// (e.g. `Mafa`) is filled in at build time.
        static let prefixGroups: [(prefix: String, suffix: String)] = [
            ("01", "-F alleles"),
            ("02", "-G alleles"),
            ("04", "-AG alleles"),
            ("05", "-A major alleles"),
            ("06", "-A minor alleles"),
            ("07", "-70 alleles"),
            ("10", "-L alleles"),
            ("11", "-E alleles"),
            ("12", "-B alleles"),
            ("13", "-DRB alleles"),
            ("14", "-DQA/DQB alleles"),
            ("15", "-DPA/DPB alleles"),
        ]

        static func build(from result: ONTGenotypeResultBundleData) -> PivotWorkbook {
            build(from: result, sidecar: nil, thresholds: .none)
        }

        static func build(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar?
        ) -> PivotWorkbook {
            build(from: result, sidecar: sidecar, thresholds: .none)
        }

        static func build(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar?,
            thresholds: Thresholds
        ) -> PivotWorkbook {
            let samples = result.samples.map(\.sample)
            // Distinct reads, not alignment records: an unmerged Illumina pair
            // yields two records per fragment, which would report ~2x the value
            // the genotype inspector shows for the same sample. The allele rows
            // below already use `passedUniqueReads`, so this keeps the header
            // row consistent with them.
            let mappedReadCounts = result.samples.map { Optional($0.passedUniqueReads) }
            let totalReadCounts = result.samples.map(\.sampleTotalReads)
            let percentReadsUnmapped: [Double?] = result.samples.map { sample in
                guard let retained = sample.sampleUniqueRetainedPercent else { return nil }
                return max(0, min(100, 100 - retained))
            }

            let activeAnalysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
                for: result,
                bundleURL: result.bundleURL,
                sidecar: sidecar
            )
            let haplotypeRows = makeHaplotypeRows(
                samples: samples,
                analysis: activeAnalysis,
                sidecar: sidecar
            )
            let commentsRow = makeCommentsRow(samples: samples, analysis: activeAnalysis)

            // Build allele groups. Group key is the leading numeric prefix
            // of the genotype name (e.g. `01_M1_F_01_w_06` → "01").
            // Per (sample × genotype) count = sum of passedUniqueReads
            // across all calls with that genotype for that sample.
            var countsByGenotypeBySample: [String: [String: Int]] = [:]
            for call in result.calls {
                countsByGenotypeBySample[call.genotype, default: [:]][call.sample, default: 0] += call.passedUniqueReads
            }
            let genotypesByPrefix: [String: [String]] = Dictionary(
                grouping: Array(countsByGenotypeBySample.keys),
                by: { leadingNumericPrefix($0) ?? "??" }
            )
            let speciesPrefix = speciesPrefix(from: result.haplotypeAnalysis)

            // Percent thresholds use the denominator the inspector's Percent
            // Basis control selects: the sample's retained reads, or the
            // sample's reads at the allele's locus group.
            let sampleRetainedTotals: [String: Int] = Dictionary(
                uniqueKeysWithValues: result.samples.map { ($0.sample, $0.passedUniqueReads) }
            )
            var viewedLocusTotals: [String: [String: Int]] = [:]
            var locusGroupByGenotype: [String: String] = [:]
            for call in result.calls {
                viewedLocusTotals[call.sample, default: [:]][call.locusGroup, default: 0] += call.passedUniqueReads
                if locusGroupByGenotype[call.genotype] == nil {
                    locusGroupByGenotype[call.genotype] = call.locusGroup
                }
            }
            let denominator: (String, String) -> Int? = { genotype, sample in
                switch thresholds.percentBasis {
                case .sampleRetained:
                    return sampleRetainedTotals[sample]
                case .viewedLocus:
                    guard let locusGroup = locusGroupByGenotype[genotype] else { return nil }
                    return viewedLocusTotals[sample]?[locusGroup]
                }
            }
            var filteredValueCount = 0
            var removedRowCount = 0
            var groups: [AlleleGroup] = []
            // Emit groups in canonical prefix order, skipping any that
            // contain no observed genotypes.
            var seenPrefixes = Set<String>()
            for (prefix, suffix) in prefixGroups {
                seenPrefixes.insert(prefix)
                guard let names = genotypesByPrefix[prefix], !names.isEmpty else { continue }
                let alleles = makeAlleleRows(
                    genotypeNames: names,
                    samples: samples,
                    countsByGenotypeBySample: countsByGenotypeBySample,
                    thresholds: thresholds,
                    denominator: denominator,
                    filteredValueCount: &filteredValueCount,
                    removedRowCount: &removedRowCount
                )
                guard !alleles.isEmpty else { continue }
                groups.append(AlleleGroup(label: speciesPrefix + suffix, alleles: alleles))
            }
            // Trailing bucket for any unexpected prefix so nothing is lost.
            let leftover = genotypesByPrefix.keys.filter { !seenPrefixes.contains($0) }.sorted()
            for prefix in leftover {
                guard let names = genotypesByPrefix[prefix], !names.isEmpty else { continue }
                let alleles = makeAlleleRows(
                    genotypeNames: names,
                    samples: samples,
                    countsByGenotypeBySample: countsByGenotypeBySample,
                    thresholds: thresholds,
                    denominator: denominator,
                    filteredValueCount: &filteredValueCount,
                    removedRowCount: &removedRowCount
                )
                guard !alleles.isEmpty else { continue }
                let label = prefix == "??"
                    ? "Other alleles"
                    : "\(speciesPrefix)-\(prefix) alleles"
                groups.append(AlleleGroup(label: label, alleles: alleles))
            }

            let sheetName = sanitizedSheetName(result.manifest.analysisName)

            return PivotWorkbook(
                sheetName: sheetName,
                samples: samples,
                mappedReadCounts: mappedReadCounts,
                totalReadCounts: totalReadCounts,
                percentReadsUnmapped: percentReadsUnmapped,
                haplotypeRows: haplotypeRows,
                commentsRow: commentsRow,
                groups: groups,
                filteredValueCount: filteredValueCount,
                removedRowCount: removedRowCount
            )
        }

        private static func makeHaplotypeRows(
            samples: [String],
            analysis: GenotypeHaplotypeAnalysis?,
            sidecar: GenotypeAnnotationSidecar?
        ) -> [HaplotypeRow] {
            var rows: [HaplotypeRow] = []
            let effectiveCalls: GenotypeEffectiveCallAuthority.Resolution? = {
                guard let analysis else { return nil }
                return GenotypeEffectiveCallAuthority.resolve(
                    analysis: analysis,
                    sidecar: sidecar ?? .empty(
                        generatedAt: analysis.generatedAt
                            ?? "1970-01-01T00:00:00Z"
                    )
                )
            }()
            // Build (sample → locus → call) map from the persisted analysis.
            var callsBySampleLocus: [String: [String: GenotypeHaplotypeLocusCall]] = [:]
            var analysisLoci = Set<String>()
            if let analysis {
                for sample in analysis.samples {
                    var locusMap: [String: GenotypeHaplotypeLocusCall] = [:]
                    for call in sample.calls {
                        locusMap[call.locus] = call
                        analysisLoci.insert(call.locus)
                    }
                    callsBySampleLocus[sample.sample] = locusMap
                }
            }
            for locus in haplotypeRowLoci(analysisLoci: analysisLoci) {
                for slot in 1...2 {
                    let label = "\(locus) Haplotype \(slot)"
                    let values: [String?] = samples.map { sample in
                        guard let call = callsBySampleLocus[sample]?[locus] else { return nil }
                        let raw = effectiveCalls?.value(
                            sample: sample,
                            locus: locus,
                            slot: slot == 1 ? .h1 : .h2
                        )?.effective ?? (slot == 1 ? call.haplotype1 : call.haplotype2)
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    rows.append(HaplotypeRow(label: label, values: values))
                }
            }
            return rows
        }

        private static func haplotypeRowLoci(analysisLoci: Set<String>) -> [String] {
            guard !analysisLoci.isEmpty else { return canonicalSplitLoci }
            let usesGroupedDR = analysisLoci.contains("MHC-DR")
            let usesGroupedDQ = analysisLoci.contains("MHC-DQ")
            let usesGroupedDP = analysisLoci.contains("MHC-DP")
            return [
                ["MHC-A", "MHC-B"],
                usesGroupedDR ? ["MHC-DR"] : ["MHC-DRB"],
                usesGroupedDQ ? ["MHC-DQ"] : ["MHC-DQA", "MHC-DQB"],
                usesGroupedDP ? ["MHC-DP"] : ["MHC-DPA", "MHC-DPB"],
            ].flatMap { $0 }
        }

        private static func makeCommentsRow(
            samples: [String],
            analysis: GenotypeHaplotypeAnalysis?
        ) -> [String?] {
            guard let analysis else {
                return Array(repeating: nil, count: samples.count)
            }
            let callsBySample: [String: [GenotypeHaplotypeLocusCall]] = Dictionary(
                uniqueKeysWithValues: analysis.samples.map { ($0.sample, $0.calls) }
            )
            return samples.map { sample in
                guard let calls = callsBySample[sample] else { return nil }
                let messages = calls
                    .sorted { $0.locus.localizedStandardCompare($1.locus) == .orderedAscending }
                    .compactMap { call -> String? in
                        guard call.status != .called, call.status != .notAssayed else { return nil }
                        let left = call.haplotype1
                        let right = call.haplotype2
                        let label = (left == right || right.isEmpty) ? left : "\(left)/\(right)"
                        return "\(call.locus): \(label)"
                    }
                return messages.isEmpty ? nil : messages.joined(separator: "; ")
            }
        }

        private static func makeAlleleRows(
            genotypeNames: [String],
            samples: [String],
            countsByGenotypeBySample: [String: [String: Int]],
            thresholds: Thresholds = .none,
            denominator: (String, String) -> Int? = { _, _ in nil },
            filteredValueCount: inout Int,
            removedRowCount: inout Int
        ) -> [AlleleRow] {
            let sortedNames = genotypeNames.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            var rows: [AlleleRow] = []
            for name in sortedNames {
                let perSample = countsByGenotypeBySample[name] ?? [:]
                var suppressed = 0
                let counts: [Int?] = samples.map { sample in
                    let count = perSample[sample] ?? 0
                    guard count > 0 else { return nil }
                    guard thresholds.admits(count: count, sampleTotal: denominator(name, sample)) else {
                        suppressed += 1
                        return nil
                    }
                    return count
                }
                filteredValueCount += suppressed
                // A row with nothing left is background the analyst would have
                // hidden by hand, so drop it unless asked to keep it.
                if counts.allSatisfy({ $0 == nil }) {
                    removedRowCount += 1
                    if !thresholds.keepEmptyRows { continue }
                }
                rows.append(AlleleRow(name: name, counts: counts))
            }
            return rows
        }

        private static func leadingNumericPrefix(_ genotype: String) -> String? {
            let scanner = Scanner(string: genotype)
            scanner.charactersToBeSkipped = nil
            var digits = ""
            while let scalar = scanner.scanCharacter(), scalar.isNumber {
                digits.append(scalar)
            }
            return digits.isEmpty ? nil : digits
        }

        private static func speciesPrefix(from analysis: GenotypeHaplotypeAnalysis?) -> String {
            // Prefer the canonical Mafa/Mamu code from the analysis manifest;
            // fall back to "Mafa" which matches the existing template.
            if let analysis {
                // GenotypeHaplotypeAnalysis stores speciesName, not the
                // shorthand code. Use the assay's definition set lookup if
                // possible by parsing the species name (e.g. "Macaca
                // fascicularis" → "Mafa"). When unparseable, fall back to
                // the first four characters of the species code if it looks
                // like a Mafa-style abbreviation.
                let speciesCode = inferSpeciesCode(speciesName: analysis.speciesName)
                if !speciesCode.isEmpty {
                    return speciesCode
                }
            }
            return "Mafa"
        }

        private static func inferSpeciesCode(speciesName: String) -> String {
            let lowered = speciesName.lowercased()
            if lowered.contains("fascicularis") { return "Mafa" }
            if lowered.contains("mulatta") { return "Mamu" }
            if lowered.contains("nemestrina") { return "Mane" }
            if lowered.contains("fuscata") { return "Mafu" }
            if lowered.contains("tonkeana") { return "Mato" }
            if lowered.contains("leonina") { return "Male" }
            if lowered.contains("thibetana") { return "Math" }
            // Unknown — return empty so caller falls back to "Mafa".
            return ""
        }

        /// XLSX sheet names are limited to 31 characters and cannot include
        /// `:`, `\`, `/`, `?`, `*`, `[`, `]`. Empty names fall back to
        /// "Genotype" to match the template behavior.
        static func sanitizedSheetName(_ name: String) -> String {
            let illegal: Set<Character> = [":", "\\", "/", "?", "*", "[", "]"]
            var sanitized = String(name.filter { !illegal.contains($0) })
            sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            if sanitized.isEmpty {
                sanitized = "Genotype"
            }
            if sanitized.count > 31 {
                sanitized = String(sanitized.prefix(31))
            }
            return sanitized
        }
    }

    // MARK: - Workbook output

    private static func writeXLSX(
        to outputURL: URL,
        buildDir: URL,
        workbook: PivotWorkbook
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: buildDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        try contentTypesXML.write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try makeWorkbookXML(sheetName: workbook.sheetName).write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try workbookRelsXML.write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makePivotSheet(workbook).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = buildDir
        zip.arguments = ["-qr", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            throw GenotypeExportPivotXlsxError.zipFailed
        }
    }

    private static func makePivotSheet(_ workbook: PivotWorkbook) -> String {
        var sheet = sheetHeader()
        var rowIndex = 1

        // Row 1: "Animal ID" | (blank) | (blank) | samples...
        sheet += rowXML(
            index: rowIndex,
            cells: [.boldLabel("Animal ID"), .blank, .blank]
                + workbook.samples.map { Cell.boldLabel($0) }
        )
        rowIndex += 1

        // Row 2: "GS ID" | "Total" | "Average" | samples...
        sheet += rowXML(
            index: rowIndex,
            cells: [.boldLabel("GS ID"), .boldLabel("Total"), .boldLabel("Average")]
                + workbook.samples.map { Cell.boldLabel($0) }
        )
        rowIndex += 1

        // Row 3: Mapped Read Count
        let mappedTotal = workbook.mappedReadCounts.compactMap { $0 }.reduce(0, +)
        let mappedAverage = average(workbook.mappedReadCounts)
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("Mapped Read Count"), .number(Double(mappedTotal)), averageCell(mappedAverage)]
                + workbook.mappedReadCounts.map { count in count.map { .number(Double($0)) } ?? .blank }
        )
        rowIndex += 1

        // Row 4: total_read_count
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("total_read_count"), .blank, .blank]
                + workbook.totalReadCounts.map { count in count.map { .number(Double($0)) } ?? .blank }
        )
        rowIndex += 1

        // Row 5: percent_reads_unmapped
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("percent_reads_unmapped"), .blank, .blank]
                + workbook.percentReadsUnmapped.map { value in value.map { .percent($0) } ?? .blank }
        )
        rowIndex += 1

        // Rows 6-19: Haplotype rows.
        for haplotypeRow in workbook.haplotypeRows {
            sheet += rowXML(
                index: rowIndex,
                cells: [.label(haplotypeRow.label), .blank, .blank]
                    + haplotypeRow.values.map { value in value.map { .label($0) } ?? .blank }
            )
            rowIndex += 1
        }

        // Row 20: Comments
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("Comments"), .boldLabel("Subtotal"), .boldLabel("# Obs.")]
                + workbook.commentsRow.map { value in value.map { .label($0) } ?? .blank }
        )
        rowIndex += 1

        // Allele groups.
        for group in workbook.groups {
            // Bold header row.
            sheet += rowXML(
                index: rowIndex,
                cells: [.boldLabel(group.label), .blank, .blank]
                    + Array(repeating: Cell.blank, count: workbook.samples.count)
            )
            rowIndex += 1
            for allele in group.alleles {
                let subtotal = allele.counts.compactMap { $0 }.reduce(0, +)
                let obs = allele.counts.compactMap { $0 }.filter { $0 > 0 }.count
                sheet += rowXML(
                    index: rowIndex,
                    cells: [
                        .label(allele.name),
                        subtotal > 0 ? .number(Double(subtotal)) : .blank,
                        obs > 0 ? .number(Double(obs)) : .blank,
                    ] + allele.counts.map { count in count.map { .number(Double($0)) } ?? .blank }
                )
                rowIndex += 1
            }
        }

        sheet += sheetFooter()
        return sheet
    }

    private static func average(_ values: [Int?]) -> Double? {
        let presentValues = values.compactMap { $0 }
        guard !presentValues.isEmpty else { return nil }
        let sum = presentValues.reduce(0, +)
        return Double(sum) / Double(presentValues.count)
    }

    private static func averageCell(_ value: Double?) -> Cell {
        guard let value else { return .blank }
        return .number(value)
    }

    // MARK: - Cell helpers

    /// Cell variants used by the pivot sheet.
    private enum Cell {
        case blank
        case label(String)
        case boldLabel(String)
        case number(Double)
        case percent(Double)

        var styleID: Int {
            switch self {
            case .blank, .label: return 0
            case .boldLabel: return 1
            case .number: return 0
            case .percent: return 2
            }
        }
    }

    private static func sheetHeader() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

        """
    }

    private static func sheetFooter() -> String {
        "</sheetData></worksheet>"
    }

    private static func rowXML(index: Int, cells: [Cell]) -> String {
        let cellXML = cells.enumerated().map { (col, cell) -> String in
            let ref = "\(columnLetter(col + 1))\(index)"
            switch cell {
            case .blank:
                return ""
            case .label(let value), .boldLabel(let value):
                let escaped = xmlEscape(value)
                return #"<c r="\#(ref)" s="\#(cell.styleID)" t="inlineStr"><is><t xml:space="preserve">\#(escaped)</t></is></c>"#
            case .number(let value):
                return #"<c r="\#(ref)" s="\#(cell.styleID)"><v>\#(formatNumber(value))</v></c>"#
            case .percent(let value):
                return #"<c r="\#(ref)" s="\#(cell.styleID)"><v>\#(formatNumber(value))</v></c>"#
            }
        }.joined()
        return #"<row r="\#(index)">\#(cellXML)</row>"# + "\n"
    }

    private static func formatNumber(_ value: Double) -> String {
        // Avoid emitting scientific notation; preserve up to 6 fractional
        // digits like the openpyxl pipeline output.
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6f", value)
    }

    private static func columnLetter(_ oneBased: Int) -> String {
        var n = oneBased
        var result = ""
        while n > 0 {
            n -= 1
            let scalar = UnicodeScalar(65 + (n % 26))!
            result = String(scalar) + result
            n /= 26
        }
        return result
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Workbook scaffolding

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static func makeWorkbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
    }

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    /// Three styles:
    ///   0 = default (no fill, regular font)
    ///   1 = bold (for section headers and table headers)
    ///   2 = percent (uses numFmtId 9, "0%") — actually we use 0.0 so values
    ///       show with one decimal place to match `45.7`-style entries.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="1"><numFmt numFmtId="164" formatCode="0.0"/></numFmts>
      <fonts count="2">
        <font><sz val="11"/><name val="Aptos"/></font>
        <font><b/><sz val="11"/><name val="Aptos"/></font>
      </fonts>
      <fills count="2">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
      </fills>
      <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      </cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """
}

enum GenotypeExportPivotXlsxError: Error, LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed: return "Failed to zip the pivot XLSX archive."
        }
    }
}

// MARK: - Filtered copy of the bundle's workbook

extension GenotypeExportPivotXlsxSubcommand {
    struct FilteredCopyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The workbook the export copies: an explicit `--source-workbook`, else
    /// the bundle's `current.xlsx` when one has been published, else the
    /// primary workbook the run wrote. Returns nil when none exists on disk,
    /// in which case the pivot-only workbook is written instead.
    static func resolveSourceWorkbookURL(
        explicit: String?,
        bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest
    ) -> URL? {
        let fileManager = FileManager.default
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        var candidates: [URL] = []
        if let current = manifest.currentWorkbookPath, !current.isEmpty {
            candidates.append(bundleURL.appendingPathComponent(current))
        }
        candidates.append(bundleURL.appendingPathComponent("current.xlsx"))
        if !manifest.primaryWorkbookPath.isEmpty {
            candidates.append(bundleURL.appendingPathComponent(manifest.primaryWorkbookPath))
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// The per-allele survivors handed to the openpyxl script.
    ///
    /// Built with every row present (`keepEmptyRows` forced on) so a row whose
    /// values all fell below the thresholds still appears, with no survivors,
    /// and the script can delete it. The caller's own `keepEmptyRows` travels
    /// separately.
    struct FilterPlan: Codable, Equatable {
        struct Row: Codable, Equatable {
            let genotype: String
            /// Exact row labels accepted in report and published-current workbooks.
            let workbookLabels: [String]
            /// Samples whose value clears the thresholds, in workbook order.
            let keep: [String]
        }

        struct Comment: Codable, Equatable {
            let body: String
            let author: String
            let timestamp: String
        }

        struct HaplotypeHeaderCell: Codable, Equatable {
            let sample: String
            let value: String?
        }

        struct HaplotypeHeaderRow: Codable, Equatable {
            let workbookLabels: [String]
            let cells: [HaplotypeHeaderCell]
        }

        struct ProjectedCell: Codable, Equatable {
            let sample: String
            let value: String
            let review: String?
            let comment: Comment?
            let colorHex: String?
        }

        struct ProjectedRow: Codable, Equatable {
            let genotype: String
            let workbookLabels: [String]
            let locus: String?
            let stableClusterID: String?
            let cells: [ProjectedCell]
            let comment: Comment?
            let rowColorHex: String?
        }

        let sheet: String
        let keepEmptyRows: Bool
        let rows: [Row]
        let haplotypeHeaderRows: [HaplotypeHeaderRow]
        let visibleSamples: [String]?
        let projectedRows: [ProjectedRow]?
        let exactHaplotypeCalls: [GenotypeViewProjectionHaplotypeCall]?
        let sourceRevision: GenotypeViewProjectionSourceRevision?
        let filterContext: [String: String]?
        let allGenotypes: [String]
        let columnComments: [String: Comment]

        static func make(
            from result: ONTGenotypeResultBundleData,
            sidecar: GenotypeAnnotationSidecar?,
            thresholds: PivotWorkbookBuilder.Thresholds,
            projection: GenotypeViewProjection? = nil
        ) -> FilterPlan {
            var planThresholds = thresholds
            planThresholds.keepEmptyRows = true
            let workbook = PivotWorkbookBuilder.build(
                from: result,
                sidecar: sidecar,
                thresholds: planThresholds
            )
            let rows = workbook.groups.flatMap { group in
                group.alleles.map { allele in
                    Row(
                        genotype: allele.name,
                        workbookLabels: workbookLabels(
                            genotype: allele.name,
                            projectionLabel: nil
                        ),
                        keep: zip(workbook.samples, allele.counts).compactMap { sample, count in
                            count == nil ? nil : sample
                        }
                    )
                }
            }
            let projectedGenotypes = projection?.rows.map { $0.rawGenotype ?? $0.label } ?? []
            let allGenotypes = Array(
                Set(result.calls.map(\.genotype)).union(projectedGenotypes)
            ).sorted()
            let haplotypeHeaderRows: [HaplotypeHeaderRow] = workbook.haplotypeRows.compactMap { row in
                let cells = zip(workbook.samples, row.values).compactMap { sample, value in
                    value.map { HaplotypeHeaderCell(sample: sample, value: $0) }
                }
                guard !cells.isEmpty else { return nil }
                return HaplotypeHeaderRow(
                    workbookLabels: haplotypeWorkbookLabels(for: row.label),
                    cells: cells
                )
            }
            guard let projection else {
                return FilterPlan(
                    sheet: workbook.sheetName,
                    keepEmptyRows: thresholds.keepEmptyRows,
                    rows: rows,
                    haplotypeHeaderRows: haplotypeHeaderRows,
                    visibleSamples: nil,
                    projectedRows: nil,
                    exactHaplotypeCalls: nil,
                    sourceRevision: nil,
                    filterContext: nil,
                    allGenotypes: allGenotypes,
                    columnComments: [:]
                )
            }

            let comments = sidecar?.resolvedMatrixComments ?? [:]
            var reviews: [GenotypeAnnotationSidecar.MatrixTarget: GenotypeAnnotationSidecar.MatrixReviewAnnotation] = [:]
            for review in sidecar?.matrixReviews ?? [] {
                reviews[review.target] = review
            }
            func matches(
                _ target: GenotypeAnnotationSidecar.MatrixTarget,
                row: GenotypeViewProjectionRow,
                sample: String? = nil
            ) -> Bool {
                guard target.genotype == (row.rawGenotype ?? row.label),
                      target.locus == row.locus else { return false }
                if let targetSample = target.sample, targetSample != sample { return false }
                return target.stableClusterID == row.stableClusterID
            }
            func exportedComment(
                matching kind: (GenotypeAnnotationSidecar.MatrixTarget) -> Bool
            ) -> Comment? {
                comments.first(where: { kind($0.key) }).map {
                    Comment(body: $0.value.body, author: $0.value.author, timestamp: $0.value.timestamp)
                }
            }
            let projectedRows = projection.rows.map { row in
                let genotype = row.rawGenotype ?? row.label
                let cells = projection.sampleColumns.enumerated().map { index, sample in
                    let review = reviews.first(where: {
                        if case .cell = $0.key { return matches($0.key, row: row, sample: sample) }
                        return false
                    })?.value.disposition.rawValue
                    let comment = exportedComment {
                        if case .cell = $0 { return matches($0, row: row, sample: sample) }
                        return false
                    }
                    return ProjectedCell(
                        sample: sample,
                        value: index < row.cells.count ? row.cells[index] : "",
                        review: review,
                        comment: comment,
                        colorHex: row.cellColorsHex.flatMap {
                            index < $0.count ? $0[index] : nil
                        }
                    )
                }
                let rowComment = exportedComment {
                    if case .row = $0 { return matches($0, row: row) }
                    return false
                }
                return ProjectedRow(
                    genotype: genotype,
                    workbookLabels: workbookLabels(
                        genotype: genotype,
                        projectionLabel: row.label
                    ),
                    locus: row.locus,
                    stableClusterID: row.stableClusterID,
                    cells: cells,
                    comment: rowComment,
                    rowColorHex: row.rowColorHex
                )
            }
            var columnComments: [String: Comment] = [:]
            for sample in projection.sampleColumns {
                if let comment = comments[.column(sample: sample)] {
                    columnComments[sample] = Comment(
                        body: comment.body,
                        author: comment.author,
                        timestamp: comment.timestamp
                    )
                }
            }
            return FilterPlan(
                sheet: workbook.sheetName,
                keepEmptyRows: thresholds.keepEmptyRows,
                rows: rows,
                haplotypeHeaderRows: haplotypeHeaderRows,
                visibleSamples: projection.sampleColumns,
                projectedRows: projectedRows,
                exactHaplotypeCalls: projection.haplotypeCalls,
                sourceRevision: projection.sourceRevision,
                filterContext: projection.filterContext,
                allGenotypes: allGenotypes,
                columnComments: columnComments
            )
        }

        /// The primary report stores the raw genotype identity, while an MCM
        /// published current workbook stores the compact display label created
        /// by the report pipeline. Keep both exact identities in the plan; the
        /// transform rejects aliases that resolve to more than one source row.
        private static func workbookLabels(
            genotype: String,
            projectionLabel: String?
        ) -> [String] {
            var labels: [String] = []
            func append(_ value: String?) {
                guard let value else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !labels.contains(trimmed) else { return }
                labels.append(trimmed)
            }
            append(genotype)
            append(projectionLabel)

            let alleleNames = MHCReferenceGenotypeDisplay.alleleNames(for: genotype)
            if !alleleNames.isEmpty {
                let compact = alleleNames.map { allele -> String in
                    guard allele.hasPrefix("Mafa-"),
                          let separator = allele.firstIndex(of: "_") else {
                        return allele
                    }
                    return String(allele[..<separator]) + "*"
                        + String(allele[allele.index(after: separator)...])
                }.joined(separator: "/")
                append(compact)
            }
            return labels
        }

        /// Current MCM workbooks retain split class-II header rows even when
        /// the active analysis resolves a grouped DR/DQ/DP call. These are the
        /// only aliases the transform may update; arbitrary workbook rows are
        /// never inferred from partial text.
        private static func haplotypeWorkbookLabels(for label: String) -> [String] {
            let groupedAliases: [String: [String]] = [
                "MHC-DR": ["MHC-DRB"],
                "MHC-DQ": ["MHC-DQA", "MHC-DQB"],
                "MHC-DP": ["MHC-DPA", "MHC-DPB"],
            ]
            for (grouped, split) in groupedAliases {
                let prefix = grouped + " Haplotype "
                guard label.hasPrefix(prefix) else { continue }
                let slot = String(label.dropFirst(prefix.count))
                return [label] + split.map { "\($0) Haplotype \(slot)" }
            }
            return [label]
        }
    }

    struct FilteredCopySummary: Decodable {
        let sheet: String
        let matchedAlleleRows: Int
        let blankedValues: Int
        let removedAlleleRows: Int
        let pythonExecutable: String
        let pythonVersion: String
        let openpyxlVersion: String
    }

    /// Copies `sourceWorkbookURL` to the output with only its pivot sheet
    /// changed: values below the thresholds are blanked, each allele row's
    /// Total and observation count are recomputed from what remains, and rows
    /// left empty are removed unless `--keep-empty-rows` was given. Every
    /// other sheet is retained. Recognized haplotype headers are refreshed
    /// from current effective calls while native comments are preserved.
    /// The copy is not registered with the
    /// bundle, so edits made to it never flow back into the result.
    func exportFilteredCopy(
        of sourceWorkbookURL: URL,
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?,
        thresholds: PivotWorkbookBuilder.Thresholds,
        projection: GenotypeViewProjection? = nil,
        projectionURL: URL? = nil,
        annotationURL: URL? = nil,
        capturedInputRecords: [FileRecord] = [],
        bundleURL: URL,
        outputURL: URL,
        buildDir: URL,
        managedPythonResolver: @escaping @Sendable () async throws -> URL,
        startedAt: Date
    ) async throws {
        guard FileManager.default.fileExists(atPath: sourceWorkbookURL.path) else {
            throw FilteredCopyError(message: "Source workbook not found: \(sourceWorkbookURL.path)")
        }
        let plan = FilterPlan.make(
            from: result,
            sidecar: sidecar,
            thresholds: thresholds,
            projection: projection
        )
        let planURL = buildDir.appendingPathComponent("filter-plan.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: planURL, options: .atomic)
        let scriptURL = buildDir.appendingPathComponent("filter-pivot-sheet.py")
        try Data(Self.filterPivotSheetScript.utf8).write(to: scriptURL, options: .atomic)

        let pythonURL = try await managedPythonResolver()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transformStartedAt = Date()
        let (status, stdout, stderr) = try await Self.runProcess(
            executableURL: pythonURL,
            arguments: [scriptURL.path, sourceWorkbookURL.path, outputURL.path, planURL.path]
        )
        let transformCompletedAt = Date()
        guard status == 0 else {
            throw FilteredCopyError(
                message: "Filtering the pivot sheet failed (exit \(status)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let summary = try JSONDecoder().decode(FilteredCopySummary.self, from: Data(stdout.utf8))

        var command = [
            CLICommandIdentity.executableName, "genotype", "export-pivot-xlsx",
            "--bundle", bundle,
            "--output", output,
        ]
        if let sourceWorkbook {
            command += ["--source-workbook", sourceWorkbook]
        }
        if let viewProjection {
            command += ["--view-projection", viewProjection]
        }
        if let annotations {
            command += ["--annotations", annotations]
        }
        command += thresholds.provenanceArguments
        let transformCommand = [
            pythonURL.path, scriptURL.path, sourceWorkbookURL.path, outputURL.path, planURL.path,
        ]
        let resolvedOptions = provenanceOptions(
            thresholds: thresholds,
            sourceWorkbookURL: sourceWorkbookURL,
            projectionURL: projectionURL,
            annotationURL: annotationURL
        ).merging([
            "transformRuntime": .dictionary([
                "pythonExecutable": .file(URL(fileURLWithPath: summary.pythonExecutable)),
                "pythonVersion": .string(summary.pythonVersion),
                "openpyxlVersion": .string(summary.openpyxlVersion),
            ]),
            "transformCommand": .array(transformCommand.map(ParameterValue.string)),
            "transformExitStatus": .integer(Int(status)),
        ]) { _, new in new }
        let condaPrefix = pythonURL.deletingLastPathComponent().deletingLastPathComponent()
        let transformStep = ProvenanceStep(
            toolName: "python/openpyxl pivot transform",
            toolVersion: summary.openpyxlVersion,
            argv: transformCommand,
            durableReplayArgv: command,
            resolvedOptions: [
                "pythonVersion": .string(summary.pythonVersion),
                "openpyxlVersion": .string(summary.openpyxlVersion),
                "filterPlan": .file(planURL),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: summary.pythonVersion,
                executablePath: summary.pythonExecutable,
                condaEnvironment: "openpyxl",
                condaPrefix: condaPrefix.path,
                dependencySet: "openpyxl=\(summary.openpyxlVersion)"
            ),
            inputs: [sourceWorkbookURL, scriptURL, planURL].map {
                ProvenanceFileDescriptor(
                    fileRecord: ProvenanceRecorder.fileRecord(url: $0, role: .input)
                )
            },
            outputs: [
                ProvenanceFileDescriptor(
                    fileRecord: ProvenanceRecorder.fileRecord(url: outputURL, role: .output)
                ),
            ],
            exitStatus: Int(status),
            wallTimeSeconds: max(0, transformCompletedAt.timeIntervalSince(transformStartedAt)),
            stderr: stderr,
            startedAt: transformStartedAt,
            completedAt: transformCompletedAt
        )
        var optionPaths: [String: URL] = [
            "bundle": bundleURL,
            "output": outputURL,
        ]
        if sourceWorkbook != nil { optionPaths["source-workbook"] = sourceWorkbookURL }
        if viewProjection != nil, let projectionURL { optionPaths["view-projection"] = projectionURL }
        if annotations != nil, let annotationURL { optionPaths["annotations"] = annotationURL }
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "genotype.export.pivot-xlsx",
            toolName: "lungfish genotype export-pivot-xlsx",
            command: command,
            bundleURL: bundleURL,
            outputURLs: [outputURL],
            outputDirectory: outputURL.deletingLastPathComponent(),
            optionPaths: optionPaths,
            explicitOptions: provenanceExplicitOptions(thresholds: thresholds),
            defaults: provenanceDefaults,
            resolvedOptions: resolvedOptions,
            additionalInputURLs: [sourceWorkbookURL] + (
                GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                    for: result,
                    bundleURL: bundleURL,
                    sidecar: sidecar
                ).map { [$0] } ?? []
            ),
            additionalInputRecords: capturedInputRecords,
            excludedInputURLs: capturedInputRecords.map { URL(fileURLWithPath: $0.path) },
            extraSteps: [transformStep],
            startedAt: startedAt
        )

        let report: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "sourceWorkbook": sourceWorkbookURL.path,
            "sheet": summary.sheet,
            "sampleCount": result.samples.count,
            "matchedAlleleRows": summary.matchedAlleleRows,
            "minReads": thresholds.minimumReads,
            "minPercent": thresholds.minimumPercent,
            "percentBasis": thresholds.percentBasis.rawValue,
            "filteredAlleleValueCount": summary.blankedValues,
            "removedAlleleRowCount": summary.removedAlleleRows,
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(reportData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// Runs a child to completion, observing its exit through
    /// `terminationHandler` (see IlluminaAmpliconPairMerger for why not
    /// `waitUntilExit`).
    static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class Exit: @unchecked Sendable {
            private let lock = NSLock()
            private var status: Int32?
            private var continuation: CheckedContinuation<Int32, Never>?
            func finish(_ code: Int32) {
                lock.lock(); status = code; let pending = continuation; continuation = nil; lock.unlock()
                pending?.resume(returning: code)
            }
            func wait() async -> Int32 {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    let stored = status
                    if stored == nil { self.continuation = continuation }
                    lock.unlock()
                    if let stored { continuation.resume(returning: stored) }
                }
            }
        }
        let exit = Exit()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        try process.run()
        // Drain both pipes off the awaiting task so a chatty child cannot
        // fill a pipe and stall before it exits.
        async let stdoutData = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderrData = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
        let status = await exit.wait()
        let stdout = String(decoding: await stdoutData, as: UTF8.self)
        let stderr = String(decoding: await stderrData, as: UTF8.self)
        return (status, stdout, stderr)
    }

    /// Rewrites the pivot sheet of a copied workbook from a filter plan.
    ///
    /// Sample columns are read from the "GS ID" header row, which the
    /// pipeline's workbook and the pivot-only writer share. Allele rows are
    /// matched by their name in column A against the plan. Recognized
    /// haplotype header rows are refreshed from the active analysis; read-count
    /// and comment rows plus group labels otherwise retain the source workbook.
    /// Column B (Total) and C (# Obs.) are recomputed only where the row already
    /// carried numbers there.
    static let filterPivotSheetScript = #"""
import json
import platform
import re
import sys
from copy import copy

import openpyxl
from openpyxl import load_workbook
from openpyxl.comments import Comment
from openpyxl.styles import PatternFill, Side

source, output, plan_path = sys.argv[1:4]
with open(plan_path) as handle:
    plan = json.load(handle)

workbook = load_workbook(source)
sheet_name = plan.get("sheet")
keep_empty_rows = bool(plan.get("keepEmptyRows"))
visible_samples = plan.get("visibleSamples")
projected_rows = plan.get("projectedRows")
exact_haplotype_calls = plan.get("exactHaplotypeCalls")

if visible_samples is not None and len(visible_samples) != len(set(visible_samples)):
    sys.stderr.write("The viewport projection contains duplicate sample columns.\n")
    sys.exit(3)

def pivot_layout(candidate):
    header_rows = [
        row for row in range(1, min(candidate.max_row, 60) + 1)
        if candidate.cell(row, 1).value == "GS ID"
    ]
    if len(header_rows) != 1:
        return None
    header = header_rows[0]
    columns_by_name = {}
    for column in range(4, candidate.max_column + 1):
        name = candidate.cell(header, column).value
        if isinstance(name, str) and name.strip():
            columns_by_name.setdefault(name.strip(), []).append(column)
    if not columns_by_name or any(len(columns) != 1 for columns in columns_by_name.values()):
        return None
    if visible_samples is not None and any(
        len(columns_by_name.get(sample, [])) != 1 for sample in visible_samples
    ):
        return None
    return header, {name: columns[0] for name, columns in columns_by_name.items()}

compatible = []
for candidate in workbook.worksheets:
    layout = pivot_layout(candidate)
    if layout is not None:
        compatible.append((candidate, layout))
if not compatible:
    suffix = " containing every projected sample" if visible_samples is not None else ""
    sys.stderr.write("The workbook has no compatible pivot worksheet" + suffix + ".\n")
    sys.exit(2)
if len(compatible) != 1:
    sys.stderr.write(
        "The workbook has multiple compatible pivot worksheets: "
        + ", ".join(candidate.title for candidate, _ in compatible) + "\n"
    )
    sys.exit(2)
sheet, (header_row, sample_columns) = compatible[0]

if visible_samples is not None:
    def snapshot_cell(cell):
        return {
            "value": cell.value,
            "style": copy(cell._style),
            "comment": copy(cell.comment),
            "hyperlink": copy(cell.hyperlink),
        }

    def restore_cell(cell, state):
        cell.value = state["value"]
        cell._style = copy(state["style"])
        cell.comment = copy(state["comment"])
        cell._hyperlink = copy(state["hyperlink"])

    sample_snapshots = {}
    sample_widths = {}
    for sample in visible_samples:
        source_column = sample_columns[sample]
        sample_snapshots[sample] = [
            snapshot_cell(sheet.cell(row, source_column))
            for row in range(1, sheet.max_row + 1)
        ]
        source_letter = sheet.cell(1, source_column).column_letter
        sample_widths[sample] = copy(sheet.column_dimensions[source_letter])

    existing_sample_count = max(0, sheet.max_column - 3)
    if existing_sample_count:
        sheet.delete_cols(4, existing_sample_count)
    if visible_samples:
        sheet.insert_cols(4, len(visible_samples))
    sample_columns = {}
    for offset, sample in enumerate(visible_samples):
        target_column = 4 + offset
        sample_columns[sample] = target_column
        for row, state in enumerate(sample_snapshots[sample], start=1):
            restore_cell(sheet.cell(row, target_column), state)
        target_letter = sheet.cell(1, target_column).column_letter
        source_dimension = sample_widths[sample]
        sheet.column_dimensions[target_letter].width = source_dimension.width
        sheet.column_dimensions[target_letter].hidden = source_dimension.hidden

haplotype_colors = {
    "M1": "FF000000",
    "M2": "FFFF0000",
    "M3": "FF0432FF",
    "M4": "FF00B050",
    "M5": "FFFFC000",
    "M6": "FF595959",
    "M7": "FF7030A0",
}

def refresh_haplotype_cell(cell, value):
    cell.value = value
    cell.fill = PatternFill(fill_type=None)
    font = copy(cell.font)
    text = "" if value is None else str(value).strip()
    match = None if text in ("", "-") or text.startswith("ERR:") else re.search(r"\b(M[1-7])", text)
    if match is not None:
        font.bold = True
        font.color = haplotype_colors[match.group(1)]
    elif text.startswith("ERR:"):
        font.bold = True
        font.color = "FF9C0006"
    else:
        font.bold = False
        font.color = "FF000000"
    cell.font = font

for header in plan.get("haplotypeHeaderRows") or []:
    cells_by_sample = {cell["sample"]: cell for cell in header.get("cells", [])}
    for label in header.get("workbookLabels") or []:
        matching_rows = [
            row for row in range(header_row + 1, min(sheet.max_row, 60) + 1)
            if sheet.cell(row, 1).value == label
        ]
        if len(matching_rows) > 1:
            sys.stderr.write("The pivot sheet has duplicate haplotype header rows: " + label + "\n")
            sys.exit(4)
        if not matching_rows:
            continue
        row = matching_rows[0]
        for sample, column in sample_columns.items():
            if sample in cells_by_sample:
                refresh_haplotype_cell(
                    sheet.cell(row, column),
                    cells_by_sample[sample].get("value"),
                )

def annotation_text(entry, label):
    if not entry:
        return None
    return "\n".join([
        "[LGE Matrix Comments]",
        label,
        "Body: " + str(entry.get("body") or ""),
        "Author: " + str(entry.get("author") or "Lungfish"),
        "Timestamp: " + str(entry.get("timestamp") or ""),
    ])

def apply_comment(cell, entry, label):
    text = annotation_text(entry, label)
    if text is None:
        return
    base = ""
    author = "Lungfish"
    if cell.comment is not None:
        base = cell.comment.text.split("[LGE Matrix Comments]", 1)[0].rstrip()
        author = cell.comment.author or author
    cell.comment = Comment("\n\n".join(part for part in (base, text) if part), author if base else "Lungfish")

for sample, entry in (plan.get("columnComments") or {}).items():
    column = sample_columns.get(sample)
    if column is not None:
        apply_comment(sheet.cell(header_row, column), entry, "Sample column: " + sample)

def workbook_labels(entry):
    labels = entry.get("workbookLabels") or [entry["genotype"]]
    return set(str(label).strip() for label in labels if str(label).strip())

filter_rows_by_label = {}
for entry in plan["rows"]:
    for label in workbook_labels(entry):
        filter_rows_by_label.setdefault(label, []).append(entry)

first_allele_row = header_row + 1
for row in range(header_row, sheet.max_row + 1):
    if sheet.cell(row, 1).value == "Comments":
        first_allele_row = row + 1
        break

matched = 0
blanked = 0
rows_to_delete = []
if projected_rows is not None:
    projected_names = [row["genotype"] for row in projected_rows]
    if len(projected_names) != len(set(projected_names)):
        sys.stderr.write(
            "The viewport projection contains duplicate genotype labels; "
            "the pivot workbook cannot disambiguate their locus/stable identities.\n"
        )
        sys.exit(4)

    projected_by_label = {}
    for index, projected in enumerate(projected_rows):
        for label in workbook_labels(projected):
            projected_by_label.setdefault(label, []).append(index)

    def snapshot_row(row):
        return [snapshot_cell(sheet.cell(row, column)) for column in range(1, sheet.max_column + 1)]

    source_rows = {index: [] for index in range(len(projected_rows))}
    source_groups = {}
    current_group = None
    original_allele_rows = []
    for source_row in range(first_allele_row, sheet.max_row + 1):
        name = sheet.cell(source_row, 1).value
        filter_matches = filter_rows_by_label.get(name, []) if isinstance(name, str) else []
        if len(filter_matches) > 1:
            sys.stderr.write(
                "The pivot sheet row label matches multiple raw genotype identities: "
                + str(name) + "\n"
            )
            sys.exit(4)
        if len(filter_matches) == 1:
            original_allele_rows.append(source_row)
        if (
            isinstance(name, str)
            and not filter_matches
            and name != "Genotype"
            and name.lower().endswith("alleles")
        ):
            current_group = (name, snapshot_row(source_row))
        projected_matches = projected_by_label.get(name, []) if isinstance(name, str) else []
        if len(projected_matches) > 1:
            sys.stderr.write(
                "The pivot sheet row label matches multiple projected genotype identities: "
                + str(name) + "\n"
            )
            sys.exit(4)
        if len(projected_matches) == 1:
            index = projected_matches[0]
            source_rows[index].append(source_row)
            source_groups[index] = current_group
    ambiguous = [
        projected_names[index]
        for index in range(len(projected_rows))
        if len(source_rows[index]) != 1
    ]
    if ambiguous:
        sys.stderr.write(
            "The pivot sheet must contain exactly one row for each projected genotype: "
            + ", ".join(ambiguous) + "\n"
        )
        sys.exit(4)

    projected_sequence = []
    emitted_groups = set()
    for index, projected in enumerate(projected_rows):
        source_row = source_rows[index][0]
        group = source_groups.get(index)
        group_name = group[0] if group is not None else None
        if group is not None and group_name not in emitted_groups:
            projected_sequence.append((None, group[1]))
            emitted_groups.add(group_name)
        projected_sequence.append((projected, snapshot_row(source_row)))

    genotype_header_state = None
    if sheet.cell(first_allele_row, 1).value == "Genotype":
        genotype_header_state = snapshot_row(first_allele_row)
        rewrite_start = first_allele_row + 1
    else:
        rewrite_start = first_allele_row
    sheet.delete_rows(rewrite_start, sheet.max_row - rewrite_start + 1)
    if projected_sequence:
        sheet.insert_rows(rewrite_start, len(projected_sequence))
    for offset, (_, state) in enumerate(projected_sequence):
        target_row = rewrite_start + offset
        for column, cell_state in enumerate(state, start=1):
            restore_cell(sheet.cell(target_row, column), cell_state)

    if genotype_header_state is not None:
        for column, cell_state in enumerate(genotype_header_state, start=1):
            restore_cell(sheet.cell(first_allele_row, column), cell_state)

    for offset, (projected, _) in enumerate(projected_sequence):
        if projected is None:
            continue
        row = rewrite_start + offset
        name = projected["genotype"]
        matched += 1
        row_color = projected.get("rowColorHex")
        sheet.cell(row, 1).fill = (
            PatternFill(fill_type="solid", fgColor="FF" + row_color.lstrip("#").upper())
            if row_color else PatternFill(fill_type=None)
        )
        apply_comment(sheet.cell(row, 1), projected.get("comment"), "Allele row: " + name)
        remaining = []
        cells_by_sample = {cell["sample"]: cell for cell in projected.get("cells", [])}
        for sample, column in sample_columns.items():
            projected_cell = cells_by_sample.get(sample, {})
            raw_value = str(projected_cell.get("value") or "").strip()
            cell = sheet.cell(row, column)
            color = projected_cell.get("colorHex")
            cell.fill = (
                PatternFill(fill_type="solid", fgColor="FF" + color.lstrip("#").upper())
                if color else PatternFill(fill_type=None)
            )
            if raw_value in ("", "-"):
                cell.value = None
            else:
                try:
                    number = int(raw_value.replace(",", ""))
                    cell.value = number
                    remaining.append(number)
                except ValueError:
                    cell.value = raw_value
            review = projected_cell.get("review")
            if review == "falsePositive" and cell.value is not None:
                display = cell.value
                cell.value = "[" + str(display) + "]"
                font = copy(cell.font)
                font.italic = True
                font.color = "FF767676"
                cell.font = font
            elif review == "falseNegative":
                cell.value = "FN"
                warning_side = Side(style="mediumDashed", color="FFC65911")
                border = copy(cell.border)
                border.left = copy(warning_side)
                border.right = copy(warning_side)
                border.top = copy(warning_side)
                border.bottom = copy(warning_side)
                cell.border = border
                cell.fill = PatternFill(fill_type="solid", fgColor="FFFFF2CC")
                font = copy(cell.font)
                font.bold = True
                font.color = "FF7F6000"
                cell.font = font
            apply_comment(
                cell,
                projected_cell.get("comment"),
                "Cell: " + sample + " / " + name,
            )
        total_cell = sheet.cell(row, 2)
        observed_cell = sheet.cell(row, 3)
        if isinstance(total_cell.value, (int, float)):
            total_cell.value = sum(remaining) if remaining else None
        if isinstance(observed_cell.value, (int, float)):
            observed_cell.value = len(remaining) if remaining else None
    removed_projected_rows = max(0, len(original_allele_rows) - len(projected_rows))

for row in range(first_allele_row, sheet.max_row + 1):
    if projected_rows is not None:
        break
    name = sheet.cell(row, 1).value
    matches = filter_rows_by_label.get(name, []) if isinstance(name, str) else []
    if len(matches) > 1:
        sys.stderr.write(
            "The pivot sheet row label matches multiple raw genotype identities: "
            + str(name) + "\n"
        )
        sys.exit(4)
    if len(matches) != 1:
        continue
    matched += 1
    keep = set(matches[0]["keep"])
    remaining = []
    for sample, column in sample_columns.items():
        cell = sheet.cell(row, column)
        if cell.value is None:
            continue
        if sample in keep:
            if isinstance(cell.value, (int, float)):
                remaining.append(cell.value)
        else:
            cell.value = None
            blanked += 1
    total_cell = sheet.cell(row, 2)
    observed_cell = sheet.cell(row, 3)
    if isinstance(total_cell.value, (int, float)):
        total_cell.value = sum(remaining) if remaining else None
    if isinstance(observed_cell.value, (int, float)):
        observed_cell.value = len(remaining) if remaining else None
    if not remaining and not keep_empty_rows:
        rows_to_delete.append(row)

for row in reversed(rows_to_delete):
    sheet.delete_rows(row)

# A projection carrying exact calls is the new filtered-view contract. It is
# intentionally scoped and must not retain unfiltered companion worksheets.
if projected_rows is not None and exact_haplotype_calls is not None:
    source_matrix = sheet
    clean_matrix = workbook.create_sheet("Genotype Matrix", 0)
    clean_matrix.append(["Genotype", "Locus", "Stable Cluster ID"] + visible_samples)
    for cell in clean_matrix[1]:
        cell.font = copy(cell.font)
        cell.font = cell.font.copy(bold=True)
    for offset, sample in enumerate(visible_samples, start=4):
        clean_matrix.cell(1, offset).comment = copy(
            source_matrix.cell(header_row, sample_columns[sample]).comment
        )
    for projected in projected_rows:
        matching_rows = [
            row for row in range(1, source_matrix.max_row + 1)
            if source_matrix.cell(row, 1).value in workbook_labels(projected)
        ]
        if len(matching_rows) != 1:
            sys.stderr.write(
                "The rewritten matrix lost a projected genotype row: "
                + str(projected.get("genotype")) + "\n"
            )
            sys.exit(4)
        source_row = matching_rows[0]
        clean_matrix.append([
            projected.get("genotype"),
            projected.get("locus") or "",
            projected.get("stableClusterID") or "",
        ] + [source_matrix.cell(source_row, sample_columns[sample]).value for sample in visible_samples])
        target_row = clean_matrix.max_row
        clean_matrix.cell(target_row, 1)._style = copy(source_matrix.cell(source_row, 1)._style)
        clean_matrix.cell(target_row, 1).comment = copy(source_matrix.cell(source_row, 1).comment)
        for offset, sample in enumerate(visible_samples, start=4):
            source_cell = source_matrix.cell(source_row, sample_columns[sample])
            target_cell = clean_matrix.cell(target_row, offset)
            target_cell._style = copy(source_cell._style)
            target_cell.comment = copy(source_cell.comment)
            target_cell._hyperlink = copy(source_cell.hyperlink)
    clean_matrix.freeze_panes = "D2"
    clean_matrix.auto_filter.ref = clean_matrix.dimensions
    clean_matrix.column_dimensions["A"].width = 36
    clean_matrix.column_dimensions["B"].width = 18
    clean_matrix.column_dimensions["C"].width = 24
    for candidate in list(workbook.worksheets):
        if candidate is not clean_matrix:
            workbook.remove(candidate)
    sheet = clean_matrix

    calls_sheet = workbook.create_sheet("Haplotype Calls")
    call_headers = [
        "Sample", "Locus", "Haplotype 1", "Haplotype 2",
        "H1 Status", "H2 Status", "H1 Source", "H2 Source",
        "Pipeline H1", "Pipeline H2", "Comment",
    ]
    calls_sheet.append(call_headers)
    for cell in calls_sheet[1]:
        cell.font = copy(cell.font)
        cell.font = cell.font.copy(bold=True)
    def literal_text(value):
        return "" if value is None else str(value)
    for call in exact_haplotype_calls:
        calls_sheet.append([
            literal_text(call.get("sample")),
            literal_text(call.get("locus")),
            literal_text(call.get("haplotype1")),
            literal_text(call.get("haplotype2")),
            literal_text(call.get("haplotype1Status")),
            literal_text(call.get("haplotype2Status")),
            literal_text(call.get("haplotype1Source")),
            literal_text(call.get("haplotype2Source")),
            literal_text(call.get("baselineHaplotype1")),
            literal_text(call.get("baselineHaplotype2")),
            literal_text(call.get("comment")),
        ])
        for cell in calls_sheet[calls_sheet.max_row]:
            cell.data_type = "s"
    calls_sheet.freeze_panes = "A2"
    calls_sheet.auto_filter.ref = calls_sheet.dimensions
    for column, width in enumerate([20, 18, 22, 22, 14, 14, 16, 16, 22, 22, 42], start=1):
        calls_sheet.column_dimensions[calls_sheet.cell(1, column).column_letter].width = width

    metadata_sheet = workbook.create_sheet("Export Metadata")
    metadata_sheet.append(["Field", "Value"])
    metadata_sheet["A1"].font = metadata_sheet["A1"].font.copy(bold=True)
    metadata_sheet["B1"].font = metadata_sheet["B1"].font.copy(bold=True)
    metadata_sheet.append(["Workbook Role", "Filtered view (read-only snapshot)"])
    for key, value in sorted((plan.get("filterContext") or {}).items()):
        metadata_sheet.append([literal_text(key), literal_text(value)])
        for cell in metadata_sheet[metadata_sheet.max_row]:
            cell.data_type = "s"
    revision = plan.get("sourceRevision") or {}
    for key in ("assayID", "analysisRevisionID", "definitionSetID"):
        metadata_sheet.append(["Source " + key, literal_text(revision.get(key))])
        for cell in metadata_sheet[metadata_sheet.max_row]:
            cell.data_type = "s"
    metadata_sheet.column_dimensions["A"].width = 30
    metadata_sheet.column_dimensions["B"].width = 80

workbook.save(output)
print(json.dumps({
    "sheet": sheet.title,
    "matchedAlleleRows": matched,
    "blankedValues": blanked,
    "removedAlleleRows": removed_projected_rows if projected_rows is not None else len(rows_to_delete),
    "pythonExecutable": sys.executable,
    "pythonVersion": platform.python_version(),
    "openpyxlVersion": openpyxl.__version__,
}))
"""#
}
