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
    /// what it recorded before (R3). The read-set plan is no run parameter, since the pipeline writes it
    /// under the resolved defaults (``resolvedRunOptions(for:)``).
    static func inputLineageParameters(for config: EsVirituConfig) -> [String: ParameterValue] {
        guard let originals = config.originalInputFiles else { return [:] }
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
        return [
            "originalInputs": .array(uniqueOriginals.map { .file($0) }),
            "inputMaterializationCommands": .array(commands.map { .string($0) }),
        ]
    }

    /// The options the pipeline's record holds besides its run parameters, which are explicit. The read
    /// format is the one the run used, a resolved default. A configuration cannot tell a format the user
    /// chose from one the planner chose, so the executor adds the user's own `--read-format` to the explicit
    /// options (2.7 E12, B8). A planned run adds its read-set plan here, its one home (E13, B16).
    static func resolvedRunOptions(for config: EsVirituConfig) -> ProvenanceOptions {
        var resolved: [String: ParameterValue] = ["readFormat": .string(config.readFormat.rawValue)]
        resolved.merge(config.readSetPlan?.provenanceParameters ?? [:]) { current, _ in current }
        return ProvenanceOptions(resolvedDefaults: resolved)
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
