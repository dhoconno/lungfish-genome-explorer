import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Export a `.lungfishgenotype` bundle's finalized analyst results as a set
/// of LabKey-ready CSV files.
///
/// The WNPRC team imports analyst-reviewed genotype results into a LabKey
/// server through CSV ingestion (preferred over API authentication because
/// CSVs are easier to debug when an upload fails). Each file is "long-format"
/// (one row per fact, not per sample) with a stable header row, UTF-8 +
/// Unix line endings, and RFC 4180 escaping.
///
/// The five files produced under `--output-dir`:
///
///   * `haplotype_calls.csv`     — final, post-override H1/H2 haplotype calls
///   * `allele_read_counts.csv`  — per-sample per-allele unique read counts
///   * `overrides.csv`           — analyst overrides (audit-friendly subset)
///   * `audit_log.csv`           — full audit trail
///   * `smart_cohorts.csv`       — saved smart cohorts in the bundle
///
/// The haplotype calls reflect analyst-applied overrides merged over the
/// pipeline's `haplotypeAnalysis` so LabKey receives the *active* (final)
/// call, not the raw pipeline output. Bundle files themselves are never
/// modified — this is a provenance-`inspectOnly` (`cli.genotype` policy)
/// command, peer to the existing `export-xlsx` subcommand.
struct GenotypeExportLabKeySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-labkey",
        abstract: "Export the genotype bundle's analyst-reviewed results as LabKey-ready CSV files."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the `.lungfishgenotype` bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Directory to write the LabKey CSV files into. Created if missing.")
    var outputDir: String

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if outputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output-dir must not be empty.")
        }
    }

    func run() async throws {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let outputDirURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)

        let sidecar = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)

        // Loading the result is best-effort: when only the annotation
        // sidecar is present (no pipeline artifacts), still emit the
        // override / audit / cohort CSVs so the analyst can ship the
        // sidecar fragments. The haplotype and allele tables degrade to
        // header-only files in that case.
        let result = try? ONTGenotypeResultBundle.loadResult(from: bundleURL)

        let exporter = LabKeyExporter(
            outputDir: outputDirURL,
            bundleURL: bundleURL,
            result: result,
            sidecar: sidecar
        )
        let written = try exporter.writeAll()
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "genotype.export.labkey",
            toolName: "lungfish genotype export-labkey",
            command: [
                CLICommandIdentity.executableName, "genotype", "export-labkey",
                "--bundle", bundleURL.path,
                "--output-dir", outputDirURL.path,
            ],
            bundleURL: bundleURL,
            outputURLs: written.map(\.url),
            outputDirectory: outputDirURL,
            optionPaths: [
                "bundle": bundleURL,
                "outputDir": outputDirURL,
            ],
            additionalInputURLs: result.flatMap {
                GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                    for: $0,
                    bundleURL: bundleURL,
                    sidecar: sidecar
                )
            }.map { [$0] } ?? [],
            startedAt: startedAt
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "outputDir": outputDirURL.path,
            "files": written.map { $0.url.path },
            "rowCounts": Dictionary(uniqueKeysWithValues: written.map { ($0.label, $0.rowCount) })
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(summaryData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - Exporter

/// Plain-data record describing one of the five LabKey CSV files this
/// subcommand writes. Exposed at file scope so unit tests can introspect
/// the exporter without booting the CLI runner.
struct GenotypeLabKeyExportFile: Equatable {
    let label: String
    let filename: String
    let url: URL
    let rowCount: Int
}

/// Pure-Swift CSV writer for the five LabKey files. No third-party CSV
/// library: every field flows through `csvField(_:)` for RFC 4180 escaping
/// and rows are joined with the Unix line ending the LabKey importer
/// expects.
struct LabKeyExporter {
    let outputDir: URL
    let bundleURL: URL
    let result: ONTGenotypeResultBundleData?
    let sidecar: GenotypeAnnotationSidecar

    static let filenames: [String: String] = [
        "haplotype_calls": "haplotype_calls.csv",
        "allele_read_counts": "allele_read_counts.csv",
        "overrides": "overrides.csv",
        "audit_log": "audit_log.csv",
        "smart_cohorts": "smart_cohorts.csv"
    ]

    func writeAll() throws -> [GenotypeLabKeyExportFile] {
        let haplotypeRows = buildHaplotypeRows()
        let alleleRows = buildAlleleRows()
        let overrideRows = buildOverrideRows()
        let auditRows = buildAuditRows()
        let cohortRows = buildCohortRows()

        return [
            try writeCSV(
                label: "haplotype_calls",
                header: [
                    "animal_id", "gs_id", "locus", "slot", "called_haplotype",
                    "status", "reads_supporting", "is_override", "notes"
                ],
                rows: haplotypeRows
            ),
            try writeCSV(
                label: "allele_read_counts",
                header: [
                    "animal_id", "gs_id", "allele", "locus_group",
                    "unique_reads", "passed_unique_reads", "passed_alignments"
                ],
                rows: alleleRows
            ),
            try writeCSV(
                label: "overrides",
                header: [
                    "animal_id", "locus", "slot", "original_call", "override_call",
                    "reason_tag", "rationale", "author", "timestamp"
                ],
                rows: overrideRows
            ),
            try writeCSV(
                label: "audit_log",
                header: [
                    "action", "animal_id", "locus", "slot", "before", "after",
                    "color", "reason", "rationale", "author", "timestamp"
                ],
                rows: auditRows
            ),
            try writeCSV(
                label: "smart_cohorts",
                header: [
                    "cohort_id", "cohort_name", "predicate_json",
                    "created_at", "sample_count"
                ],
                rows: cohortRows
            )
        ]
    }

    // MARK: Haplotype calls

    /// Build the final, post-override haplotype call rows.
    ///
    /// `sidecar.callOverrides` are merged over `result.haplotypeAnalysis` so
    /// each `(sample, locus, slot)` triple resolves to the analyst-chosen
    /// haplotype when one exists. The status column reports the pipeline's
    /// status string for transparency (analysts can still see when the raw
    /// call was `no_haplotype` even after an override sets a final call).
    func buildHaplotypeRows() -> [[String]] {
        guard let result else { return [] }
        let analysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
            for: result,
            bundleURL: bundleURL,
            sidecar: sidecar
        ) ?? GenotypeHaplotypeAnalysis(
                assayID: "", definitionSetID: "", definitionSetName: "",
                speciesName: "", samples: []
            )
        let overrideIndex = indexOverrides(sidecar.callOverrides)
        let callsBySample = Dictionary(uniqueKeysWithValues: result.samples.map { ($0.sample, $0) })

        var rows: [[String]] = []
        for sampleAnalysis in analysis.samples {
            let sampleCalls = callsBySample[sampleAnalysis.sample]?.calls ?? []
            for call in sampleAnalysis.calls {
                rows.append(haplotypeRow(
                    sample: sampleAnalysis.sample,
                    locus: call.locus,
                    slot: .h1,
                    rawHaplotype: call.haplotype1,
                    status: call.status,
                    notes: call.notes,
                    sampleCalls: sampleCalls,
                    overrideIndex: overrideIndex
                ))
                rows.append(haplotypeRow(
                    sample: sampleAnalysis.sample,
                    locus: call.locus,
                    slot: .h2,
                    rawHaplotype: call.haplotype2,
                    status: call.status,
                    notes: call.notes,
                    sampleCalls: sampleCalls,
                    overrideIndex: overrideIndex
                ))
            }
        }
        return rows
    }

    private func haplotypeRow(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        rawHaplotype: String,
        status: GenotypeHaplotypeCallStatus,
        notes: String,
        sampleCalls: [ONTGenotypeCall],
        overrideIndex: [OverrideKey: GenotypeAnnotationSidecar.CallOverride]
    ) -> [String] {
        let key = OverrideKey(sample: sample, locus: locus, slot: slot)
        let override = overrideIndex[key]
        let finalCall = override?.overrideCall ?? rawHaplotype
        let reads = readsSupporting(haplotype: finalCall, sampleCalls: sampleCalls)
        return [
            sample,
            sample,
            locus,
            slot.rawValue,
            finalCall,
            statusString(status),
            String(reads),
            override != nil ? "true" : "false",
            notes
        ]
    }

    /// "Reads supporting" the called haplotype is the sum of unique reads
    /// over every observed allele call whose genotype string mentions the
    /// haplotype token. The token may already be in canonical (`M1A`) or
    /// raw (`Mafa-A1*063:02_M1A`) form — substring matching handles both.
    /// Returns 0 for placeholder calls (`-`, `ERR: ...`) and for samples
    /// missing from the call CSV.
    private func readsSupporting(haplotype: String, sampleCalls: [ONTGenotypeCall]) -> Int {
        let trimmed = haplotype.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", !trimmed.hasPrefix("ERR") else { return 0 }
        return sampleCalls
            .filter { $0.genotype.contains(trimmed) }
            .map { max(0, $0.passedUniqueReads) }
            .reduce(0, +)
    }

    private func statusString(_ status: GenotypeHaplotypeCallStatus) -> String {
        switch status {
        case .called: return "called"
        case .notAssayed: return "not_assayed"
        case .noHaplotype: return "no_haplotype"
        case .tooManyHaplotypes: return "too_many_haplotypes"
        case .tooManyGenotypes: return "too_many_genotypes"
        case .specialCase: return "special_case"
        }
    }

    // MARK: Allele read counts

    func buildAlleleRows() -> [[String]] {
        guard let result else { return [] }
        var rows: [[String]] = []
        for sample in result.samples {
            for call in sample.calls {
                rows.append([
                    sample.sample,
                    sample.sample,
                    call.genotype,
                    call.locusGroup,
                    String(call.sampleUniqueRetainedReads ?? call.passedUniqueReads),
                    String(call.passedUniqueReads),
                    String(call.passedAlignments)
                ])
            }
        }
        return rows
    }

    // MARK: Overrides

    func buildOverrideRows() -> [[String]] {
        sidecar.callOverrides.map { override in
            [
                override.sample,
                override.locus,
                override.slot.rawValue,
                override.originalCall,
                override.overrideCall,
                override.reasonTag.rawValue,
                override.rationale,
                override.author,
                override.timestamp
            ]
        }
    }

    // MARK: Audit log

    func buildAuditRows() -> [[String]] {
        sidecar.auditLog.map { entry in
            [
                entry.action,
                entry.sample,
                entry.locus ?? "",
                entry.slot?.rawValue ?? "",
                entry.before ?? "",
                entry.after ?? "",
                entry.color ?? "",
                entry.reason ?? "",
                entry.rationale ?? "",
                entry.author,
                entry.timestamp
            ]
        }
    }

    // MARK: Smart cohorts

    /// Smart cohorts get a deterministic `cohort_id` derived from
    /// `name + scope` so LabKey rows survive re-exports without colliding on
    /// `cohort_name` collisions across scopes. The predicate is serialized
    /// as JSON exactly as it lives in the sidecar so analysts can round-trip
    /// it into Lungfish. `sample_count` is the number of bundle samples the
    /// predicate currently matches — useful for sanity-checking the cohort
    /// before LabKey ingestion.
    func buildCohortRows() -> [[String]] {
        let subjects: [GenotypeCohortSubject]
        if let result {
            let sampleIds = Set(result.sampleNames + result.samples.map(\.sample) + result.calls.map(\.sample))
            let metadata = SampleMetadataStore.load(from: result.bundleURL, knownSampleIds: sampleIds)
            subjects = GenotypeCohortSubjectBuilder.buildSubjects(
                result: result,
                sidecar: sidecar,
                metadataBySample: metadata?.records ?? [:]
            )
        } else {
            subjects = []
        }
        let createdAt = sidecar.generatedAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        return sidecar.smartCohorts.enumerated().map { (offset, cohort) -> [String] in
            let predicateJSON: String
            if let data = try? encoder.encode(cohort.predicate),
               let json = String(data: data, encoding: .utf8) {
                predicateJSON = json
            } else {
                predicateJSON = ""
            }
            let count = subjects.filter { cohort.predicate.evaluate($0) }.count
            return [
                String(offset + 1),
                cohort.name,
                predicateJSON,
                createdAt,
                String(count)
            ]
        }
    }

    // MARK: CSV writing

    private func writeCSV(
        label: String,
        header: [String],
        rows: [[String]]
    ) throws -> GenotypeLabKeyExportFile {
        let filename = Self.filenames[label]!
        let url = outputDir.appendingPathComponent(filename)
        var output = header.map(Self.csvField).joined(separator: ",") + "\n"
        for row in rows {
            output += row.map(Self.csvField).joined(separator: ",") + "\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
        return GenotypeLabKeyExportFile(
            label: label,
            filename: filename,
            url: url,
            rowCount: rows.count
        )
    }

    /// RFC 4180 escaping: wrap in double quotes when the field contains
    /// a comma, double quote, CR, or LF; double up any embedded quotes.
    /// Empty strings stay empty (LabKey treats unquoted empty fields as
    /// NULL — what we want for missing optional values).
    static func csvField(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: Override indexing

    struct OverrideKey: Hashable {
        let sample: String
        let locus: String
        let slot: HaplotypeSlot
    }

    /// Build a last-write-wins lookup keyed on `(sample, locus, slot)`. The
    /// sidecar's append-only history may contain superseded overrides for
    /// the same slot; LabKey only wants the most recent decision, which
    /// matches what the inspector renders.
    private func indexOverrides(
        _ overrides: [GenotypeAnnotationSidecar.CallOverride]
    ) -> [OverrideKey: GenotypeAnnotationSidecar.CallOverride] {
        var index: [OverrideKey: GenotypeAnnotationSidecar.CallOverride] = [:]
        for override in overrides {
            let key = OverrideKey(sample: override.sample, locus: override.locus, slot: override.slot)
            if let existing = index[key], existing.timestamp >= override.timestamp {
                continue
            }
            index[key] = override
        }
        return index
    }
}
