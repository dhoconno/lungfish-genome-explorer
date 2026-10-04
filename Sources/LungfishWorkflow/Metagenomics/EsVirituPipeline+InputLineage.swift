// EsVirituPipeline+InputLineage.swift - The bundle behind each EsViritu input in provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension EsVirituConfig {
    /// Records where the execution files of `resolved` came from, when any
    /// came from a `.lungfishfastq` bundle. Call it on a configuration whose
    /// ``inputFiles`` are `resolved.executionInputURLs`.
    public mutating func recordInputLineage(_ resolved: ResolvedSequenceInputs) {
        let originals = resolved.originalInputURLs.map(\.standardizedFileURL)
        let executions = resolved.executionInputURLs.map(\.standardizedFileURL)
        originalInputFiles = originals == executions ? nil : originals
    }
}

extension EsVirituPipeline {
    /// Run parameters that name the bundles behind the execution files. They
    /// are the inputs as given (`originalInputs`) and the `lungfish-cli fastq
    /// materialize` command that rebuilds each materialized file
    /// (`inputMaterializationCommands`), or the `cat` command that joined
    /// several files. A run on files as given gets none, so it records exactly
    /// what it recorded before (R3). A planned run adds its read-set plan.
    static func inputLineageParameters(for config: EsVirituConfig) -> [String: ParameterValue] {
        let planParameters = config.readSetPlan?.provenanceParameters ?? [:]
        guard let originals = config.originalInputFiles else { return planParameters }
        var uniqueOriginals: [URL] = []
        for url in originals where !uniqueOriginals.contains(url) {
            uniqueOriginals.append(url)
        }
        let commands = CLISequenceInputMaterialization.materializedInputPairs(
            originalInputURLs: originals,
            executionInputURLs: config.inputFiles
        ).map { pair in
            CLISequenceInputMaterialization.materializationCommand(
                originalURL: pair.originalURL,
                executionURL: pair.executionURL
            ).map(shellEscape).joined(separator: " ")
        }
        return planParameters.merging([
            "originalInputs": .array(uniqueOriginals.map { .file($0) }),
            "inputMaterializationCommands": .array(commands.map { .string($0) }),
        ]) { current, _ in current }
    }

    /// The EsViritu step's input records with the bundle behind each file,
    /// meaning the bundle's manifest, payload and root FASTQ, then the file
    /// EsViritu read. Nil when the files ran as given, or when the lineage
    /// cannot be read, and the step then records the files alone as before.
    static func inputLineageRecords(for config: EsVirituConfig) -> [FileRecord]? {
        guard let originals = config.originalInputFiles,
              let records = try? CLISequenceInputMaterialization.inputRecordsPreservingLineage(
                  originalInputURLs: originals,
                  executionInputURLs: config.inputFiles
              ) else {
            return nil
        }
        // A physical bundle's file can come back spelled with and without
        // /private, which the shared helper's path check counts as two files.
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path).inserted
        }
    }
}
