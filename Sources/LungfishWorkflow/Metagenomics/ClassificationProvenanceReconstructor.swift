// ClassificationProvenanceReconstructor.swift - Rebuilds a Kraken 2 result's run provenance from its sidecar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Rebuilds the folder-level provenance of a single Kraken 2 result from its
/// `classification-result.json` sidecar.
///
/// Older `lungfish build-db kraken2` runs replaced a result folder's
/// `.lungfish-provenance.json` (which described the Kraken 2 and Bracken run)
/// with their own envelope. The original envelope is gone, but the sidecar
/// still records the database, parameters, tool versions, inputs, and outputs.
/// This rebuilds an envelope from those facts and marks it as reconstructed.
public enum ClassificationProvenanceReconstructor {

    /// Resolved-option key naming the file the envelope was rebuilt from.
    public static let reconstructedFromKey = "provenanceReconstructedFrom"

    /// Rebuilds the run envelope for the result in `directory`.
    ///
    /// - Throws: when the sidecar or its report cannot be loaded, or the
    ///   envelope cannot be completed.
    public static func reconstructEnvelope(resultDirectory directory: URL) throws -> ProvenanceEnvelope {
        let result = try ClassificationResult.load(from: directory)
        let config = result.config
        let sidecarURL = directory.appendingPathComponent(ClassificationResult.sidecarFilename)
        let fm = FileManager.default

        let endedAt = persistedSavedAt(sidecarURL: sidecarURL)
            ?? ((try? fm.attributesOfItem(atPath: sidecarURL.path)[.modificationDate]) as? Date)
            ?? Date()
        let startedAt = endedAt.addingTimeInterval(-max(0, result.runtime))

        let brackenRan = result.brackenURL != nil || result.profileOutcome.state != .notRequested
        let workflowName = brackenRan ? "Metagenomics Profiling" : "Metagenomics Classification"

        let inputs = config.inputFiles
            .filter { fm.fileExists(atPath: $0.path) }
            .map { ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: $0, role: .input)) }

        var outputURLs: [(URL, FileRole)] = [
            (result.reportURL, .report),
            (result.outputURL, .output),
        ]
        if let brackenURL = result.brackenURL {
            outputURLs.append((brackenURL, .output))
        }
        if let brackenReport = result.brackenReportURL {
            outputURLs.append((brackenReport, .report))
        }
        outputURLs.append((sidecarURL, .output))
        let outputs = outputURLs
            .filter { fm.fileExists(atPath: $0.0.path) }
            .map { ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileRecord(url: $0.0, role: $0.1)) }

        let parameters = runParameters(config: config)
        var steps = [
            ProvenanceStep(
                toolName: "kraken2",
                toolVersion: result.toolVersion,
                resolvedOptions: parameters,
                inputs: inputs,
                outputs: outputs.filter { descriptor in
                    let name = URL(fileURLWithPath: descriptor.path).lastPathComponent
                    return name == result.reportURL.lastPathComponent
                        || name == result.outputURL.lastPathComponent
                },
                exitStatus: 0,
                wallTimeSeconds: result.runtime
            ),
        ]
        if brackenRan {
            var brackenOptions: [String: ParameterValue] = [:]
            if let resolution = result.profileOutcome.resolution {
                brackenOptions["brackenResolvedRank"] = .string(resolution.rank.code)
                brackenOptions["brackenReadLength"] = .integer(resolution.readLength)
                brackenOptions["brackenThreshold"] = .integer(resolution.threshold)
            }
            brackenOptions["profileState"] = .string(result.profileOutcome.state.rawValue)
            steps.append(ProvenanceStep(
                toolName: "bracken",
                toolVersion: result.profileOutcome.toolVersion ?? "unknown",
                resolvedOptions: brackenOptions,
                outputs: outputs.filter { descriptor in
                    let name = URL(fileURLWithPath: descriptor.path).lastPathComponent
                    return name == result.brackenURL?.lastPathComponent
                        || name == result.brackenReportURL?.lastPathComponent
                },
                exitStatus: 0,
                dependsOn: [steps[0].id]
            ))
        }

        let argv = ["LungfishWorkflow", "reconstruct-classification-provenance", sidecarURL.path]
        var builder = ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: "unknown",
            toolName: "kraken2",
            toolVersion: result.toolVersion
        )
        .argv(argv)
        .options(
            explicit: parameters,
            defaults: [:],
            resolved: [
                reconstructedFromKey: .file(sidecarURL),
                "provenanceReconstructionReason": .string(
                    "The original run provenance was replaced by an older kraken2.sqlite build; rebuilt from classification-result.json."
                ),
                "provenanceReconstructedAt": .string(ISO8601DateFormatter().string(from: Date())),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        for url in config.inputFiles where fm.fileExists(atPath: url.path) {
            builder = try builder.input(url, role: .input)
        }
        for (url, role) in outputURLs where fm.fileExists(atPath: url.path) {
            builder = try builder.output(url, role: role)
        }
        for step in steps {
            builder = builder.step(step)
        }
        return try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
    }

    private static func runParameters(config: ClassificationConfig) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "goal": .string(config.goal.rawValue),
            "database": .string(config.databaseName),
            "databaseVersion": .string(config.databaseVersion),
            "databasePath": .file(config.databasePath.standardizedFileURL),
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "pairedEnd": .boolean(config.isPairedEnd),
            "readFormat": .string(config.readFormat.rawValue),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
        ]
        if let catalogID = config.databaseCatalogID {
            parameters["databaseCatalogID"] = .string(catalogID)
        }
        if let sampleName = config.sampleDisplayName {
            parameters["sampleDisplayName"] = .string(sampleName)
        }
        return parameters
    }

    private static func persistedSavedAt(sidecarURL: URL) -> Date? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedAt = object["savedAt"] as? String else {
            return nil
        }
        return ISO8601DateFormatter().date(from: savedAt)
    }
}
