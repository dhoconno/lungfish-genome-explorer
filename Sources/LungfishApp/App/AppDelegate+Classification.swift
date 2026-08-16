// AppDelegate+Classification.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3
import os
import LungfishKit

/// One stable row in the human-readable classification batch summary.
struct ClassificationBatchSummaryRow: Sendable, Equatable {
    let sampleId: String
    let status: String
    let profileState: String
    let requestedRank: String
    let resolvedRank: String
    let totalReads: String
    let classifiedReads: String
    let classifiedPercentage: String
    let speciesCount: String
    let dominantSpecies: String
    let message: String
}

/// Aggregate terminal-state decision for a classification batch.
struct ClassificationBatchOutcomeEvaluation: Sendable, Equatable {
    let completedCount: Int
    let degradedCount: Int
    let failedCount: Int
    let requiresWarningCompletion: Bool
    let warningMessage: String
}

/// User-facing and analysis-manifest metadata for one valid Kraken2 result.
struct ClassificationSingleOutcomeMetadata: Sendable, Equatable {
    let requiresWarningCompletion: Bool
    let completionDetail: String
    let analysisSummary: String
    let analysisParameters: [String: AnalysisParameterValue]
}

/// Pure formatting and terminal-state policy shared by app execution and tests.
enum ClassificationBatchOutcomePolicy {
    static let summaryHeader = "sample_id\tstatus\tprofile_state\trequested_rank\tresolved_rank\ttotal_reads\tclassified_reads\tclassified_pct\tspecies_count\tdominant_species\tmessage"

    static func row(sampleId: String, result: ClassificationResult) -> ClassificationBatchSummaryRow {
        let outcome = result.profileOutcome
        let resolution = outcome.resolution
        let requestedRank = resolution?.request.provenanceValue
            ?? result.config.brackenProfileRequest?.rank.provenanceValue
            ?? ""
        let resolvedRank = resolution.flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) } ?? ""
        let message = outcome.state == .degraded
            ? (outcome.message ?? outcome.reason?.rawValue ?? "Bracken profiling degraded")
            : ""
        return ClassificationBatchSummaryRow(
            sampleId: sampleId,
            status: outcome.state == .degraded ? "degraded" : "ok",
            profileState: outcome.state.rawValue,
            requestedRank: requestedRank,
            resolvedRank: resolvedRank,
            totalReads: String(result.tree.totalReads),
            classifiedReads: String(result.tree.classifiedReads),
            classifiedPercentage: String(format: "%.2f", result.tree.classifiedFraction * 100),
            speciesCount: String(result.tree.speciesCount),
            dominantSpecies: result.tree.dominantSpecies?.name ?? "",
            message: message
        )
    }

    static func failedRow(sampleId: String, message: String) -> ClassificationBatchSummaryRow {
        ClassificationBatchSummaryRow(
            sampleId: sampleId,
            status: "failed",
            profileState: "",
            requestedRank: "",
            resolvedRank: "",
            totalReads: "",
            classifiedReads: "",
            classifiedPercentage: "",
            speciesCount: "",
            dominantSpecies: "",
            message: message
        )
    }

    static func summaryTSV(rows: [ClassificationBatchSummaryRow]) -> String {
        let lines = rows.map { row in
            [
                row.sampleId,
                row.status,
                row.profileState,
                row.requestedRank,
                row.resolvedRank,
                row.totalReads,
                row.classifiedReads,
                row.classifiedPercentage,
                row.speciesCount,
                row.dominantSpecies,
                row.message,
            ]
            .map(appTSVField)
            .joined(separator: "\t")
        }
        return ([summaryHeader] + lines).joined(separator: "\n")
    }

    static func evaluate(
        rows: [ClassificationBatchSummaryRow],
        sqliteWarning: String?
    ) -> ClassificationBatchOutcomeEvaluation {
        let completedCount = rows.filter { $0.status == "ok" }.count
        let degradedCount = rows.filter { $0.status == "degraded" }.count
        let failedCount = rows.filter { $0.status == "failed" }.count
        var warnings: [String] = []
        if degradedCount > 0 {
            warnings.append("\(degradedCount) sample\(degradedCount == 1 ? "" : "s") retained Kraken2 classifications but Bracken profiling degraded")
        }
        if failedCount > 0 {
            warnings.append("\(failedCount) sample\(failedCount == 1 ? "" : "s") failed")
        }
        if let sqliteWarning, !sqliteWarning.isEmpty {
            warnings.append(sqliteWarning)
        }
        return ClassificationBatchOutcomeEvaluation(
            completedCount: completedCount,
            degradedCount: degradedCount,
            failedCount: failedCount,
            requiresWarningCompletion: !warnings.isEmpty,
            warningMessage: warnings.joined(separator: "; ")
        )
    }

    static func singleResultMetadata(
        for result: ClassificationResult
    ) -> ClassificationSingleOutcomeMetadata {
        let tree = result.tree
        let outcome = result.profileOutcome
        var parameters = result.config.summaryParameters()
        parameters["profileState"] = .string(outcome.state.rawValue)
        if let rank = outcome.resolution.flatMap({ BrackenDatabaseCapabilities.levelCode(for: $0.rank) }) {
            parameters["brackenResolvedRank"] = .string(rank)
        }
        if let reason = outcome.reason {
            parameters["brackenDegradationReason"] = .string(reason.rawValue)
        }
        if let message = outcome.message {
            parameters["brackenMessage"] = .string(message)
        }
        if let toolVersion = outcome.toolVersion {
            parameters["brackenToolVersion"] = .string(toolVersion)
        }

        let classificationDetail = "\(tree.classifiedReads) of \(tree.totalReads) reads classified"
        let analysisBase = "\(tree.totalReads) reads, \(tree.classifiedReads) classified"
        guard outcome.state == .degraded else {
            return ClassificationSingleOutcomeMetadata(
                requiresWarningCompletion: false,
                completionDetail: classificationDetail,
                analysisSummary: analysisBase,
                analysisParameters: parameters
            )
        }

        let reason = outcome.message ?? outcome.reason?.rawValue ?? "unknown reason"
        let resolvedRank = outcome.resolution
            .flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) }
            ?? "unknown"
        return ClassificationSingleOutcomeMetadata(
            requiresWarningCompletion: true,
            completionDetail: "\(classificationDetail); Bracken profiling degraded at resolved rank \(resolvedRank): \(reason)",
            analysisSummary: "\(analysisBase); profiling degraded at resolved rank \(resolvedRank): \(reason)",
            analysisParameters: parameters
        )
    }
}

extension AppDelegate {
    // MARK: - Direct-Launch Classification Methods

    /// Launches Kraken2 classification directly (skipping the wizard chooser step).
    ///
    /// Called from the sidebar's "Run" button when the Classify Reads operation is selected.
    @objc func launchKraken2Classification(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .kraken2)
    }

    /// Launches EsViritu viral detection directly (skipping the wizard chooser step).
    @objc func launchEsVirituDetection(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .esViritu)
    }

    /// Launches TaxTriage comprehensive triage directly (skipping the wizard chooser step).
    @objc func launchTaxTriage(_ sender: Any?) {
        showFASTQOperationsDialog(sender, initialCategory: .classification, initialToolID: .taxTriage)
    }

    /// Runs the classification pipeline, dispatching based on the config's goal.
    ///
    /// Registers the operation with ``OperationCenter`` so it appears in the
    /// Operations Panel with live progress updates.
    ///
    /// - `.classify`: Runs Kraken2 only, displays taxonomy browser.
    /// - `.profile`: Runs Kraken2 + Bracken, displays taxonomy browser with abundances.
    /// - `.extract`: Runs Kraken2, displays taxonomy browser, then auto-presents
    ///   the extraction sheet so the user can select taxa to extract.
    internal func runClassification(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        guard let first = configs.first else { return }
        if configs.count == 1 {
            runClassification(config: first, viewerController: viewerController, routeContext: routeContext)
            return
        }
        runClassificationBatch(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    /// Resolves input FASTQ files using ``FASTQSourceResolver``, materializing
    /// virtual datasets as needed.
    ///
    /// Delegates to the centralized resolver from `LungfishWorkflow`, injecting
    /// `FASTQDerivativeService` as the materializer for derived bundles.
    /// Finds the `.lungfishfastq` bundle URL from a list of input file URLs.
    ///
    /// Handles two cases:
    /// 1. The URL itself is a bundle (e.g., `SRR123.lungfishfastq`)
    /// 2. The URL is a file inside a bundle (e.g., `SRR123.lungfishfastq/reads.fastq.gz`)
    static func findSourceBundle(for inputFiles: [URL]) -> URL? {
        for url in inputFiles {
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: url) {
                return bundleURL
            }
            if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: url) {
                return referenceBundleURL
            }
        }
        return nil
    }

    nonisolated internal static func durableSequenceInputsForProvenance(_ inputFiles: [URL]) -> [URL] {
        inputFiles.flatMap { inputURL -> [URL] in
            let standardizedInput = inputURL.standardizedFileURL
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInput) {
                if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
                    let payloadURLs = durableMaterializedPayloadURLs(manifest.payload, in: bundleURL)
                    return payloadURLs.isEmpty ? [bundleURL] : payloadURLs
                }
                if let physicalFASTQs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL),
                   !physicalFASTQs.isEmpty {
                    return physicalFASTQs
                }
                return [bundleURL]
            }
            if let resolvedSequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedInput) {
                return [resolvedSequenceURL]
            }
            return [standardizedInput]
        }
    }

    nonisolated private static func durableDerivedPayloadURLs(
        _ payload: FASTQDerivativePayload,
        in bundleURL: URL
    ) -> [URL] {
        let candidates: [URL]
        switch payload {
        case .subset(let readIDListFilename):
            candidates = [
                validatedFASTQBundleMember(readIDListFilename, in: bundleURL, field: "payload.subset.readIDListFilename"),
            ].compactMap { $0 }
        case .trim(let trimPositionFilename):
            candidates = [
                validatedFASTQBundleMember(trimPositionFilename, in: bundleURL, field: "payload.trim.trimPositionFilename"),
            ].compactMap { $0 }
        case .full(let fastqFilename):
            candidates = [
                validatedFASTQBundleMember(fastqFilename, in: bundleURL, field: "payload.full.fastqFilename"),
            ].compactMap { $0 }
        case .fullFASTA(let fastaFilename):
            candidates = [
                validatedFASTQBundleMember(fastaFilename, in: bundleURL, field: "payload.fullFASTA.fastaFilename"),
            ].compactMap { $0 }
        case .fullPaired(let r1Filename, let r2Filename):
            candidates = [
                validatedFASTQBundleMember(r1Filename, in: bundleURL, field: "payload.fullPaired.r1Filename"),
                validatedFASTQBundleMember(r2Filename, in: bundleURL, field: "payload.fullPaired.r2Filename"),
            ].compactMap { $0 }
        case .fullMixed(let classification):
            candidates = classification.files.compactMap {
                validatedFASTQBundleMember($0.filename, in: bundleURL, field: "readClassification.files[].filename")
            }
        case .demuxedVirtual(_, let readIDListFilename, let previewFilename, let trimPositionsFilename, let orientMapFilename):
            candidates = [
                validatedFASTQBundleMember(readIDListFilename, in: bundleURL, field: "payload.demuxedVirtual.readIDListFilename"),
                validatedFASTQBundleMember(previewFilename, in: bundleURL, field: "payload.demuxedVirtual.previewFilename"),
                trimPositionsFilename.flatMap {
                    validatedFASTQBundleMember($0, in: bundleURL, field: "payload.demuxedVirtual.trimPositionsFilename")
                },
                orientMapFilename.flatMap {
                    validatedFASTQBundleMember($0, in: bundleURL, field: "payload.demuxedVirtual.orientMapFilename")
                },
            ].compactMap { $0 }
        case .orientMap(let orientMapFilename, let previewFilename):
            candidates = [
                validatedFASTQBundleMember(orientMapFilename, in: bundleURL, field: "payload.orientMap.orientMapFilename"),
                validatedFASTQBundleMember(previewFilename, in: bundleURL, field: "payload.orientMap.previewFilename"),
            ].compactMap { $0 }
        case .demuxGroup:
            candidates = []
        }
        return candidates
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated private static func durableMaterializedPayloadURLs(
        _ payload: FASTQDerivativePayload,
        in bundleURL: URL
    ) -> [URL] {
        switch payload {
        case .full, .fullFASTA, .fullPaired, .fullMixed:
            return durableDerivedPayloadURLs(payload, in: bundleURL)
        case .subset, .trim, .demuxedVirtual, .demuxGroup, .orientMap:
            return []
        }
    }

    nonisolated internal static func durableSequenceInputRecordsForProvenance(_ inputFiles: [URL]) -> [FileRecord] {
        inputFiles.flatMap { inputURL -> [FileRecord] in
            let standardizedInput = inputURL.standardizedFileURL
            guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedInput),
                  let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
                return durableSequenceInputsForProvenance([standardizedInput]).map {
                    ProvenanceRecorder.fileRecord(url: $0, role: .input)
                }
            }

            var durableURLs = [FASTQBundle.derivedManifestURL(in: bundleURL)]
            durableURLs += durableDerivedPayloadURLs(manifest.payload, in: bundleURL)

            let rootBundleURL = FASTQBundle.resolveBundle(
                relativePath: manifest.rootBundleRelativePath,
                from: bundleURL
            )
            if let rootSequenceURL = try? FASTQBundle.validatedBundleMemberURL(
                for: manifest.rootFASTQFilename,
                in: rootBundleURL,
                field: "rootFASTQFilename",
                allowExistingSymlinkEscape: true
            ), FileManager.default.fileExists(atPath: rootSequenceURL.path) {
                durableURLs.append(rootSequenceURL)
            }

            var seen = Set<String>()
            return durableURLs.compactMap { url in
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return nil }
                return ProvenanceRecorder.fileRecord(url: url, role: .input)
            }
        }
    }

    /// Persists diagnosable batch artifacts when setup fails before any sample
    /// pipeline can create child provenance.
    @discardableResult
    nonisolated internal static func persistClassificationBatchSetupFailure(
        batchRoot: URL,
        configurations: [ClassificationConfig],
        sampleIDs: [String],
        command: [String],
        startedAt: Date,
        completedAt: Date,
        errorDescription: String
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: batchRoot, withIntermediateDirectories: true)

        let message = "Batch setup failed: \(errorDescription)"
        let rows = sampleIDs.map {
            ClassificationBatchOutcomePolicy.failedRow(sampleId: $0, message: message)
        }
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(
                schemaVersion: 2,
                createdAt: startedAt,
                sampleCount: configurations.count
            ),
            goal: configurations.first?.goal.rawValue ?? ClassificationConfig.Goal.classify.rawValue,
            databaseName: configurations.first?.databaseName ?? "unknown",
            databaseVersion: configurations.first?.databaseVersion ?? "",
            summaryTSV: summaryURL.lastPathComponent,
            samples: [],
            completedCount: 0,
            degradedCount: 0,
            failedCount: configurations.count
        )

        do {
            try ClassificationBatchOutcomePolicy.summaryTSV(rows: rows)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
            try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)

            return try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
                batchRoot: batchRoot,
                manifest: manifest,
                summaryURL: summaryURL,
                sqliteURL: nil,
                command: command,
                additionalStderr: [message],
                additionalInputURLs: configurations.flatMap { $0.originalInputFiles ?? $0.inputFiles },
                context: ClassificationBatchProvenanceContext(
                    configurations: configurations,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        } catch {
            let fallbackMessage = [
                message,
                "Failed to persist setup summary, manifest, or standard root provenance: \(error.localizedDescription)",
            ].joined(separator: "\n")
            return try persistClassificationBatchFailureRoot(
                batchRoot: batchRoot,
                configurations: configurations,
                command: command,
                startedAt: startedAt,
                completedAt: completedAt,
                failureStage: "batch-setup-artifact-publication",
                errorDescription: fallbackMessage,
                additionalOutputURLs: [
                    summaryURL,
                    batchRoot.appendingPathComponent(ClassificationBatchResultManifest.filename),
                ]
            )
        }
    }

    /// Writes a minimal but complete root failure envelope directly. This path
    /// intentionally does not require a summary or result manifest: those are
    /// precisely the artifacts that may have failed to publish.
    @discardableResult
    nonisolated internal static func persistClassificationBatchFailureRoot(
        batchRoot: URL,
        configurations: [ClassificationConfig],
        command: [String],
        startedAt: Date,
        completedAt: Date,
        failureStage: String,
        errorDescription: String,
        additionalOutputURLs: [URL] = []
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: batchRoot, withIntermediateDirectories: true)

        let inputURLs = uniqueClassificationBatchURLs(
            configurations.flatMap { $0.originalInputFiles ?? $0.inputFiles }
        )
        let inputDescriptors = inputURLs.map {
            ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(url: $0, role: .input)
            )
        }
        let databaseDescriptors = uniqueClassificationBatchDescriptors(
            configurations.map(classificationDatabaseReferenceDescriptor)
        )

        let outputDirectories = uniqueClassificationBatchURLs(
            configurations.map(\.outputDirectory)
        )
        var childEnvelopes = outputDirectories.compactMap { directory -> ProvenanceEnvelope? in
            ProvenanceRecorder.loadEnvelope(from: directory)
        }
        if let existingRootEnvelope = ProvenanceRecorder.loadEnvelope(from: batchRoot),
           existingRootEnvelope.toolName != "Lungfish Classification Batch" {
            childEnvelopes.append(existingRootEnvelope)
        }
        let childSteps = childEnvelopes.flatMap(\.steps)
        let childFiles = childEnvelopes.flatMap(\.files)
        let childOutputs = uniqueClassificationBatchDescriptors(
            childEnvelopes.flatMap(\.outputs) + childEnvelopes.compactMap(\.output)
        )
        let directoriesWithoutChildEnvelope = outputDirectories.filter { directory in
            guard FileManager.default.fileExists(atPath: directory.path) else { return false }
            return ProvenanceRecorder.loadEnvelope(from: directory) == nil
        }
        let unprovenancedOutputs = directoriesWithoutChildEnvelope.map {
            ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(url: $0, role: .output)
            )
        }
        let artifactOutputs = additionalOutputURLs.compactMap(
            classificationRegularOutputDescriptor
        )
        let outputs = uniqueClassificationBatchDescriptors(
            artifactOutputs + childOutputs + unprovenancedOutputs
        )
        let runtimeIdentity = ProvenanceRuntimeIdentity()
        let wallTime = max(0, completedAt.timeIntervalSince(startedAt))
        let failureOptions = classificationBatchFailureOptions(
            configurations: configurations,
            failureStage: failureStage
        )
        let failureInputs = uniqueClassificationBatchDescriptors(
            inputDescriptors + databaseDescriptors + childOutputs
        )
        let failureStep = ProvenanceStep(
            toolName: "Lungfish Classification Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: command,
            durableReplayArgv: command,
            resolvedOptions: failureOptions.resolvedDefaults,
            runtimeIdentity: runtimeIdentity,
            inputs: failureInputs,
            outputs: artifactOutputs,
            exitStatus: 1,
            wallTimeSeconds: wallTime,
            stderr: errorDescription,
            dependsOn: childSteps.map(\.id),
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "Classification Batch",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Classification Batch",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "Lungfish Classification Batch",
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: command,
            durableReplayArgv: command,
            options: failureOptions,
            runtimeIdentity: runtimeIdentity,
            files: uniqueClassificationBatchDescriptors(
                inputDescriptors + databaseDescriptors + childFiles + outputs
            ),
            output: outputs.first,
            outputs: outputs,
            steps: childSteps + [failureStep],
            wallTimeSeconds: wallTime,
            exitStatus: 1,
            stderr: errorDescription
        )
        return try ProvenanceWriter().write(envelope, to: batchRoot)
    }

    nonisolated private static func classificationBatchFailureOptions(
        configurations: [ClassificationConfig],
        failureStage: String
    ) -> ProvenanceOptions {
        let first = configurations.first
        let sampleConfigurations = configurations.map { config in
            ParameterValue.dictionary([
                "goal": .string(config.goal.rawValue),
                "inputFormat": .string(config.inputFormat.rawValue),
                "inputPaths": .array(
                    (config.originalInputFiles ?? config.inputFiles)
                        .map { .string($0.standardizedFileURL.path) }
                ),
                "outputDirectory": .string(config.outputDirectory.standardizedFileURL.path),
                "pairedEnd": .boolean(config.isPairedEnd),
                "databaseName": .string(config.databaseName),
                "databaseVersion": .string(config.databaseVersion),
                "databasePath": .string(config.databasePath.standardizedFileURL.path),
                "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
                "databaseCatalogID": config.databaseCatalogID.map(ParameterValue.string) ?? .null,
                "databaseInstallationRecipe": config.databaseInstallationRecipe
                    .map { .string($0.provenanceValue) } ?? .null,
                "confidence": .number(config.confidence),
                "minimumHitGroups": .integer(config.minimumHitGroups),
                "threads": .integer(config.threads),
                "memoryMapping": .boolean(config.memoryMapping),
                "quickMode": .boolean(config.quickMode),
                "extraArguments": .array(config.extraArguments.map(ParameterValue.string)),
                "brackenRankRequest": config.brackenProfileRequest
                    .map { .string($0.rank.provenanceValue) } ?? .null,
                "brackenReadLength": config.brackenProfileRequest
                    .map { .integer($0.readLength) } ?? .null,
                "brackenThreshold": config.brackenProfileRequest
                    .map { .integer($0.threshold) } ?? .null,
            ])
        }
        let explicit: [String: ParameterValue] = [
            "goal": first.map { .string($0.goal.rawValue) } ?? .null,
            "databaseName": first.map { .string($0.databaseName) } ?? .null,
            "databaseVersion": first.map { .string($0.databaseVersion) } ?? .null,
            "databasePath": first.map { .string($0.databasePath.standardizedFileURL.path) } ?? .null,
            "databaseDigest": first?.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": first?.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": first?.databaseInstallationRecipe
                .map { .string($0.provenanceValue) } ?? .null,
            "configurationCount": .integer(configurations.count),
            "failureStage": .string(failureStage),
            "sampleConfigurations": .array(sampleConfigurations),
        ]
        let defaults: [String: ParameterValue] = [
            "inputFormat": .string(SequenceFormat.fastq.rawValue),
            "confidence": .number(0),
            "minimumHitGroups": .integer(2),
            "threads": .integer(4),
            "memoryMapping": .boolean(false),
            "quickMode": .boolean(false),
            "brackenRankRequest": .string("automatic"),
            "brackenReadLength": .integer(150),
            "brackenThreshold": .integer(10),
            "summaryFilename": .string("classification-batch-summary.tsv"),
            "sqliteFilename": .string("kraken2.sqlite"),
            "manifestFilename": .string(ClassificationBatchResultManifest.filename),
        ]
        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: [
                "failureStage": .string(failureStage),
                "sampleConfigurations": .array(sampleConfigurations),
                "databasePaths": .array(
                    uniqueClassificationBatchURLs(configurations.map(\.databasePath))
                        .map { .string($0.path) }
                ),
                "databaseDigests": .array(
                    Array(Set(configurations.compactMap(\.databaseDigest)))
                        .sorted()
                        .map(ParameterValue.string)
                ),
            ]
        )
    }

    nonisolated private static func classificationDatabaseReferenceDescriptor(
        _ config: ClassificationConfig
    ) -> ProvenanceFileDescriptor {
        let path = config.databasePath.standardizedFileURL
        let receipt = ProvenanceRecorder.loadEnvelope(from: path)
        let receiptDigest = receipt?.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue
        let digest = config.databaseDigest ?? receiptDigest
        let receiptSize: UInt64? = receipt.map { envelope in
            var seen = Set<String>()
            return envelope.outputs.reduce(UInt64(0)) { total, descriptor in
                guard seen.insert(descriptor.path).inserted else { return total }
                return total + (descriptor.fileSize ?? 0)
            }
        }
        return ProvenanceFileDescriptor(
            path: path.path,
            checksumSHA256: digest,
            fileSize: receiptSize,
            format: .unknown,
            role: .reference,
            sourceProvenancePath: receipt.map { _ in
                path.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
            }
        )
    }

    nonisolated private static func classificationRegularOutputDescriptor(
        _ url: URL
    ) -> ProvenanceFileDescriptor? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return ProvenanceFileDescriptor(
            fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(url: url, role: .output)
        )
    }

    nonisolated private static func uniqueClassificationBatchURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    nonisolated private static func uniqueClassificationBatchDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        return descriptors.filter {
            seen.insert("\($0.role.rawValue)\u{0}\($0.path)").inserted
        }
    }

    /// Builds a runnable shell command that reproduces each sample in a batch
    /// with its durable inputs, resolved Kraken settings, Bracken request, and
    /// final per-sample output directory.
    nonisolated internal static func classificationBatchReplayCommand(
        configurations: [ClassificationConfig]
    ) -> [String] {
        let commands = configurations.map { config -> String in
            var arguments = ["conda", "classify"]
            arguments += ["--db", config.databaseName]
            arguments += ["--output-dir", config.outputDirectory.path]
            arguments += ["--confidence", String(config.confidence)]
            arguments += ["--min-hit-groups", String(config.minimumHitGroups)]
            arguments += ["--threads", String(config.threads)]

            if config.isPairedEnd {
                arguments.append("--paired")
            }
            if config.memoryMapping {
                arguments.append("--memory-mapping")
            }
            if config.quickMode {
                arguments.append("--quick")
            }
            if !config.extraArguments.isEmpty {
                arguments += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
            }
            if config.goal == .profile {
                let request = config.brackenProfileRequest ?? .automaticDefault
                arguments.append("--profile")
                arguments += ["--bracken-read-length", String(request.readLength)]
                arguments += ["--bracken-threshold", String(request.threshold)]
                if case .explicit(let rank) = request.rank {
                    arguments += ["--bracken-level", rank.code]
                }
            }

            arguments += (config.originalInputFiles ?? config.inputFiles).map(\.path)
            let classificationCommand = ([CLICommandIdentity.executableName] + arguments)
                .map(shellEscape)
                .joined(separator: " ")
            return (classificationDatabaseReplayGuards(for: config) + [classificationCommand])
                .joined(separator: "; ")
        }
        return ["/bin/sh", "-c", (["set -e"] + commands).joined(separator: "\n")]
    }

    /// `--db` is a registry display name, so a replay also asserts the exact
    /// installation receipt captured by the app before allowing that lookup.
    nonisolated private static func classificationDatabaseReplayGuards(
        for config: ClassificationConfig
    ) -> [String] {
        let databasePath = config.databasePath.standardizedFileURL
        let receiptURL = databasePath.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let receipt = ProvenanceRecorder.loadEnvelope(from: databasePath)
        let digest = config.databaseDigest
            ?? receipt?.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue
            ?? "__missing_database_digest__"
        let escapedPath = shellEscape(databasePath.path)
        let escapedReceipt = shellEscape(receiptURL.path)
        let escapedDigest = shellEscape(digest)
        let receiptDigest = "$(/usr/bin/plutil -extract options.resolvedDefaults.payloadAggregateSHA256.value raw -o - \(escapedReceipt))"
        let receiptPath = "$(/usr/bin/plutil -extract options.resolvedDefaults.intendedFinalPath.value raw -o - \(escapedReceipt))"
        let receiptExitStatus = "$(/usr/bin/plutil -extract exitStatus raw -o - \(escapedReceipt))"
        let databaseInfoCommand = [
            CLICommandIdentity.executableName,
            "conda",
            "db",
            "info",
            "--no-color",
            config.databaseName,
        ].map(shellEscape).joined(separator: " ")
        let registryPath = "$(\(databaseInfoCommand) | /usr/bin/sed -n "
            + shellEscape("s/^Location[[:space:]]*:[[:space:]]*//p")
            + ")"
        return [
            "/bin/test -d \(escapedPath)",
            "/bin/test -f \(escapedReceipt)",
            "/bin/test \"\(receiptDigest)\" = \(escapedDigest)",
            "/bin/test \"\(receiptPath)\" = \(escapedPath)",
            "/bin/test \"\(receiptExitStatus)\" = 0",
            "/bin/test \"\(registryPath)\" = \(escapedPath)",
        ]
    }

    nonisolated private static func validatedFASTQBundleMember(
        _ relativePath: String,
        in bundleURL: URL,
        field: String
    ) -> URL? {
        try? FASTQBundle.validatedBundleMemberURL(for: relativePath, in: bundleURL, field: field)
    }

    ///
    /// Called at the start of `runClassification` / `runEsViritu` / `runTaxTriage`
    /// so that dialogs appear instantly and materialization happens as the first
    /// pipeline step after the user clicks Run.
    internal func resolveInputFiles(
        _ inputFiles: [URL],
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [URL] {
        let resolver = FASTQSourceResolver()
        resolver.materializer = { bundleURL, tempDir, progressCallback in
            try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDir,
                progress: { msg in progressCallback(msg) }
            )
        }

        var resolved: [URL] = []
        for inputURL in inputFiles {
            try Task.checkCancellation()

            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) {
                let urls = try await resolver.resolve(
                    bundleURL: bundleURL,
                    tempDirectory: tempDirectory,
                    progress: { _, msg in progress?(msg) }
                )
                resolved.append(contentsOf: urls)
                continue
            }

            if let resolvedSequenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) {
                resolved.append(resolvedSequenceURL)
                continue
            }

            resolved.append(inputURL)
        }
        return resolved
    }

    internal func runClassification(
        config: ClassificationConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Classification"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL) {
                config.outputDirectory = analysisDir
            }
        }

        let pipeline = ClassificationPipeline()

        // Build a descriptive title from the first input file and the goal.
        let inputName = config.inputFiles.first?.lastPathComponent ?? "reads"
        let goalLabel: String
        switch config.goal {
        case .classify: goalLabel = "Classifying"
        case .profile:  goalLabel = "Profiling"
        case .extract:  goalLabel = "Classifying (extract)"
        }
        let operationTitle = "\(goalLabel) \(inputName)"

        // Register the operation with OperationCenter so it appears in the Operations Panel.
        let cliCmd = OperationCenter.buildCLICommand(subcommand: "conda classify", args: {
            var args = ["--db", config.databasePath.path]
            args += config.inputFiles.map(\.path)
            return args
        }())
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Starting Kraken2 with \(config.databaseName)...",
            operationType: .classification,
            cliCommand: cliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs as the first pipeline step.
                // This creates temp files that are cleaned up after classification.
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "classify-", contextURL: config.inputFiles.first ?? config.databasePath)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    config.inputFiles,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                ) ?? config.inputFiles

                // Build a config with resolved (materialized) input files
                var resolvedConfig = config
                // Preserve the original bundle display name before materialization
                // replaces inputFiles, so the taxonomy viewer shows the real sample
                // name instead of "materialized".
                if resolvedConfig.sampleDisplayName == nil {
                    let bundleName = config.inputFiles.first?
                        .deletingPathExtension().lastPathComponent
                    resolvedConfig.sampleDisplayName = bundleName
                }
                // Preserve original input files before materialization replaces them,
                // so extraction can locate a valid source FASTQ after the materialized
                // temp file is deleted.
                if resolvedConfig.originalInputFiles == nil {
                    resolvedConfig.originalInputFiles = config.inputFiles
                }
                resolvedConfig.inputFiles = resolvedFiles

                let progressCallback: @Sendable (Double, String) -> Void = { progress, message in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.showProgress(message)
                            _ = OperationCenter.shared.update(
                                id: opID,
                                progress: max(0, min(1, progress)),
                                detail: message
                            )
                            OperationCenter.shared.log(id: opID, level: .info, message: message)
                        }
                    }
                }

                let result: ClassificationResult
                switch resolvedConfig.goal {
                case .classify, .extract:
                    result = try await pipeline.classify(config: resolvedConfig, progress: progressCallback)
                case .profile:
                    result = try await pipeline.profile(config: resolvedConfig, progress: progressCallback)
                }

                let capturedConfig = config
                let outcomeMetadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: result)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()

                        if outcomeMetadata.requiresWarningCompletion {
                            _ = OperationCenter.shared.completeWithWarning(
                                id: opID,
                                detail: outcomeMetadata.completionDetail
                            )
                        } else {
                            _ = OperationCenter.shared.complete(
                                id: opID,
                                detail: outcomeMetadata.completionDetail
                            )
                        }

                        viewerController.displayTaxonomyResult(result)

                        // For the extract goal, auto-present the unified
                        // extraction dialog after showing the taxonomy browser
                        // so the user can pick taxa.
                        if capturedConfig.goal == .extract,
                           viewerController.taxonomyViewController != nil,
                           let topSpecies = result.tree.dominantSpecies,
                           let window = viewerController.view.window {
	                            let ctx = TaxonomyReadExtractionAction.Context(
	                                tool: .kraken2,
	                                resultPath: capturedConfig.outputDirectory,
	                                selections: [ClassifierRowSelector(
	                                    sampleId: nil,
	                                    accessions: [],
	                                    taxIds: [topSpecies.taxId]
	                                )],
	                                suggestedName: "kraken2_\(topSpecies.name.replacingOccurrences(of: " ", with: "_"))",
	                                routeContext: routeContext
	                            )
                            TaxonomyReadExtractionAction.shared.present(context: ctx, hostWindow: window)
                        }

                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifest
                        if let bundleURL = Self.findSourceBundle(for: capturedConfig.originalInputFiles ?? capturedConfig.inputFiles) {
                            let entry = AnalysisManifestEntry(
                                tool: "kraken2",
                                analysisDirectoryName: Self.analysisManifestDirectoryName(
                                    for: capturedConfig.outputDirectory,
                                    projectURL: routeContext?.projectURL
                                ),
                                displayName: "Kraken2 Classification",
                                parameters: outcomeMetadata.analysisParameters,
                                summary: outcomeMetadata.analysisSummary,
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)

                        let alert = NSAlert()
                        alert.messageText = "Classification Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }

        // Wire cancellation so the Operations Panel cancel button works
        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }


    /// Runs the EsViritu viral detection pipeline.
    ///
    /// Registers the operation with ``OperationCenter`` and displays the
    /// ``EsVirituResultViewController`` when complete.
    internal func runEsViritu(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext: OperationRouteContext? = nil
    ) {
        guard let first = configs.first else { return }
        if configs.count == 1 {
            runEsViritu(config: first, viewerController: viewerController, routeContext: routeContext)
            return
        }
        runEsVirituBatch(configs: configs, viewerController: viewerController, routeContext: routeContext)
    }

    internal func runEsViritu(
        config: EsVirituConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        // Single-sample runs also use batch-style layout (sample in a subdirectory)
        // so there's only one display path for EsViritu results.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "EsViritu detection"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
                tool: "esviritu", in: projectURL, isBatch: true
            ) {
                let sampleSubdir = batchDir.appendingPathComponent(config.sampleName, isDirectory: true)
                try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                config.outputDirectory = sampleSubdir
            }
        }

        let esCliArgs: [String] = {
            var args = ["--input"] + config.inputFiles.map(\.path)
            args += ["--sample", config.sampleName]
            return args
        }()
        let esCliCmd = OperationCenter.buildCLICommand(subcommand: "esviritu detect", args: esCliArgs)
        let esCliArgv = [CLICommandIdentity.executableName, "esviritu", "detect"] + esCliArgs
        let opID = OperationCenter.shared.start(
            title: "EsViritu \(config.sampleName)",
            detail: "Starting EsViritu viral detection\u{2026}",
            operationType: .classification,
            cliCommand: esCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs before running EsViritu
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "esviritu-", contextURL: config.inputFiles.first ?? config.outputDirectory)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                let resolvedFiles = try await self?.resolveInputFiles(
                    config.inputFiles,
                    tempDirectory: materializeTempDir,
                    progress: { message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                ) ?? config.inputFiles

                var resolvedConfig = config
                resolvedConfig.inputFiles = resolvedFiles

                let pipeline = EsVirituPipeline()
                let result = try await pipeline.detect(
                    config: resolvedConfig,
                    progress: { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: max(0, min(1, progress)),
                                    detail: message
                                )
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )

                // Parse EsViritu output files into the LungfishIO display model.
                let detections = (try? EsVirituDetectionParser.parse(url: result.detectionURL)) ?? []
                let assemblies = EsVirituDetectionParser.groupByAssembly(detections)
                let taxProfile: [ViralTaxProfile]
                if let tpURL = result.taxProfileURL {
                    taxProfile = (try? EsVirituTaxProfileParser.parse(url: tpURL)) ?? []
                } else {
                    taxProfile = []
                }
                let coverageWindows: [ViralCoverageWindow]
                if let cvURL = result.coverageURL {
                    coverageWindows = (try? EsVirituCoverageParser.parse(url: cvURL)) ?? []
                } else {
                    coverageWindows = []
                }

                let ioResult = LungfishIO.EsVirituResult(
                    sampleId: config.sampleName,
                    detections: detections,
                    assemblies: assemblies,
                    taxProfile: taxProfile,
                    coverageWindows: coverageWindows,
                    totalFilteredReads: detections.first?.filteredReadsInSample ?? 0,
                    detectedFamilyCount: Set(detections.compactMap(\.family)).count,
                    detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
                    runtime: result.runtime,
                    toolVersion: result.toolVersion
                )

                // Build the SQLite database at the parent batch directory so
                // the single-sample result opens directly into the DB-backed view.
                // config.outputDirectory is the per-sample subdir; its parent is
                // the batch root the sidebar shows.
                let esvBatchRoot = config.outputDirectory.deletingLastPathComponent()
                var dbBuildErrorDescription: String?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building EsViritu database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building esviritu.sqlite from single-sample result")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "esviritu", resultURL: esvBatchRoot, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runEsViritu: Failed to build esviritu.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }

                let summaryURL = esvBatchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
                let sampleID = MetagenomicsSampleGrouper.sanitizeSampleId(config.sampleName)
                let summaryLines = [
                    "sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror",
                    [
                        appTSVField(sampleID),
                        "ok",
                        String(result.virusCount),
                        String(ioResult.detectedFamilyCount),
                        String(ioResult.detectedSpeciesCount),
                        "",
                    ].joined(separator: "\t"),
                ]
                do {
                    try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
                } catch {
                    appDelegateLogger.warning("runEsViritu: Failed to write summary TSV - \(error.localizedDescription, privacy: .public)")
                }

                let manifest = EsVirituBatchResultManifest(
                    header: MetagenomicsBatchManifestHeader(
                        schemaVersion: 1,
                        createdAt: Date(),
                        sampleCount: 1
                    ),
                    summaryTSV: summaryURL.lastPathComponent,
                    samples: [
                        MetagenomicsBatchSampleRecord(
                            sampleId: sampleID,
                            resultDirectory: appRelativePath(from: esvBatchRoot, to: config.outputDirectory),
                            inputFiles: config.inputFiles.map(\.path),
                            isPairedEnd: config.isPairedEnd
                        )
                    ]
                )

                do {
                    try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: esvBatchRoot)
                } catch {
                    appDelegateLogger.warning("runEsViritu: Failed to save batch manifest - \(error.localizedDescription, privacy: .public)")
                }

                try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
                    batchRoot: esvBatchRoot,
                    manifest: manifest,
                    summaryURL: summaryURL,
                    sqliteURL: esvBatchRoot.appendingPathComponent("esviritu.sqlite"),
                    command: esCliArgv
                )

                let capturedResult = ioResult
                let capturedConfig = config
                let capturedDBBuildError = dbBuildErrorDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        if let dbError = capturedDBBuildError {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                            )
                        }
                        let completionDetail = capturedResult.detections.isEmpty
                            ? "No viral hits detected"
                            : "\(capturedResult.detections.count) viruses detected in \(capturedResult.detectedFamilyCount) families"
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: completionDetail
                        )
                        // Reload sidebar so the new result bundle appears.
                        // User clicks the new result to view it (batch-only display path).
                        self?.targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifest
                        if let bundleURL = Self.findSourceBundle(for: capturedConfig.inputFiles) {
                            let entry = AnalysisManifestEntry(
                                tool: "esviritu",
                                analysisDirectoryName: Self.analysisManifestDirectoryName(
                                    for: capturedConfig.outputDirectory,
                                    projectURL: routeContext?.projectURL
                                ),
                                displayName: "EsViritu Detection",
                                parameters: capturedConfig.summaryParameters(),
                                summary: "\(capturedResult.detections.count) viruses detected in \(capturedResult.detectedFamilyCount) families",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: errorDesc)

                        let alert = NSAlert()
                        alert.messageText = "EsViritu Failed"
                        alert.informativeText = errorDesc
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Runs Kraken2/Bracken profiling in batch mode (one run per sample).
    private func runClassificationBatch(
        configs: [ClassificationConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        guard !configs.isEmpty else { return }
        let batchStartedAt = Date()

        // Redirect output to project-level Analyses/ folder when a project is open.
        var configs = configs
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let projectURL = routeContext?.projectURL
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Classification batch"
        ) else { return }
        if let projectURL, let batchDir = try? AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: projectURL, isBatch: true) {
            for i in configs.indices {
                // Try the centralized helper; on failure, fall back to the old semantics.
                if let sampleSubdir = try? AnalysesFolder.batchSampleDirectory(named: configs[i].outputDirectory.lastPathComponent, in: batchDir) {
                    configs[i].outputDirectory = sampleSubdir
                } else {
                    // Preserve pre-refactor failure semantics: compute path and best-effort create.
                    let name = configs[i].outputDirectory.lastPathComponent
                    let sampleSubdir = batchDir.appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                    configs[i].outputDirectory = sampleSubdir
                }
            }
        }

        let sampleCount = configs.count
        let firstConfig = configs[0]
        let batchRoot = firstConfig.outputDirectory.deletingLastPathComponent()

        let sampleIDs: [String] = configs.enumerated().map { index, config in
            let outputName = config.outputDirectory.lastPathComponent
            if !outputName.isEmpty {
                return MetagenomicsSampleGrouper.sanitizeSampleId(outputName)
            }
            if let firstInput = config.inputFiles.first {
                return MetagenomicsSampleGrouper.sanitizeSampleId(
                    firstInput.deletingPathExtension().lastPathComponent
                )
            }
            return "sample_\(index + 1)"
        }

        let batchCliArgs: [String] = {
            guard let first = configs.first else { return ["--batch"] }
            var args = ["--db", first.databasePath.path]
            for c in configs {
                args += c.inputFiles.map(\.path)
            }
            return args
        }()
        let batchCliCmd = OperationCenter.buildCLICommand(
            subcommand: "conda classify",
            args: batchCliArgs
        )
        let batchProvenanceCommand = Self.classificationBatchReplayCommand(
            configurations: configs
        )
        let opID = OperationCenter.shared.start(
            title: "Classification Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting Kraken2/Bracken batch\u{2026}",
            operationType: .classification,
            cliCommand: batchCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }

            let batchMaterializeTempDir: URL
            do {
                batchMaterializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "classify-batch-mat-",
                    contextURL: firstConfig.inputFiles.first ?? firstConfig.databasePath
                )
            } catch {
                var detail = "Failed to prepare classification batch inputs: \(error.localizedDescription)"
                do {
                    _ = try Self.persistClassificationBatchSetupFailure(
                        batchRoot: batchRoot,
                        configurations: configs,
                        sampleIDs: sampleIDs,
                        command: batchProvenanceCommand,
                        startedAt: batchStartedAt,
                        completedAt: Date(),
                        errorDescription: error.localizedDescription
                    )
                } catch let provenanceError {
                    detail += "; additionally failed to persist batch provenance: \(provenanceError.localizedDescription)"
                    appDelegateLogger.error("runClassificationBatch: \(detail, privacy: .public)")
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: detail)
                        self.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()
                    }
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: batchMaterializeTempDir) }

            let pipeline = ClassificationPipeline()
            var successfulResults: [(sampleId: String, config: ClassificationConfig, result: ClassificationResult)] = []
            var failedResults: [(sampleId: String, error: String)] = []
            var failedProvenanceDirectories: [URL] = []
            var batchWasCancelled = false

            for (index, config) in configs.enumerated() {
                if Task.isCancelled {
                    break
                }

                let sampleID = sampleIDs[index]
                let samplePrefix = "Sample \(index + 1)/\(sampleCount) (\(sampleID))"

                let progressCallback: @Sendable (Double, String) -> Void = { sampleProgress, message in
                    let bounded = max(0, min(1, sampleProgress))
                    let overall = (Double(index) + bounded) / Double(sampleCount)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            viewerController.showProgress("\(samplePrefix): \(message)")
                            _ = OperationCenter.shared.update(
                                id: opID,
                                progress: overall,
                                detail: "\(samplePrefix): \(message)"
                            )
                        }
                    }
                }

                do {
                    let resolvedFiles = try await self.resolveInputFiles(
                        config.inputFiles,
                        tempDirectory: batchMaterializeTempDir,
                        progress: { message in
                            let prefixed = "\(samplePrefix): \(message)"
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(prefixed)
                                    _ = OperationCenter.shared.update(id: opID, progress: Double(index) / Double(sampleCount), detail: prefixed)
                                    OperationCenter.shared.log(id: opID, level: .info, message: prefixed)
                                }
                            }
                        }
                    )

                    var resolvedConfig = config
                    if resolvedConfig.sampleDisplayName == nil {
                        let bundleName = config.inputFiles.first?
                            .deletingPathExtension().lastPathComponent
                        resolvedConfig.sampleDisplayName = bundleName
                    }
                    if resolvedConfig.originalInputFiles == nil {
                        resolvedConfig.originalInputFiles = config.inputFiles
                    }
                    resolvedConfig.inputFiles = resolvedFiles

                    let result: ClassificationResult
                    switch resolvedConfig.goal {
                    case .classify, .extract:
                        result = try await pipeline.classify(config: resolvedConfig, progress: progressCallback)
                    case .profile:
                        result = try await pipeline.profile(config: resolvedConfig, progress: progressCallback)
                    }

                    successfulResults.append((sampleID, config, result))
                } catch {
                    failedResults.append((sampleID, error.localizedDescription))
                    failedProvenanceDirectories.append(config.outputDirectory)
                    appDelegateLogger.warning("runClassificationBatch: Sample \(sampleID, privacy: .public) failed - \(error.localizedDescription, privacy: .public)")
                }
            }

            batchWasCancelled = Task.isCancelled
            if batchWasCancelled {
                let recordedSampleIDs = Set(successfulResults.map(\.sampleId) + failedResults.map(\.sampleId))
                for (index, sampleID) in sampleIDs.enumerated() where !recordedSampleIDs.contains(sampleID) {
                    failedResults.append((sampleID, "Batch cancelled before this sample ran"))
                    failedProvenanceDirectories.append(configs[index].outputDirectory)
                }
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)

            let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
            let returnedRows = successfulResults.map {
                ClassificationBatchOutcomePolicy.row(sampleId: $0.sampleId, result: $0.result)
            }
            let failedRows = failedResults.map {
                ClassificationBatchOutcomePolicy.failedRow(sampleId: $0.sampleId, message: $0.error)
            }
            let summaryRows = returnedRows + failedRows
            let initialEvaluation = ClassificationBatchOutcomePolicy.evaluate(
                rows: summaryRows,
                sqliteWarning: nil
            )

            let sampleRecords = zip(successfulResults, returnedRows).map { item, row in
                MetagenomicsBatchSampleRecord(
                    sampleId: item.sampleId,
                    resultDirectory: appRelativePath(from: batchRoot, to: item.config.outputDirectory),
                    inputFiles: item.config.inputFiles.map(\.path),
                    isPairedEnd: item.config.isPairedEnd,
                    status: row.status,
                    message: row.message.isEmpty ? nil : row.message
                )
            }

            let manifest = ClassificationBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 2,
                    createdAt: Date(),
                    sampleCount: sampleCount
                ),
                goal: firstConfig.goal.rawValue,
                databaseName: firstConfig.databaseName,
                databaseVersion: firstConfig.databaseVersion,
                summaryTSV: summaryURL.lastPathComponent,
                samples: sampleRecords,
                completedCount: initialEvaluation.completedCount,
                degradedCount: initialEvaluation.degradedCount,
                failedCount: initialEvaluation.failedCount
            )

            do {
                try ClassificationBatchOutcomePolicy.summaryTSV(rows: summaryRows)
                    .write(to: summaryURL, atomically: true, encoding: .utf8)
                try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)
            } catch {
                var detail = "Failed to write classification batch artifacts: \(error.localizedDescription)"
                do {
                    _ = try Self.persistClassificationBatchFailureRoot(
                        batchRoot: batchRoot,
                        configurations: configs,
                        command: batchProvenanceCommand,
                        startedAt: batchStartedAt,
                        completedAt: Date(),
                        failureStage: "batch-artifact-publication",
                        errorDescription: (
                            failedResults.map { "Sample \($0.sampleId) failed: \($0.error)" }
                                + [detail]
                        ).joined(separator: "\n"),
                        additionalOutputURLs: [
                            summaryURL,
                            batchRoot.appendingPathComponent(ClassificationBatchResultManifest.filename),
                        ]
                    )
                } catch let provenanceError {
                    detail += "; additionally failed to persist root failure provenance: \(provenanceError.localizedDescription)"
                }
                appDelegateLogger.error("runClassificationBatch: \(detail, privacy: .public)")
                let terminalDetail = detail
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: terminalDetail)
                    }
                }
                return
            }

            // Build the SQLite database from the per-sample kreports before the
            // operation completes, so the batch can be opened immediately.
            // Skipped when every sample failed (no data to aggregate).
            var dbBuildErrorDescription: String?
            let successfulCountForDB = successfulResults.count
            if successfulCountForDB > 0 && !batchWasCancelled {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building Kraken2 database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building kraken2.sqlite from \(successfulCountForDB) sample(s)")
                    }
                }
                do {
                    let successfulSampleDirectories = successfulResults.map { $0.config.outputDirectory }
                    try LungfishCLIRunner.buildClassifierDatabase(
                        tool: "kraken2",
                        resultURL: batchRoot,
                        force: true,
                        sampleDirectories: successfulSampleDirectories
                    )
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runClassificationBatch: Failed to build kraken2.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            batchWasCancelled = batchWasCancelled || Task.isCancelled

            do {
                var provenanceStderr = failedResults.map {
                    "Sample \($0.sampleId) failed: \($0.error)"
                }
                if let dbBuildErrorDescription {
                    provenanceStderr.append(
                        "Kraken2 SQLite index build failed: \(dbBuildErrorDescription)"
                    )
                }
                if batchWasCancelled {
                    provenanceStderr.append("Classification batch cancelled by the user")
                }
                try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
                    batchRoot: batchRoot,
                    manifest: manifest,
                    summaryURL: summaryURL,
                    sqliteURL: batchRoot.appendingPathComponent("kraken2.sqlite"),
                    command: batchProvenanceCommand,
                    additionalStderr: provenanceStderr,
                    additionalInputURLs: configs.flatMap(\.inputFiles),
                    additionalSampleDirectories: failedProvenanceDirectories,
                    context: ClassificationBatchProvenanceContext(
                        configurations: configs,
                        startedAt: batchStartedAt,
                        completedAt: Date()
                    )
                )
            } catch {
                var detail = "Failed to write classification batch provenance: \(error.localizedDescription)"
                var failureMessages = failedResults.map {
                    "Sample \($0.sampleId) failed: \($0.error)"
                }
                if let dbBuildErrorDescription {
                    failureMessages.append(
                        "Kraken2 SQLite index build failed: \(dbBuildErrorDescription)"
                    )
                }
                if batchWasCancelled {
                    failureMessages.append("Classification batch cancelled by the user")
                }
                failureMessages.append(detail)
                do {
                    _ = try Self.persistClassificationBatchFailureRoot(
                        batchRoot: batchRoot,
                        configurations: configs,
                        command: batchProvenanceCommand,
                        startedAt: batchStartedAt,
                        completedAt: Date(),
                        failureStage: "batch-provenance-publication",
                        errorDescription: failureMessages.joined(separator: "\n"),
                        additionalOutputURLs: [
                            summaryURL,
                            batchRoot.appendingPathComponent(ClassificationBatchResultManifest.filename),
                            batchRoot.appendingPathComponent("kraken2.sqlite"),
                        ]
                    )
                } catch let fallbackError {
                    detail += "; additionally failed to persist root failure provenance: \(fallbackError.localizedDescription)"
                }
                appDelegateLogger.error("runClassificationBatch: \(detail, privacy: .public)")
                let terminalDetail = detail
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: terminalDetail)
                    }
                }
                return
            }

            if batchWasCancelled {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: "Batch cancelled")
                        self.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()
                    }
                }
                return
            }

            let finalEvaluation = ClassificationBatchOutcomePolicy.evaluate(
                rows: summaryRows,
                sqliteWarning: dbBuildErrorDescription
            )
            let capturedDBBuildError = dbBuildErrorDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    viewerController.hideProgress()

                    let successCount = successfulResults.count

                    if successCount == 0 {
                        let detail = failedResults.first?.error ?? "All samples failed"
                        _ = OperationCenter.shared.fail(id: opID, detail: detail)
                        self.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        let alert = NSAlert()
                        alert.messageText = "Classification Batch Failed"
                        alert.informativeText = detail
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                        return
                    }

                    if let dbError = capturedDBBuildError {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .warning,
                            message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                        )
                    }

                    let completionBase = "\(successCount) of \(sampleCount) samples returned valid Kraken2 classifications"
                    if finalEvaluation.requiresWarningCompletion {
                        _ = OperationCenter.shared.completeWithWarning(
                            id: opID,
                            detail: "\(completionBase); \(finalEvaluation.warningMessage)"
                        )
                    } else {
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: completionBase
                        )
                    }

                    if let firstResult = successfulResults.first?.result {
                        viewerController.displayTaxonomyResult(firstResult)
                    }

                    self.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?
                        .sidebarController.requestReloadFromFilesystem()

                    // Record analysis in source bundle manifests
                    for entry in successfulResults {
                        let bundleURL = Self.findSourceBundle(for: entry.config.originalInputFiles ?? entry.config.inputFiles)
                        if let bundleURL {
                            let outcomeMetadata = ClassificationBatchOutcomePolicy.singleResultMetadata(
                                for: entry.result
                            )
                            let manifestEntry = AnalysisManifestEntry(
                                tool: "kraken2",
                                analysisDirectoryName: Self.analysisManifestDirectoryName(
                                    for: batchRoot,
                                    projectURL: projectURL
                                ),
                                displayName: "Kraken2 Batch",
                                parameters: outcomeMetadata.analysisParameters,
                                summary: outcomeMetadata.analysisSummary,
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(manifestEntry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Runs EsViritu detection in batch mode (one run per sample).
    private func runEsVirituBatch(
        configs: [EsVirituConfig],
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        guard !configs.isEmpty else { return }

        // Redirect output to project-level Analyses/ folder when a project is open.
        var configs = configs
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let projectURL = routeContext?.projectURL
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "EsViritu batch"
        ) else { return }
        if let projectURL, let batchDir = try? AnalysesFolder.createAnalysisDirectory(tool: "esviritu", in: projectURL, isBatch: true) {
            for i in configs.indices {
                // Try the centralized helper; on failure, fall back to the old semantics.
                if let sampleSubdir = try? AnalysesFolder.batchSampleDirectory(named: configs[i].outputDirectory.lastPathComponent, in: batchDir) {
                    configs[i].outputDirectory = sampleSubdir
                } else {
                    // Preserve pre-refactor failure semantics: compute path and best-effort create.
                    let name = configs[i].outputDirectory.lastPathComponent
                    let sampleSubdir = batchDir.appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.createDirectory(at: sampleSubdir, withIntermediateDirectories: true)
                    configs[i].outputDirectory = sampleSubdir
                }
            }
        }

        let sampleCount = configs.count
        let firstConfig = configs[0]
        let batchRoot = firstConfig.outputDirectory.deletingLastPathComponent()

        let esBatchCliArgs: [String] = {
            var args = ["--input"]
            for c in configs {
                args += c.inputFiles.map(\.path)
            }
            args += ["--sample", configs.first?.sampleName ?? "batch"]
            return args
        }()
        let esBatchCliCmd = OperationCenter.buildCLICommand(subcommand: "esviritu detect", args: esBatchCliArgs)
        let esBatchCliArgv = [CLICommandIdentity.executableName, "esviritu", "detect"] + esBatchCliArgs
        let opID = OperationCenter.shared.start(
            title: "EsViritu Batch (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting EsViritu batch\u{2026}",
            operationType: .classification,
            cliCommand: esBatchCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }

            let batchMaterializeTempDir = try ProjectTempDirectory.createFromContext(
                prefix: "esviritu-batch-mat-", contextURL: firstConfig.inputFiles.first ?? firstConfig.outputDirectory)
            defer { try? FileManager.default.removeItem(at: batchMaterializeTempDir) }

            let pipeline = EsVirituPipeline()
            var successfulResults: [(sampleId: String, config: EsVirituConfig, pipelineResult: LungfishWorkflow.EsVirituResult, ioResult: LungfishIO.EsVirituResult)] = []
            var failedResults: [(sampleId: String, error: String)] = []

            for (index, config) in configs.enumerated() {
                if Task.isCancelled {
                    break
                }

                let sampleID = MetagenomicsSampleGrouper.sanitizeSampleId(config.sampleName)
                let samplePrefix = "Sample \(index + 1)/\(sampleCount) (\(sampleID))"

                do {
                    let resolvedFiles = try await self.resolveInputFiles(
                        config.inputFiles,
                        tempDirectory: batchMaterializeTempDir,
                        progress: { message in
                            let prefixed = "\(samplePrefix): \(message)"
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(prefixed)
                                    _ = OperationCenter.shared.update(id: opID, progress: Double(index) / Double(sampleCount), detail: prefixed)
                                    OperationCenter.shared.log(id: opID, level: .info, message: prefixed)
                                }
                            }
                        }
                    )

                    var resolvedConfig = config
                    resolvedConfig.inputFiles = resolvedFiles

                    let pipelineResult = try await pipeline.detect(
                        config: resolvedConfig,
                        progress: { progress, message in
                            let bounded = max(0, min(1, progress))
                            let overall = (Double(index) + bounded) / Double(sampleCount)
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress("\(samplePrefix): \(message)")
                                    _ = OperationCenter.shared.update(
                                        id: opID,
                                        progress: overall,
                                        detail: "\(samplePrefix): \(message)"
                                    )
                                    OperationCenter.shared.log(id: opID, level: .info, message: "\(samplePrefix): \(message)")
                                }
                            }
                        }
                    )

                    let detections = (try? EsVirituDetectionParser.parse(url: pipelineResult.detectionURL)) ?? []
                    let assemblies = EsVirituDetectionParser.groupByAssembly(detections)
                    let taxProfile: [ViralTaxProfile]
                    if let tpURL = pipelineResult.taxProfileURL {
                        taxProfile = (try? EsVirituTaxProfileParser.parse(url: tpURL)) ?? []
                    } else {
                        taxProfile = []
                    }
                    let coverageWindows: [ViralCoverageWindow]
                    if let cvURL = pipelineResult.coverageURL {
                        coverageWindows = (try? EsVirituCoverageParser.parse(url: cvURL)) ?? []
                    } else {
                        coverageWindows = []
                    }

                    let ioResult = LungfishIO.EsVirituResult(
                        sampleId: config.sampleName,
                        detections: detections,
                        assemblies: assemblies,
                        taxProfile: taxProfile,
                        coverageWindows: coverageWindows,
                        totalFilteredReads: detections.first?.filteredReadsInSample ?? 0,
                        detectedFamilyCount: Set(detections.compactMap(\.family)).count,
                        detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
                        runtime: pipelineResult.runtime,
                        toolVersion: pipelineResult.toolVersion
                    )

                    successfulResults.append((sampleID, config, pipelineResult, ioResult))
                } catch {
                    failedResults.append((sampleID, error.localizedDescription))
                    appDelegateLogger.warning("runEsVirituBatch: Sample \(sampleID, privacy: .public) failed - \(error.localizedDescription, privacy: .public)")
                }
            }

            let fm = FileManager.default
            try? fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)

            let summaryURL = batchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
            var summaryLines: [String] = []
            summaryLines.append("sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror")

            for entry in successfulResults {
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "ok",
                    String(entry.pipelineResult.virusCount),
                    String(entry.ioResult.detectedFamilyCount),
                    String(entry.ioResult.detectedSpeciesCount),
                    "",
                ].joined(separator: "\t"))
            }

            for entry in failedResults {
                summaryLines.append([
                    appTSVField(entry.sampleId),
                    "failed",
                    "",
                    "",
                    "",
                    appTSVField(entry.error),
                ].joined(separator: "\t"))
            }

            do {
                try summaryLines.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
            } catch {
                appDelegateLogger.warning("runEsVirituBatch: Failed to write summary TSV - \(error.localizedDescription, privacy: .public)")
            }

            let sampleRecords = successfulResults.map { item in
                MetagenomicsBatchSampleRecord(
                    sampleId: item.sampleId,
                    resultDirectory: appRelativePath(from: batchRoot, to: item.config.outputDirectory),
                    inputFiles: item.config.inputFiles.map(\.path),
                    isPairedEnd: item.config.isPairedEnd
                )
            }

            let manifest = EsVirituBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 1,
                    createdAt: Date(),
                    sampleCount: sampleCount
                ),
                summaryTSV: summaryURL.lastPathComponent,
                samples: sampleRecords
            )

            do {
                try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: batchRoot)
            } catch {
                appDelegateLogger.warning("runEsVirituBatch: Failed to save batch manifest - \(error.localizedDescription, privacy: .public)")
            }

            // Build the SQLite database from the per-sample outputs before the
            // operation completes, so the batch can be opened immediately.
            // Skipped when every sample failed (no data to aggregate).
            var dbBuildErrorDescription: String?
            let successfulCountForDB = successfulResults.count
            if successfulCountForDB > 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building EsViritu database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building esviritu.sqlite from \(successfulCountForDB) sample(s)")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "esviritu", resultURL: batchRoot, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runEsVirituBatch: Failed to build esviritu.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            if !successfulResults.isEmpty {
                try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
                    batchRoot: batchRoot,
                    manifest: manifest,
                    summaryURL: summaryURL,
                    sqliteURL: batchRoot.appendingPathComponent("esviritu.sqlite"),
                    command: esBatchCliArgv
                )
            }

            let capturedDBBuildError = dbBuildErrorDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    viewerController.hideProgress()

                    if Task.isCancelled {
                        _ = OperationCenter.shared.fail(id: opID, detail: "Batch cancelled")
                        return
                    }

                    let successCount = successfulResults.count
                    let failureCount = failedResults.count

                    if successCount == 0 {
                        let detail = failedResults.first?.error ?? "All samples failed"
                        _ = OperationCenter.shared.fail(id: opID, detail: detail)

                        let alert = NSAlert()
                        alert.messageText = "EsViritu Batch Failed"
                        alert.informativeText = detail
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                        return
                    }

                    if let dbError = capturedDBBuildError {
                        OperationCenter.shared.log(
                            id: opID,
                            level: .warning,
                            message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                        )
                    }

                    if failureCount == 0 {
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) of \(sampleCount) samples completed"
                        )
                    } else {
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: "\(successCount) completed, \(failureCount) failed"
                        )
                    }

                    // Reload sidebar so the new batch result appears.
                    // User clicks the new result to view it (batch-only display path).
                    self.targetMainWindowController(routeContext: routeContext)?
                        .mainSplitViewController?
                        .sidebarController.requestReloadFromFilesystem()

                    // Record analysis in source bundle manifests
                    for entry in successfulResults {
                        let bundleURL = Self.findSourceBundle(for: entry.config.inputFiles)
                        if let bundleURL {
                            let manifestEntry = AnalysisManifestEntry(
                                tool: "esviritu",
                                analysisDirectoryName: Self.analysisManifestDirectoryName(
                                    for: batchRoot,
                                    projectURL: projectURL
                                ),
                                displayName: "EsViritu Batch",
                                parameters: entry.config.summaryParameters(),
                                summary: "\(entry.ioResult.detections.count) viruses in \(entry.ioResult.detectedFamilyCount) families",
                                status: .completed
                            )
                            do { try AnalysisManifestStore.recordAnalysis(manifestEntry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Runs the TaxTriage Nextflow pipeline.
    ///
    /// Registers the operation with ``OperationCenter`` and displays the
    /// ``TaxTriageResultViewController`` when complete.
    internal func runTaxTriage(
        config: TaxTriageConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        // Redirect output to project-level Analyses/ folder when a project is open.
        // TaxTriage pipeline writes its own sample-subdirectory layout, so we just
        // create the batch-style parent directory and point outputDirectory at it.
        var config = config
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "TaxTriage"
        ) else { return }
        if let projectURL = routeContext?.projectURL {
            if let batchDir = try? AnalysesFolder.createAnalysisDirectory(
                tool: "taxtriage", in: projectURL, isBatch: true
            ) {
                config.outputDirectory = batchDir
            }
        }

        let sampleCount = config.samples.count
        let ttCliCmd: String = {
            var args = ["--input"]
            for sample in config.samples {
                args.append(sample.fastq1.path); if let f2 = sample.fastq2 { args.append(f2.path) }
            }
            return OperationCenter.buildCLICommand(subcommand: "taxtriage", args: args)
        }()
        let opID = OperationCenter.shared.start(
            title: "TaxTriage (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            detail: "Starting TaxTriage pipeline\u{2026}",
            operationType: .classification,
            cliCommand: ttCliCmd,
            routeContext: routeContext
        )

        let task = Task.detached { [weak self] in
            do {
                // Materialize virtual FASTQs for each sample before running TaxTriage
                let materializeTempDir = try ProjectTempDirectory.createFromContext(
                    prefix: "taxtriage-", contextURL: config.samples.first?.fastq1 ?? config.outputDirectory)
                defer { try? FileManager.default.removeItem(at: materializeTempDir) }

                var resolvedConfig = config
                for (i, sample) in resolvedConfig.samples.enumerated() {
                    let allFiles = [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])
                    let resolved = try await self?.resolveInputFiles(
                        allFiles,
                        tempDirectory: materializeTempDir,
                        progress: { message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    viewerController.showProgress(message)
                                    _ = OperationCenter.shared.update(id: opID, progress: 0, detail: message)
                                    OperationCenter.shared.log(id: opID, level: .info, message: message)
                                }
                            }
                        }
                    ) ?? allFiles
                    resolvedConfig.samples[i].fastq1 = resolved[0]
                    if resolved.count > 1 {
                        resolvedConfig.samples[i].fastq2 = resolved[1]
                    }
                }

                let runner = TaxTriageSerialBatchRunner()
                let result = try await runner.run(
                    config: resolvedConfig,
                    progress: { progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                viewerController.showProgress(message)
                                _ = OperationCenter.shared.update(
                                    id: opID,
                                    progress: max(0, min(1, progress)),
                                    detail: message
                                )
                                OperationCenter.shared.log(id: opID, level: .info, message: message)
                            }
                        }
                    }
                )

                // Build the SQLite database from the Nextflow outputs before the
                // operation completes, so the batch can be opened immediately.
                var dbBuildErrorDescription: String?
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.update(id: opID, progress: 0.95, detail: "Building TaxTriage database\u{2026}")
                        OperationCenter.shared.log(id: opID, level: .info, message: "Building taxtriage.sqlite from TaxTriage outputs")
                    }
                }
                do {
                    try LungfishCLIRunner.buildClassifierDatabase(tool: "taxtriage", resultURL: result.outputDirectory, force: true)
                } catch {
                    dbBuildErrorDescription = error.localizedDescription
                    appDelegateLogger.warning(
                        "runTaxTriage: Failed to build taxtriage.sqlite - \(error.localizedDescription, privacy: .public)"
                    )
                }

                _ = try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(
                    resultDirectory: result.outputDirectory
                )

                let capturedResult = result
                let capturedConfig = config
                let capturedDBBuildError = dbBuildErrorDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        if let dbError = capturedDBBuildError {
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "Database build failed: \(dbError) — batch will rebuild lazily on open"
                            )
                        }
                        if capturedResult.hasIgnoredFailures {
                            let sampleIDs = Array(Set(capturedResult.ignoredFailures.compactMap(\.sampleID))).sorted()
                            let sampleSummary: String
                            if sampleIDs.isEmpty {
                                sampleSummary = "\(capturedResult.ignoredFailures.count) ignored task failures"
                            } else {
                                let preview = sampleIDs.prefix(5).joined(separator: ", ")
                                let suffix = sampleIDs.count > 5 ? ", +\(sampleIDs.count - 5) more" : ""
                                sampleSummary = "\(capturedResult.ignoredFailures.count) ignored sample failures across \(sampleIDs.count) samples (\(preview)\(suffix))"
                            }
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: sampleSummary
                            )
                        }
                        if capturedResult.hasSampleFailures {
                            let preview = capturedResult.sampleFailures
                                .prefix(5)
                                .map { failure in
                                    "\(failure.sampleID): \(failure.errorDescription)"
                                }
                                .joined(separator: "; ")
                            let suffix = capturedResult.sampleFailures.count > 5
                                ? "; +\(capturedResult.sampleFailures.count - 5) more"
                                : ""
                            OperationCenter.shared.log(
                                id: opID,
                                level: .warning,
                                message: "\(capturedResult.sampleFailures.count) TaxTriage samples failed (\(preview)\(suffix))"
                            )
                        }
                        let completionDetail: String
                        var warningSummaries: [String] = []
                        if capturedResult.hasIgnoredFailures {
                            warningSummaries.append("\(capturedResult.ignoredFailures.count) ignored task failures")
                        }
                        if capturedResult.hasSampleFailures {
                            warningSummaries.append("\(capturedResult.sampleFailures.count) failed samples")
                        }
                        if !warningSummaries.isEmpty {
                            completionDetail = "\(capturedResult.reportFiles.count) reports, \(warningSummaries.joined(separator: ", "))"
                        } else {
                            completionDetail = capturedResult.summary
                        }
                        _ = OperationCenter.shared.complete(
                            id: opID,
                            detail: completionDetail
                        )
                        // Write cross-reference sidecars into each source bundle so
                        // the sidebar discovers TaxTriage results under all contributors.
                        Self.writeTaxTriageCrossRefSidecars(result: capturedResult, config: capturedConfig)

                        // Record in batch run history log
                        BatchRunHistory.recordRun(result: capturedResult, config: capturedConfig)

                        // Reload sidebar so the new result bundle appears
                        AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                            .mainSplitViewController?
                            .sidebarController.requestReloadFromFilesystem()

                        // Record analysis in source bundle manifests
                        for sample in capturedConfig.samples {
                            if let bundleURL = Self.findSourceBundle(for: [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])) {
                                let entry = AnalysisManifestEntry(
                                    tool: "taxtriage",
                                    analysisDirectoryName: Self.analysisManifestDirectoryName(
                                        for: capturedConfig.outputDirectory,
                                        projectURL: routeContext?.projectURL
                                    ),
                                    displayName: "TaxTriage Classification",
                                    parameters: capturedConfig.summaryParameters(),
                                    summary: capturedResult.summary,
                                    status: .completed
                                )
                                do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                            }
                        }
                    }
                }
            } catch {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        viewerController.hideProgress()
                        _ = OperationCenter.shared.fail(id: opID, detail: errorDesc)

                        let alert = NSAlert()
                        alert.messageText = "TaxTriage Failed"
                        alert.informativeText = errorDesc
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        if let window = viewerController.view.window {
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
    }

    /// Writes TaxTriage cross-reference sidecars into each source bundle directory.
    ///
    /// After a multi-sample TaxTriage batch run, each contributing source bundle
    /// gets a `taxtriage-ref-{runId}.json` so the sidebar can discover the result
    /// under every bundle, not just the one containing the output directory.
    private static func writeTaxTriageCrossRefSidecars(result: TaxTriageResult, config: TaxTriageConfig) {
        guard let sourceBundleURLs = result.sourceBundleURLs, sourceBundleURLs.count > 1 else { return }

        let runId = result.outputDirectory.lastPathComponent
        let now = Date()

        for (index, bundleURL) in sourceBundleURLs.enumerated() {
            // Determine which sample(s) came from this bundle
            let sampleId: String
            if index < config.samples.count {
                sampleId = config.samples[index].sampleId
            } else {
                sampleId = "sample-\(index)"
            }

            let ref = TaxTriageCrossRef(
                resultDirectory: result.outputDirectory.path,
                runId: runId,
                sampleId: sampleId,
                createdAt: now,
                batchSampleCount: config.samples.count
            )

            do {
                try MetagenomicsBatchResultStore.saveTaxTriageRef(ref, to: bundleURL)
                debugLog("Wrote TaxTriage cross-ref sidecar to \(bundleURL.lastPathComponent) for sample \(sampleId)")
            } catch {
                debugLog("Failed to write TaxTriage cross-ref to \(bundleURL.lastPathComponent): \(error)")
            }
        }
    }

    /// Shows the database browser for the specified source.
    internal func showDatabaseBrowser(source: DatabaseSource, sender: Any? = nil) {
        guard let controller = activeMainWindowController(sender: sender),
              let window = controller.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)
        browserController.routeContext = currentOperationRouteContext(for: controller)

        // Dismiss the sheet immediately when a download is kicked off.
        // The download continues in background via DownloadCenter. Bundle
        // import is handled by DownloadCenter.onBundleReady (set in
        // applicationDidFinishLaunching), eliminating the fragile callback
        // chain through the sheet controller.
        browserController.onDownloadStarted = {
            debugLog("onDownloadStarted: Dismissing sheet immediately")
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }

        // Present as sheet
        let browserWindow = NSWindow(contentViewController: browserController)
        browserWindow.title = "Search Online Databases"

        window.beginSheet(browserWindow) { _ in
            debugLog("Sheet dismissed callback executing")
        }
    }

    /// Handles multiple downloaded files with better progress tracking.
    ///
    /// This method processes multiple downloaded files sequentially, showing overall progress
    /// in the activity indicator and refreshing the sidebar once at the end.
    ///
    /// - Parameter tempFileURLs: Array of URLs of downloaded files in the temp directory
    internal func handleMultipleDownloadsSync(_ tempFileURLs: [URL], routeContext: OperationRouteContext? = nil) {
        guard !tempFileURLs.isEmpty else { return }

        debugLog("handleMultipleDownloadsSync: Starting with \(tempFileURLs.count) files")

        // Get UI controllers
        let targetController = targetMainWindowController(routeContext: routeContext)
        let activityIndicator = targetController?.mainSplitViewController?.activityIndicator
        let viewerController = targetController?.mainSplitViewController?.viewerController
        let sidebarController = targetController?.mainSplitViewController?.sidebarController

        let routedProjectURL = routeContext?.projectURL ?? targetController?.projectSession.projectURL
        guard canWriteProjectOutputs(
            projectURL: routedProjectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Downloaded imports",
            presentingWindow: targetController?.window
        ) else {
            return
        }

        let totalCount = tempFileURLs.count
        activityIndicator?.show(message: "Importing \(totalCount) file\(totalCount == 1 ? "" : "s")...", style: .indeterminate)

        // Determine destination directory
        let destinationDirectory: URL
        if let projectURL = routedProjectURL {
            destinationDirectory = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            destinationDirectory = workingURL.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create destination directory
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("handleMultipleDownloadsSync: Failed to create directory - \(error)")
            activityIndicator?.hide()
            return
        }

        var copiedURLs: [URL] = []
        var packagedFASTQPayloads: [String: URL] = [:]

        // Copy all files first
        for (index, tempURL) in tempFileURLs.enumerated() {
            // Keep bundles in place only when they already live in a visible
            // project folder. Project-local staging under `.tmp/` must still be
            // copied into Downloads so the sidebar can surface it.
            let alreadyInProject = DownloadImportRouting.shouldPreserveInPlace(
                downloadedURL: tempURL,
                projectURL: routedProjectURL,
                workingDirectoryURL: workingDirectoryURL
            )

            if alreadyInProject {
                debugLog("handleMultipleDownloadsSync: \(tempURL.lastPathComponent) already in project, skipping copy")
                copiedURLs.append(tempURL)
                continue
            }

            let originalFilename = tempURL.lastPathComponent

            // Build the full compound extension (e.g. "fastq.gz") and true base name
            var strippedURL = tempURL
            var extensionParts: [String] = []
            while !strippedURL.pathExtension.isEmpty {
                extensionParts.insert(strippedURL.pathExtension, at: 0)
                strippedURL = strippedURL.deletingPathExtension()
            }
            let fileExtension = extensionParts.joined(separator: ".")
            var baseName = strippedURL.lastPathComponent

            // Strip the UID suffix from batch downloads (format: "accession_uid.ext" -> "accession.ext")
            // UIDs are numeric, so we look for _digits at the end of the basename.
            // Skip for .lungfishref bundles — their filenames are already clean accessions
            // and accession numbers like NC_045512 contain underscore+digits that would be
            // incorrectly stripped.
            if !extensionParts.contains("lungfishref"),
               !extensionParts.contains(FASTQBundle.directoryExtension),
               !FASTQBundle.isFASTQFileURL(tempURL),
               let underscoreRange = baseName.range(of: "_", options: .backwards) {
                let potentialUID = String(baseName[underscoreRange.upperBound...])
                // Check if everything after the underscore is digits (a UID)
                if !potentialUID.isEmpty && potentialUID.allSatisfy({ $0.isNumber }) {
                    baseName = String(baseName[..<underscoreRange.lowerBound])
                    debugLog("handleMultipleDownloadsSync: Stripped UID from filename, using base: \(baseName)")
                }
            }

            let cleanFilename = "\(baseName).\(fileExtension)"
            activityIndicator?.updateMessage("Copying \(cleanFilename) (\(index + 1)/\(totalCount))...")

            // FASTQ imports are stored as package bundles so the FASTQ payload,
            // index, and metadata always travel together.
            if FASTQBundle.isFASTQFileURL(tempURL) {
                var bundleURL = destinationDirectory.appendingPathComponent(
                    "\(baseName).\(FASTQBundle.directoryExtension)",
                    isDirectory: true
                )
                var bundleCounter = 1
                while FileManager.default.fileExists(atPath: bundleURL.path) {
                    bundleURL = destinationDirectory.appendingPathComponent(
                        "\(baseName)_\(bundleCounter).\(FASTQBundle.directoryExtension)",
                        isDirectory: true
                    )
                    bundleCounter += 1
                }

                do {
                    try FileManager.default.createDirectory(
                        at: bundleURL,
                        withIntermediateDirectories: true
                    )

                    let bundledFASTQURL = bundleURL.appendingPathComponent(cleanFilename)
                    try FileManager.default.copyItem(at: tempURL, to: bundledFASTQURL)
                    debugLog("handleMultipleDownloadsSync: Packaged \(originalFilename) into \(bundleURL.path)")
                    rehydrateCopiedProvenance(from: tempURL, to: bundledFASTQURL)

                    let sourceSidecar = FASTQMetadataStore.metadataURL(for: tempURL)
                    if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                        let destSidecar = FASTQMetadataStore.metadataURL(for: bundledFASTQURL)
                        try? FileManager.default.copyItem(at: sourceSidecar, to: destSidecar)
                        try? FileManager.default.removeItem(at: sourceSidecar)
                    }

                    let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                    if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                        let destFASTQIndex = bundledFASTQURL.appendingPathExtension("fai")
                        try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                        try? FileManager.default.removeItem(at: sourceFASTQIndex)
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                    copiedURLs.append(bundleURL)
                    packagedFASTQPayloads[DownloadImportRouting.canonicalPath(for: bundleURL)] = bundledFASTQURL
                } catch {
                    debugLog("handleMultipleDownloadsSync: Failed to package FASTQ \(originalFilename) - \(error)")
                }
                continue
            }

            // Generate unique filename if needed
            var destinationURL = destinationDirectory.appendingPathComponent(cleanFilename)
            var counter = 1

            while FileManager.default.fileExists(atPath: destinationURL.path) {
                let newFilename = "\(baseName)_\(counter).\(fileExtension)"
                destinationURL = destinationDirectory.appendingPathComponent(newFilename)
                counter += 1
            }

            // Copy file
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                debugLog("handleMultipleDownloadsSync: Copied \(originalFilename) to \(destinationURL.path)")
                rehydrateCopiedProvenance(from: tempURL, to: destinationURL)

                // Copy metadata sidecar if it exists (e.g. SRA/ENA download metadata)
                let sidecarURL = FASTQMetadataStore.metadataURL(for: tempURL)
                if FileManager.default.fileExists(atPath: sidecarURL.path) {
                    let destSidecar = FASTQMetadataStore.metadataURL(for: destinationURL)
                    try? FileManager.default.copyItem(at: sidecarURL, to: destSidecar)
                    try? FileManager.default.removeItem(at: sidecarURL)
                }

                // Copy FASTQ index sidecar when present (e.g. pre-import fqidx output).
                let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                    let destFASTQIndex = destinationURL.appendingPathExtension("fai")
                    try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                    try? FileManager.default.removeItem(at: sourceFASTQIndex)
                }

                try? FileManager.default.removeItem(at: tempURL)
                copiedURLs.append(destinationURL)
            } catch {
                debugLog("handleMultipleDownloadsSync: Failed to copy \(originalFilename) - \(error)")
            }
        }

        // Trigger FASTQ ingestion only for raw FASTQ files this method packaged into
        // new bundles. Existing `.lungfishfastq` bundles are atomic imports; resolving
        // their "primary" FASTQ can point at a representative chunk and mutate/copy
        // only part of an ONT multi-file bundle.
        for url in copiedURLs {
            if let fastqURL = DownloadImportRouting.postCopyFASTQIngestionTarget(
                importedURL: url,
                packagedFASTQPayloads: packagedFASTQPayloads
            ) {
                let existingMeta = FASTQMetadataStore.load(for: fastqURL)
                FASTQIngestionService.ingestIfNeeded(
                    url: fastqURL,
                    existingMetadata: existingMeta,
                    routeContext: routeContext
                )
            }
        }

        // Now load the first file to display (load others in background)
        if let firstURL = copiedURLs.first {
            if firstURL.pathExtension.lowercased() == "lungfishref" ||
                FASTQBundle.resolvePrimaryFASTQURL(for: firstURL) != nil {
                activityIndicator?.hide()
                refreshSidebarAndSelectImportedURL(firstURL, in: targetController)
                debugLog("handleMultipleDownloadsSync: Imported \(copiedURLs.count) bundled item(s)")
                return
            }

            activityIndicator?.updateMessage("Loading \(firstURL.lastPathComponent)...")
            let importedFileCount = copiedURLs.count

            loadFileInBackground(at: firstURL) { result in
                scheduleOnMainRunLoop { [weak activityIndicator, weak viewerController, weak sidebarController] in
                    if result.error == nil {
                        // Create and display the first document
                        let document = LoadedDocument(url: result.url, type: result.type)
                        document.sequences = result.sequences
                        document.annotations = result.annotations
                        DocumentManager.shared.registerDocument(document)
                        viewerController?.displayDocument(document)
                        debugLog("handleMultipleDownloadsSync: Displayed first document '\(document.name)'")
                    }

                    activityIndicator?.hide()

                    // Refresh sidebar to show all new files
                    sidebarController?.reloadFromFilesystem()

                    // Select the first downloaded file in the sidebar to highlight what's being viewed
                    if result.error == nil {
                        sidebarController?.selectItem(forURL: result.url)
                        self.requestInspectorDocumentModeAfterDownload(in: targetController)
                    }

                    debugLog("handleMultipleDownloadsSync: Completed importing \(importedFileCount) files")
                }
            }
        } else {
            activityIndicator?.hide()
            sidebarController?.requestReloadFromFilesystem()
        }
    }

    internal func rehydrateCopiedProvenance(from sourceURL: URL, to destinationURL: URL) {
        if GUIImportedProvenanceRehydrator.finalBundleRoot(containing: destinationURL) != nil {
            do {
                try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: sourceURL, to: destinationURL)
            } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
                    debugLog("rehydrateCopiedProvenance: \(message)")
                }
            } catch ProvenanceRehydrationError.missingSourceProvenance {
                debugLog("rehydrateCopiedProvenance: no source provenance for \(sourceURL.path)")
            } catch {
                debugLog("rehydrateCopiedProvenance: failed schema-aware rehydration for \(sourceURL.path): \(error)")
            }
            return
        }

        ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
            debugLog("rehydrateCopiedProvenance: \(message)")
        }
    }
}
