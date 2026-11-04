// MetagenomicsImportService+TaxTriage.swift - What a TaxTriage import keeps and counts of the run it imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The parts of a TaxTriage import that read the source run's own record (Phase 3.2 lane TTIMPORT, row
/// IMPORT-TAXTRIAGE-BATCH-HIDDEN, UX-IMPORT-BATCH and BIO-IMPORT-BATCH). They live apart from `importTaxTriage` so that
/// the importer file does not grow.
extension MetagenomicsImportService {
    /// The files an import records as its reports. Per-sample organism reports win. Without one the combined
    /// `all.odr.txt` is the report, and without that the older rule applies (any table whose name holds `report`).
    static func taxTriageReportFiles(perSample: [URL], among files: [URL]) -> [URL] {
        if !perSample.isEmpty { return perSample }
        let combined = files.filter(TaxTriageOrganismReport.isCombinedReportFile).sorted { $0.path < $1.path }
        if !combined.isEmpty { return combined }
        return files.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            return name.contains("report") && (ext == "txt" || ext == "tsv")
        }
    }

    /// The organism rows of an import: one report per sample, `.odr.txt` over `.organisms.report.txt` as
    /// ``TaxTriageOrganismReport/reportFiles(inResultDirectory:)`` chooses. With no per-sample report it is the combined
    /// report alone, and with neither it is the older tables, MultiQC's left out.
    static func taxTriageReportEntryCount(of reportFiles: [URL]) -> Int {
        var bySample: [String: URL] = [:]
        for url in reportFiles.sorted(by: { $0.path < $1.path }) {
            guard let sample = TaxTriageOrganismReport.sampleID(fromReportFile: url) else { continue }
            if let existing = bySample[sample],
               existing.lastPathComponent.lowercased().hasSuffix(TaxTriageOrganismReport.perSampleODRSuffix) {
                continue
            }
            bySample[sample] = url
        }
        let counted = bySample.isEmpty
            ? reportFiles.filter { !$0.lastPathComponent.lowercased().hasPrefix("multiqc") }
            : Array(bySample.values)
        return counted.reduce(0) { $0 + countDataRows(in: $1) }
    }

    /// The record an import saves. The source run's own facts stay when the source holds a record (its config with the
    /// samples and their negative controls, runtime, exit code, read counts, bundles and failed samples, and its ignored
    /// failures when the log shows none). The two folders the record names become the imported one, and the file lists
    /// are the importer's own.
    static func taxTriageImportedResult(
        carrying source: TaxTriageResult?,
        in resultDirectory: URL,
        reportFiles: [URL],
        metricsFiles: [URL],
        kronaFiles: [URL],
        logFile: URL?,
        traceFile: URL?,
        allOutputFiles: [URL],
        ignoredFailures: [TaxTriageIgnoredFailure]
    ) -> TaxTriageResult {
        var config = source?.config ?? TaxTriageConfig(samples: [], outputDirectory: resultDirectory)
        config.outputDirectory = resultDirectory
        return TaxTriageResult(
            config: config,
            runtime: source?.runtime ?? 0,
            exitCode: source?.exitCode ?? 0,
            outputDirectory: resultDirectory,
            reportFiles: reportFiles,
            metricsFiles: metricsFiles,
            kronaFiles: kronaFiles,
            logFile: logFile,
            traceFile: traceFile,
            allOutputFiles: allOutputFiles,
            deduplicatedReadCounts: source?.deduplicatedReadCounts,
            perSampleDeduplicatedReadCounts: source?.perSampleDeduplicatedReadCounts,
            sourceBundleURLs: source?.sourceBundleURLs,
            ignoredFailures: ignoredFailures.isEmpty ? (source?.ignoredFailures ?? []) : ignoredFailures,
            sampleFailures: source?.sampleFailures ?? []
        )
    }

    /// `resolved` with what the source run's record says of its database. A record that names the Kraken 2 database
    /// folder gives its name, one that names none keeps the note of a result that names no database, and a source with
    /// no record says that no run record was found.
    static func taxTriageDatabaseIdentity(
        source: TaxTriageResult?,
        adding resolved: [String: ParameterValue]
    ) -> [String: ParameterValue] {
        guard let source else { return MetagenomicsImportDatabaseIdentity.noRunRecord(adding: resolved) }
        guard let path = source.config.kraken2DatabasePath else {
            return MetagenomicsImportDatabaseIdentity.notNamedBySource(tool: "TaxTriage", adding: resolved)
        }
        return MetagenomicsImportDatabaseIdentity.taxTriage(databasePath: path, adding: resolved)
    }
}
