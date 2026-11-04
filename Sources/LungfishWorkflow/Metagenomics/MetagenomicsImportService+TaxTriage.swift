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

    /// What the import keeps of the provenance record of the run that made `inputURL` (UX-IMPORT-REHYDRATE items 1 to 11).
    /// A single-sample run holds its record in the folder, and a batch of two or more samples keeps its tool steps in each
    /// sample folder, so those folders are read as well, in name order. The importer copies no hidden file, so the records
    /// would be lost with the source. Call it after the copy and before the importer writes `taxtriage-result.json`.
    static func taxTriageSourceRun(from inputURL: URL, in resultDirectory: URL) -> TaxTriageSourceRun {
        let place = StagedBundlePlace(staged: inputURL, final: resultDirectory)
        var run = TaxTriageSourceRun()
        var unreadable: String?
        var sawRecord = false
        var rootFacts: [String: ParameterValue] = [:]
        var sampleFacts: [String: ParameterValue] = [:]
        var changed: [String] = []
        var partial: String?
        for (name, folder) in taxTriageRecordFolders(of: inputURL) {
            let sidecar = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            do {
                guard let record = try ProvenanceEnvelopeReader.load(fromSidecar: sidecar) else { continue }
                sawRecord = true
                let kept = try taxTriageKeptSteps(of: record, sidecar: sidecar, place: place, in: resultDirectory)
                if let name { sampleFacts[name] = .dictionary(kept.facts) } else { rootFacts = kept.facts }
                guard let last = kept.steps.last else { continue }
                run.steps += kept.steps
                run.lastStepIDs.append(last.id)
                changed += kept.changed
                if partial == nil, record.status != .completed { partial = record.status.rawValue }
            } catch {
                unreadable = unreadable ?? error.localizedDescription
            }
        }
        guard !run.steps.isEmpty else {
            let reason = unreadable.map { "its record could not be read (\($0))" }
                ?? (sawRecord ? "its record names no steps" : "no record found")
            let note = "Source run: \(reason), so this result records only the import"
            run.note = note
            run.recordFacts = ["sourceRunNote": .string(note)]
            return run
        }
        var facts = rootFacts
        if !sampleFacts.isEmpty { facts["samples"] = .dictionary(sampleFacts) }
        run.recordFacts = ["sourceRun": .dictionary(facts)]
        var words: [String] = []
        if !changed.isEmpty {
            let listed = changed.prefix(3).joined(separator: ", ")
            words.append("Source run: \(changed.count) file(s) differ from what the run recorded: \(listed).")
        }
        if let partial { words.append("Source run: its record says \(partial), so this result may be partial.") }
        run.note = words.isEmpty ? nil : words.joined(separator: " ")
        return run
    }

    /// The folder itself, then each direct child folder by name, which are the places a run leaves a record.
    private static func taxTriageRecordFolders(of inputURL: URL) -> [(name: String?, url: URL)] {
        var folders: [(name: String?, url: URL)] = [(nil, inputURL)]
        guard taxTriageIsDirectory(inputURL) else { return folders }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: inputURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        folders += children.filter(taxTriageIsDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, $0) }
        return folders
    }

    private static func taxTriageIsDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The steps of `record` with each output naming its file in `resultDirectory`. An output the importer owns, one that
    /// the copy lacks and one whose digest the copy no longer matches leaves the step (items 4 to 6). The run-level facts
    /// of the record come back for `sourceRun` (item 9).
    private static func taxTriageKeptSteps(
        of record: ProvenanceEnvelope,
        sidecar: URL,
        place: StagedBundlePlace,
        in resultDirectory: URL
    ) throws -> (steps: [ProvenanceStep], changed: [String], facts: [String: ParameterValue]) {
        func relativeToSource(_ path: String) -> String? {
            guard let spelling = place.spellings.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
            return path == spelling ? "" : String(path.dropFirst(spelling.count + 1))
        }
        let owned: Set<String> = ["analysis-metadata.json", "taxtriage-result.json"]
        var notImported = 0
        let filtered = record.steps.map { step in
            step.with { copy in
                copy.outputs = step.outputs.filter { output in
                    guard let relative = relativeToSource(output.path) else { return true }
                    guard !relative.isEmpty else { return false }
                    let file = resultDirectory.appendingPathComponent(relative)
                    if owned.contains(relative) || isGeneratedProvenanceArtifact(file, root: resultDirectory) { return false }
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                        notImported += 1
                        return false
                    }
                    return true
                }
            }
        }
        var pathMap = Dictionary(uniqueKeysWithValues: place.spellings.map { ($0, resultDirectory.path) })
        for output in filtered.flatMap(\.outputs) {
            if let relative = relativeToSource(output.path) {
                pathMap[output.path] = resultDirectory.appendingPathComponent(relative).path
            }
        }
        let rewritten = try GUIImportedProvenanceRehydrator.rewriteOutputDescriptors(
            in: record.with { copy in
                copy.files = []
                copy.output = nil
                copy.outputs = []
                copy.steps = filtered
            },
            pathMap: pathMap,
            sourceProvenancePath: sidecar.path
        )
        var changed: [String] = []
        var steps: [ProvenanceStep] = []
        for (recorded, carried) in zip(filtered, rewritten.steps) {
            var outputs: [ProvenanceFileDescriptor] = []
            for (before, after) in zip(recorded.outputs, carried.outputs) {
                if let was = before.checksumSHA256, let now = after.checksumSHA256, was != now {
                    changed.append(relativeToSource(before.path) ?? before.path)
                } else {
                    outputs.append(after)
                }
            }
            steps.append(carried.with { $0.outputs = outputs })
        }
        let facts: [String: ParameterValue] = [
            "workflowName": .string(record.workflowName),
            "workflowVersion": record.workflowVersion.map(ParameterValue.string) ?? .null,
            "status": .string(record.status.rawValue),
            "exitStatus": record.exitStatus.map(ParameterValue.integer) ?? .null,
            "createdAt": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "argv": .array(record.argv.map(ParameterValue.string)),
            "reproducibleCommand": .string(record.reproducibleCommand),
            "explicit": .dictionary(rewritten.options.explicit),
            "resolvedDefaults": .dictionary(rewritten.options.resolvedDefaults),
            "outputsNotImported": .integer(notImported),
            "outputsChanged": .array(changed.map(ParameterValue.string)),
        ]
        return (steps, changed, facts)
    }
}

/// What an import keeps of the run that made the folder it imports (UX-IMPORT-REHYDRATE).
struct TaxTriageSourceRun {
    /// The run's steps, the folder's own first and then each sample folder by name.
    var steps: [ProvenanceStep] = []
    /// The id of the last step of each record that gave steps, which the import step depends on.
    var lastStepIDs: [UUID] = []
    /// `sourceRun` when steps were carried and `sourceRunNote` when none were, for the import's resolved defaults.
    var recordFacts: [String: ParameterValue] = [:]
    /// The words for the person, nil when the record was carried and matches what the run left.
    var note: String?
}
