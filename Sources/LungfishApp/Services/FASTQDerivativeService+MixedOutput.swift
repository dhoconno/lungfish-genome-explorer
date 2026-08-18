// FASTQDerivativeService+MixedOutput.swift - Mixed output derivatives
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Mixed Output Derivatives

    /// Runs vsearch orient and creates an orient-map derivative bundle.
    ///
    /// The orient-map derivative stores a TSV mapping read IDs to orientation (+/-)
    /// and a preview FASTQ of the first 1000 oriented reads. The full oriented FASTQ
    /// is materialized on demand using seqkit.
    func createOrientDerivative(
        sourceFASTQ: URL,
        sourceProvenanceInputRecord: FileRecord,
        sourceBridgeFASTQ: URL?,
        sourceBundleURL: URL,
        resolvedRootBundleURL: URL,
        rootFASTQFilename: String,
        sourceSequenceFormat: SequenceFormat,
        pairingMode: IngestionMetadata.PairingMode?,
        baseLineage: [FASTQDerivativeOperation],
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool,
        extraArguments: [String],
        batchOperationID: UUID?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        progress?("Running vsearch orient...")

        let pipeline = OrientPipeline(runner: runner)
        let vsearchInputRecord = sourceBridgeFASTQ == nil
            ? sourceProvenanceInputRecord
            : ProvenanceRecorder.fileRecord(url: sourceFASTQ, format: .fastq, role: .input)
        let orientPathReplacements = sourceBridgeFASTQ == nil
            ? [sourceFASTQ.path: sourceProvenanceInputRecord.path]
            : [:]
        let config = OrientConfig(
            inputURL: sourceFASTQ,
            referenceURL: referenceURL,
            wordLength: wordLength,
            dbMask: dbMask,
            qMask: dbMask,
            saveUnoriented: saveUnoriented,
            extraArguments: extraArguments
        )

        let result = try await pipeline.run(
            config: config,
            provenanceContext: OrientProvenanceContext(
                options: orientProvenanceOptions(
                    sourceInputRecord: sourceProvenanceInputRecord,
                    referenceURL: referenceURL,
                    wordLength: wordLength,
                    dbMask: dbMask,
                    saveUnoriented: saveUnoriented,
                    extraArguments: extraArguments
                ),
                inputFileRecords: [vsearchInputRecord],
                pathReplacements: orientPathReplacements
            )
        ) { fraction, msg in
            progress?(msg)
        }

        progress?("Creating orient derivative bundle...")

        // Create the derivative bundle inside the source bundle's derivatives/ directory.
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        var createdOrientBundles: [URL] = []
        var shouldCleanCreatedOrientBundlesOnFailure = true
        defer {
            if shouldCleanCreatedOrientBundlesOnFailure {
                for url in createdOrientBundles {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let initialBundleURL = derivDir.appendingPathComponent(
            "orient-\(shortID).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        let bundleURL = uniqueDirectoryURL(startingAt: initialBundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        createdOrientBundles.append(bundleURL)
        OperationMarker.markInProgress(bundleURL, detail: "Creating derivative FASTQ\u{2026}")
        defer { OperationMarker.clearInProgress(bundleURL) }

        // Create the orient-map TSV from vsearch tabbed output
        let orientMapFilename = "orient-map.tsv"
        let orientMapURL = bundleURL.appendingPathComponent(orientMapFilename)
        let (fwdCount, rcCount) = try pipeline.createOrientMap(
            from: result.tabbedOutput,
            to: orientMapURL
        )

        // Create a preview FASTQ (first 1000 oriented reads)
        let previewFilename = "preview.fastq"
        let previewURL = bundleURL.appendingPathComponent(previewFilename)
        do {
            try await writeOrientedPreviewFASTQ(
                fromSourceFASTQ: sourceFASTQ,
                orientMapURL: orientMapURL,
                outputFASTQ: previewURL
            )
        } catch {
            derivativeLogger.warning("Failed to create orient preview: \(error.localizedDescription)")
        }

        // Compute statistics on the oriented output
        let stats: FASTQDatasetStatistics?
        if sourceSequenceFormat == .fasta {
            stats = try await SyntheticFASTQBridge.placeholderStatistics(fromFASTQ: result.orientedFASTQ)
        } else {
            let statsResult = try await runner.run(
                .seqkit,
                arguments: ["stats", "--tabular", result.orientedFASTQ.path],
                timeout: 120
            )
            stats = parseFASTQStats(statsResult.stdout)
        }

        let orientIntermediateDirectory = try provenanceIntermediateDirectory(in: bundleURL)
        let storedOrientedFASTQ = orientIntermediateDirectory.appendingPathComponent("vsearch-oriented.fastq")
        let storedTabbedOutput = orientIntermediateDirectory.appendingPathComponent("vsearch-orient-results.tsv")
        try copyReplacingItem(at: result.orientedFASTQ, to: storedOrientedFASTQ)
        try copyReplacingItem(at: result.tabbedOutput, to: storedTabbedOutput)
        var orientProvenancePathMap = [
            result.orientedFASTQ.path: storedOrientedFASTQ.path,
            result.tabbedOutput.path: storedTabbedOutput.path,
        ]
        if let unorientedFASTQ = result.unorientedFASTQ,
           FileManager.default.fileExists(atPath: unorientedFASTQ.path) {
            let storedUnorientedFASTQ = orientIntermediateDirectory.appendingPathComponent("vsearch-unoriented.fastq")
            try copyReplacingItem(at: unorientedFASTQ, to: storedUnorientedFASTQ)
            orientProvenancePathMap[unorientedFASTQ.path] = storedUnorientedFASTQ.path
        }
        var bridgeStep: ProvenanceStep?
        if let sourceBridgeFASTQ {
            let storedBridgeFASTQ = orientIntermediateDirectory.appendingPathComponent("bridged-source.fastq")
            try copyReplacingItem(at: sourceBridgeFASTQ, to: storedBridgeFASTQ)
            orientProvenancePathMap[sourceBridgeFASTQ.path] = storedBridgeFASTQ.path
            let bridgeOutput = try ProvenanceFileDescriptor.file(url: storedBridgeFASTQ, format: .fastq, role: .output)
            bridgeStep = appProvenanceStep(
                argv: [
                    "lungfish-app-action:fastq-synthetic-fastq-from-fasta",
                    "--source-fasta", sourceProvenanceInputRecord.path,
                    "--output-fastq", storedBridgeFASTQ.path,
                ],
                inputs: [ProvenanceFileDescriptor(fileRecord: sourceProvenanceInputRecord)],
                outputs: [bridgeOutput],
                dependsOn: []
            )
        }
        var unorientedBundleURL: URL?
        var unorientedDest: URL?
        var unorientedPayload: FASTQDerivativePayload?
        var unorientedStats: FASTQDatasetStatistics?

        // Optionally create unoriented reads derivative
        if saveUnoriented, let unorientedFASTQ = result.unorientedFASTQ,
           FileManager.default.fileExists(atPath: unorientedFASTQ.path) {
            let unorientedShortID = UUID().uuidString.prefix(8).lowercased()
            let unorientedBaseName = "unoriented-\(unorientedShortID).\(FASTQBundle.directoryExtension)"
            let initialUnorientedBundleURL = derivDir.appendingPathComponent(unorientedBaseName, isDirectory: true)
            let createdUnorientedBundleURL = uniqueDirectoryURL(startingAt: initialUnorientedBundleURL)
            unorientedBundleURL = createdUnorientedBundleURL
            try FileManager.default.createDirectory(at: createdUnorientedBundleURL, withIntermediateDirectories: true)
            createdOrientBundles.append(createdUnorientedBundleURL)
            OperationMarker.markInProgress(createdUnorientedBundleURL, detail: "Creating derivative FASTQ\u{2026}")
            defer { OperationMarker.clearInProgress(createdUnorientedBundleURL) }

            if sourceSequenceFormat == .fasta {
                let fastaDest = createdUnorientedBundleURL.appendingPathComponent("unoriented.fasta")
                try await SyntheticFASTQBridge.convertFASTQToFASTA(
                    inputURL: unorientedFASTQ,
                    outputURL: fastaDest
                )
                unorientedDest = fastaDest
                unorientedPayload = .fullFASTA(fastaFilename: fastaDest.lastPathComponent)
                unorientedStats = try await SyntheticFASTQBridge.placeholderStatistics(fromFASTQ: unorientedFASTQ)
            } else {
                let fastqDest = createdUnorientedBundleURL.appendingPathComponent("unoriented.fastq")
                try FileManager.default.copyItem(at: unorientedFASTQ, to: fastqDest)
                unorientedDest = fastqDest
                unorientedPayload = .full(fastqFilename: fastqDest.lastPathComponent)
                unorientedStats = parseFASTQStats(
                    (try? await runner.run(.seqkit, arguments: ["stats", "--tabular", fastqDest.path], timeout: 120))?.stdout ?? ""
                )
            }
        }

        var orientCommandParts: [String] = [
            "lungfish-app-workflow:fastq-orient-derivative",
            "--source-bundle", sourceBundleURL.path,
            "--reference", referenceURL.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", dbMask,
            "--threads", "0",
            "--orient-map", orientMapURL.path,
            "--preview", previewURL.path,
        ]
        if let unorientedDest {
            orientCommandParts += ["--save-unoriented", unorientedDest.path]
        }
        if !extraArguments.isEmpty {
            orientCommandParts += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        let orientCommand = orientCommandParts.map(shellEscape).joined(separator: " ")

        let operation = FASTQDerivativeOperation(
            kind: .orient,
            orientReferencePath: referenceURL.lastPathComponent,
            orientWordLength: wordLength,
            orientDbMask: dbMask,
            orientSaveUnoriented: saveUnoriented,
            orientRCCount: rcCount,
            orientUnmatchedCount: result.unmatchedCount,
            toolUsed: "Lungfish App",
            toolCommand: orientCommand
        )

        var lineage = baseLineage
        lineage.append(operation)

        let orientParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: bundleURL)
            ?? relativePathFromBundle(bundleURL, to: sourceBundleURL)
        let orientRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: bundleURL)
            ?? relativePathFromBundle(bundleURL, to: resolvedRootBundleURL)

        let manifest = FASTQDerivedBundleManifest(
            name: "Oriented",
            parentBundleRelativePath: orientParentPath,
            rootBundleRelativePath: orientRootPath,
            rootFASTQFilename: rootFASTQFilename,
            payload: .orientMap(orientMapFilename: orientMapFilename, previewFilename: previewFilename),
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats ?? .placeholder(readCount: fwdCount + rcCount, baseCount: 0),
            pairingMode: pairingMode,
            batchOperationID: batchOperationID,
            sequenceFormat: sourceSequenceFormat
        )

        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        if let unorientedBundleURL, let unorientedPayload {
            let unorientedOp = FASTQDerivativeOperation(
                kind: .orient,
                orientReferencePath: referenceURL.lastPathComponent,
                orientSaveUnoriented: true,
                orientUnmatchedCount: result.unmatchedCount,
                toolUsed: "Lungfish App",
                toolCommand: orientCommand
            )

            var unorientedLineage = baseLineage
            unorientedLineage.append(unorientedOp)

            let unorientedParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: unorientedBundleURL)
                ?? relativePathFromBundle(unorientedBundleURL, to: sourceBundleURL)
            let unorientedRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: unorientedBundleURL)
                ?? relativePathFromBundle(unorientedBundleURL, to: resolvedRootBundleURL)

            let unorientedManifest = FASTQDerivedBundleManifest(
                name: "Unoriented",
                parentBundleRelativePath: unorientedParentPath,
                rootBundleRelativePath: unorientedRootPath,
                rootFASTQFilename: rootFASTQFilename,
                payload: unorientedPayload,
                lineage: unorientedLineage,
                operation: unorientedOp,
                cachedStatistics: unorientedStats ?? .placeholder(readCount: result.unmatchedCount, baseCount: 0),
                pairingMode: pairingMode,
                batchOperationID: batchOperationID,
                sequenceFormat: sourceSequenceFormat
            )

            try FASTQBundle.saveDerivedManifest(unorientedManifest, in: unorientedBundleURL)
        }

        let orientedBaseProvenance = try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: result.orientedFASTQ.deletingLastPathComponent(),
            finalDirectory: bundleURL,
            pathMap: orientProvenancePathMap,
            argumentPathMap: orientProvenancePathMap,
            preserveOriginMetadata: false
        )
        try writeOrientDerivativeProvenance(
            baseEnvelope: orientedBaseProvenance,
            finalDirectory: bundleURL,
            argv: orientCommandParts,
            sourceInputRecord: sourceProvenanceInputRecord,
            bridgeStep: bridgeStep,
            storedTabbedOutputPath: storedTabbedOutput.path,
            orientMapURL: orientMapURL,
            previewURL: previewURL
        )

        if let unorientedBundleURL, let unorientedFASTQ = result.unorientedFASTQ, let unorientedDest {
            let unorientedIntermediateDirectory = try provenanceIntermediateDirectory(in: unorientedBundleURL)
            let storedUnorientedOrientedFASTQ = unorientedIntermediateDirectory.appendingPathComponent("vsearch-oriented.fastq")
            let storedUnorientedFASTQ = unorientedIntermediateDirectory.appendingPathComponent("vsearch-unoriented.fastq")
            let storedUnorientedTabbedOutput = unorientedIntermediateDirectory.appendingPathComponent("vsearch-orient-results.tsv")
            try copyReplacingItem(at: result.orientedFASTQ, to: storedUnorientedOrientedFASTQ)
            try copyReplacingItem(at: unorientedFASTQ, to: storedUnorientedFASTQ)
            try copyReplacingItem(at: result.tabbedOutput, to: storedUnorientedTabbedOutput)
            var unorientedPathMap = [
                result.orientedFASTQ.path: storedUnorientedOrientedFASTQ.path,
                unorientedFASTQ.path: storedUnorientedFASTQ.path,
                result.tabbedOutput.path: storedUnorientedTabbedOutput.path,
            ]
            var unorientedArgumentPathMap = [
                result.orientedFASTQ.path: storedUnorientedOrientedFASTQ.path,
                result.tabbedOutput.path: storedUnorientedTabbedOutput.path,
                unorientedFASTQ.path: storedUnorientedFASTQ.path,
            ]
            var unorientedBridgeStep: ProvenanceStep?
            if let sourceBridgeFASTQ {
                let storedBridgeFASTQ = unorientedIntermediateDirectory.appendingPathComponent("bridged-source.fastq")
                try copyReplacingItem(at: sourceBridgeFASTQ, to: storedBridgeFASTQ)
                unorientedPathMap[sourceBridgeFASTQ.path] = storedBridgeFASTQ.path
                unorientedArgumentPathMap[sourceBridgeFASTQ.path] = storedBridgeFASTQ.path
                let bridgeOutput = try ProvenanceFileDescriptor.file(url: storedBridgeFASTQ, format: .fastq, role: .output)
                unorientedBridgeStep = appProvenanceStep(
                    argv: [
                        "lungfish-app-action:fastq-synthetic-fastq-from-fasta",
                        "--source-fasta", sourceProvenanceInputRecord.path,
                        "--output-fastq", storedBridgeFASTQ.path,
                    ],
                    inputs: [ProvenanceFileDescriptor(fileRecord: sourceProvenanceInputRecord)],
                    outputs: [bridgeOutput],
                    dependsOn: []
                )
            }
            let unorientedBaseProvenance = try ProvenanceRehydrator.rehydrateSelectedOutputs(
                sourceDirectory: result.orientedFASTQ.deletingLastPathComponent(),
                finalDirectory: unorientedBundleURL,
                pathMap: unorientedPathMap,
                argumentPathMap: unorientedArgumentPathMap,
                preserveOriginMetadata: false
            )
            try writeUnorientedDerivativeProvenance(
                baseEnvelope: unorientedBaseProvenance,
                finalDirectory: unorientedBundleURL,
                argv: orientCommandParts,
                bridgeStep: unorientedBridgeStep,
                storedUnorientedFASTQPath: storedUnorientedFASTQ.path,
                outputURL: unorientedDest,
                outputFormat: sourceSequenceFormat == .fasta ? .fasta : .fastq,
                actionIdentifier: sourceSequenceFormat == .fasta
                    ? "lungfish-app-action:fastq-orient-unmatched-fastq-to-fasta-payload"
                    : "lungfish-app-action:fastq-orient-unmatched-fastq-payload"
            )
        }

        // Clean up vsearch work directory
        let workDir = result.orientedFASTQ.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: workDir)

        progress?("Orient complete: \(fwdCount) forward, \(rcCount) reverse-complemented, \(result.unmatchedCount) unmatched")
        shouldCleanCreatedOrientBundlesOnFailure = false
        return bundleURL
    }

    func writeOrientDerivativeProvenance(
        baseEnvelope: ProvenanceEnvelope,
        finalDirectory: URL,
        argv: [String],
        sourceInputRecord: FileRecord,
        bridgeStep: ProvenanceStep?,
        storedTabbedOutputPath: String,
        orientMapURL: URL,
        previewURL: URL
    ) throws {
        let orientMapDescriptor = try ProvenanceFileDescriptor.file(url: orientMapURL, format: .text, role: .output)
        var finalOutputs = [orientMapDescriptor]
        var appSteps = [
            appProvenanceStep(
                argv: [
                    "lungfish-app-action:fastq-vsearch-tabbed-output-to-orientation-map",
                    "--vsearch-tabbed-output", storedTabbedOutputPath,
                    "--orient-map", orientMapURL.path,
                ],
                inputs: [
                    ProvenanceFileDescriptor(path: storedTabbedOutputPath, format: .text, role: .input),
                ],
                outputs: [orientMapDescriptor],
                dependsOn: baseEnvelope.steps.map(\.id)
            ),
        ]

        if FileManager.default.fileExists(atPath: previewURL.path) {
            let previewDescriptor = try ProvenanceFileDescriptor.file(url: previewURL, format: .fastq, role: .output)
            let previewInput = bridgeStep?.outputs.first?.withRole(.input)
                ?? ProvenanceFileDescriptor(fileRecord: sourceInputRecord)
            let previewDependencies = [appSteps[0].id] + (bridgeStep.map { [$0.id] } ?? [])
            finalOutputs.append(previewDescriptor)
            appSteps.append(
                appProvenanceStep(
                    argv: [
                        "lungfish-app-action:fastq-preview-from-orientation-map",
                        "--source", previewInput.path,
                        "--orient-map", orientMapURL.path,
                        "--output", previewURL.path,
                    ],
                    inputs: [
                        previewInput,
                        orientMapDescriptor.withRole(.input),
                    ],
                    outputs: [previewDescriptor],
                    dependsOn: previewDependencies
                )
            )
        }

        try writeAugmentedOrientProvenance(
            baseEnvelope: baseEnvelope,
            finalDirectory: finalDirectory,
            argv: argv,
            finalOutputs: finalOutputs,
            preSteps: bridgeStep.map { [$0] } ?? [],
            appSteps: appSteps
        )
    }

    func writeUnorientedDerivativeProvenance(
        baseEnvelope: ProvenanceEnvelope,
        finalDirectory: URL,
        argv: [String],
        bridgeStep: ProvenanceStep?,
        storedUnorientedFASTQPath: String,
        outputURL: URL,
        outputFormat: FileFormat,
        actionIdentifier: String
    ) throws {
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: outputURL, format: outputFormat, role: .output)
        let appStep = appProvenanceStep(
            argv: [
                actionIdentifier,
                "--input", storedUnorientedFASTQPath,
                "--output", outputURL.path,
            ],
            inputs: [
                ProvenanceFileDescriptor(path: storedUnorientedFASTQPath, format: .fastq, role: .input),
            ],
            outputs: [outputDescriptor],
            dependsOn: baseEnvelope.steps.map(\.id)
        )

        try writeAugmentedOrientProvenance(
            baseEnvelope: baseEnvelope,
            finalDirectory: finalDirectory,
            argv: argv,
            finalOutputs: [outputDescriptor],
            preSteps: bridgeStep.map { [$0] } ?? [],
            appSteps: [appStep]
        )
    }

    func appProvenanceStep(
        argv: [String],
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        dependsOn: [UUID],
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: "Lungfish App",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: wallTimeSeconds,
            stderr: stderr,
            dependsOn: dependsOn,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    func nativeProvenanceSteps(
        from executions: [FASTQDerivativeNativeToolExecution],
        inputs: [ProvenanceFileDescriptor],
        replayContext: FASTQDerivativeNativeReplayContext
    ) -> [ProvenanceStep] {
        executions.map { execution in
            let rewrittenArgv = rewriteNativeArguments(
                execution.result.arguments,
                using: replayContext.pathReplacements
            )
            let durableArgv = durableNativeReplayArgv(
                rewrittenArgv,
                replayContext: replayContext
            )
            let reproducibleCommand = durableArgv?.map(shellEscape).joined(separator: " ") ?? ""
            return ProvenanceStep(
                toolName: execution.tool.executableName,
                toolVersion: nativeToolVersionString(for: execution),
                argv: execution.result.arguments,
                durableReplayArgv: durableArgv,
                reproducibleCommand: reproducibleCommand,
                inputs: inputs,
                outputs: [],
                exitStatus: Int(execution.result.exitCode),
                wallTimeSeconds: execution.completedAt.timeIntervalSince(execution.startedAt),
                stderr: nonEmptyStderr(execution.result.stderr),
                dependsOn: [],
                startedAt: execution.startedAt,
                completedAt: execution.completedAt
            )
        }
    }

    func durableNativeReplayArgv(
        _ argv: [String],
        replayContext: FASTQDerivativeNativeReplayContext
    ) -> [String]? {
        guard !argv.contains(where: { argument in
            nativeArgumentReferencesTemporaryPath(argument, roots: replayContext.temporaryPathRoots)
                || nativeArgumentReferencesFASTQBundleDirectory(argument)
        }) else {
            return nil
        }
        return argv
    }

    func nativeToolVersionString(for execution: FASTQDerivativeNativeToolExecution) -> String {
        let version = execution.toolVersion ?? "unknown"
        let executable = execution.result.arguments.first ?? execution.tool.executableName
        switch execution.tool.location {
        case .managed(let environment, _):
            return "\(version) (conda:\(environment); executable:\(executable))"
        case .bundled:
            return "\(version) (bundled; executable:\(executable))"
        }
    }

    func nonEmptyStderr(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    func rewriteNativeArguments(
        _ argv: [String],
        using replacements: [String: String]
    ) -> [String] {
        argv.map { rewriteNativeArgument($0, using: replacements) }
    }

    func rewriteNativeArgument(
        _ argument: String,
        using replacements: [String: String]
    ) -> String {
        for (source, destination) in sortedPathReplacements(replacements) where argument == source {
            return destination
        }
        if argument.hasPrefix("file:") {
            let path = String(argument.dropFirst("file:".count))
            if let replacement = replacementPath(for: path, replacements: replacements) {
                return "file:\(replacement)"
            }
        }
        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return argument
        }
        let prefix = String(argument[...equalsIndex])
        let value = String(argument[argument.index(after: equalsIndex)...])
        if let replacement = replacementPath(for: value, replacements: replacements) {
            return prefix + replacement
        }
        return argument
    }

    func replacementPath(
        for path: String,
        replacements: [String: String]
    ) -> String? {
        let standardized = standardizedPath(path)
        return sortedPathReplacements(replacements).first { source, _ in
            standardizedPath(source) == standardized
        }?.value
    }

    func sortedPathReplacements(_ replacements: [String: String]) -> [(key: String, value: String)] {
        replacements.sorted { lhs, rhs in lhs.key.count > rhs.key.count }
    }

    func derivativeNativeReplayContext(
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        sourceSequenceFormat: SequenceFormat,
        transformedFASTQ: URL?,
        outputBundleURL: URL,
        payload: FASTQDerivativePayload,
        temporaryPathRoots: [String]
    ) -> FASTQDerivativeNativeReplayContext {
        var replacements: [String: String] = [:]
        if let durableSourceFASTQ = durableNativeSourceFASTQURL(
            for: sourceBundleURL,
            sourceSequenceFormat: sourceSequenceFormat
        ) {
            replacements[sourceFASTQ.path] = durableSourceFASTQ.path
        }
        if let transformedFASTQ,
           let durableOutputFASTQ = durableNativeOutputFASTQURL(
               in: outputBundleURL,
               payload: payload
           ) {
            replacements[transformedFASTQ.path] = durableOutputFASTQ.path
        }
        return FASTQDerivativeNativeReplayContext(
            pathReplacements: replacements,
            temporaryPathRoots: temporaryPathRoots
        )
    }

    func durableNativeSourceFASTQURL(
        for sourceBundleURL: URL,
        sourceSequenceFormat: SequenceFormat
    ) -> URL? {
        guard sourceSequenceFormat == .fastq else {
            return nil
        }
        if let manifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL) {
            if case .full(let fastqFilename) = manifest.payload {
                guard let url = try? FASTQBundle.validatedBundleMemberURL(
                    for: fastqFilename,
                    in: sourceBundleURL,
                    field: "payload.full.fastqFilename"
                ) else {
                    return nil
                }
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return nil
        }
        guard let url = FASTQBundle.resolvePrimarySequenceURL(for: sourceBundleURL),
              SequenceFormat.from(url: url) == .fastq else {
            return nil
        }
        return url
    }

    func durableNativeOutputFASTQURL(
        in outputBundleURL: URL,
        payload: FASTQDerivativePayload
    ) -> URL? {
        guard case .full(let fastqFilename) = payload else {
            return nil
        }
        guard let url = try? FASTQBundle.validatedBundleMemberURL(
            for: fastqFilename,
            in: outputBundleURL,
            field: "payload.full.fastqFilename"
        ) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func nativeArgumentReferencesTemporaryPath(_ argument: String, roots: [String]) -> Bool {
        guard !roots.isEmpty else { return false }
        return nativeArgumentPathCandidates(argument).contains { path in
            let standardized = standardizedPath(path)
            return roots.contains { root in
                standardized == root || standardized.hasPrefix(root + "/")
            }
        }
    }

    func nativeArgumentReferencesFASTQBundleDirectory(_ argument: String) -> Bool {
        nativeArgumentPathCandidates(argument).contains { path in
            URL(fileURLWithPath: path).standardizedFileURL.pathExtension == FASTQBundle.directoryExtension
        }
    }

    func nativeArgumentPathCandidates(_ argument: String) -> [String] {
        if argument.hasPrefix("file:") {
            return [String(argument.dropFirst("file:".count))]
        }
        if let equalsIndex = argument.firstIndex(of: "=") {
            return [String(argument[argument.index(after: equalsIndex)...])]
        }
        if argument.hasPrefix("/") {
            return [argument]
        }
        return []
    }

    func writeAugmentedOrientProvenance(
        baseEnvelope: ProvenanceEnvelope,
        finalDirectory: URL,
        argv: [String],
        finalOutputs: [ProvenanceFileDescriptor],
        preSteps: [ProvenanceStep] = [],
        appSteps: [ProvenanceStep]
    ) throws {
        let outputPaths = Set(finalOutputs.map { standardizedPath($0.path) })
        let retainedSteps = addDependencies(
            preSteps.map(\.id),
            to: stripOutputs(outputPaths, from: baseEnvelope.steps)
        )
        let retainedFiles = baseEnvelope.files.filter { descriptor in
            !(descriptor.role == .output && outputPaths.contains(standardizedPath(descriptor.path)))
        }
        let appDescriptors = (preSteps + appSteps).flatMap { $0.inputs + $0.outputs }
        let files = deduplicatedProvenanceDescriptors(retainedFiles + appDescriptors + finalOutputs)
        let envelope = ProvenanceEnvelope(
            schemaVersion: baseEnvelope.schemaVersion,
            id: baseEnvelope.id,
            createdAt: baseEnvelope.createdAt,
            workflowName: "lungfish fastq orient derivative",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish App",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            options: baseEnvelope.options,
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "Lungfish.app"),
            files: files,
            output: finalOutputs.first,
            outputs: finalOutputs,
            steps: preSteps + retainedSteps + appSteps,
            wallTimeSeconds: baseEnvelope.wallTimeSeconds,
            exitStatus: baseEnvelope.exitStatus,
            stderr: baseEnvelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
        try provenanceWriter.write(envelope, to: finalDirectory)
    }

    func writeDerivativeProvenance(
        workflowName: String,
        request: FASTQDerivativeRequest,
        operation: FASTQDerivativeOperation? = nil,
        sourceBundleURL: URL,
        sourceSequenceFormat: SequenceFormat,
        outputBundleURL: URL,
        nativeExecutions: [FASTQDerivativeNativeToolExecution] = [],
        nativeReplayContext: FASTQDerivativeNativeReplayContext = FASTQDerivativeNativeReplayContext(),
        startedAt: Date,
        completedAt: Date
    ) async throws {
        let sourceInputRecord = try durableSourceInputRecord(
            for: sourceBundleURL,
            sequenceFormat: sourceSequenceFormat
        )
        let sourceInput = ProvenanceFileDescriptor(fileRecord: sourceInputRecord)
        let additionalInputs = try await derivativeAdditionalInputDescriptors(
            for: request,
            sourceBundleURL: sourceBundleURL
        )
        let inputDescriptors = deduplicatedProvenanceDescriptors([sourceInput] + additionalInputs)
        let outputs = try derivativeOutputDescriptors(in: outputBundleURL)
        let argv = derivativeProvenanceArgv(
            request: request,
            operation: operation,
            sourceBundleURL: sourceBundleURL,
            outputBundleURL: outputBundleURL
        )
        let wallTimeSeconds = completedAt.timeIntervalSince(startedAt)
        let nativeSteps = nativeProvenanceSteps(
            from: nativeExecutions,
            inputs: inputDescriptors,
            replayContext: nativeReplayContext
        )
        let step = appProvenanceStep(
            argv: argv,
            inputs: inputDescriptors,
            outputs: outputs,
            dependsOn: nativeSteps.map(\.id),
            wallTimeSeconds: wallTimeSeconds,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish App",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: "Lungfish App", version: WorkflowRun.currentAppVersion, kind: "app"),
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            options: derivativeProvenanceOptions(
                request: request,
                operation: operation,
                sourceBundleURL: sourceBundleURL,
                outputBundleURL: outputBundleURL
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: "Lungfish.app"),
            files: deduplicatedProvenanceDescriptors(inputDescriptors + outputs + nativeSteps.flatMap { $0.inputs + $0.outputs }),
            output: outputs.first,
            outputs: outputs,
            steps: nativeSteps + [step],
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: 0,
            stderr: nil,
            signatures: [],
            legacyWorkflowRun: nil
        )
        try provenanceWriter.write(envelope, to: outputBundleURL)
    }

    func writeDemultiplexDerivativeProvenance(
        request: FASTQDerivativeRequest,
        sourceBundleURL: URL,
        sourceSequenceFormat: SequenceFormat,
        result: DemultiplexResult,
        startedAt: Date,
        completedAt: Date
    ) async throws {
        let outputBundles = result.outputBundleURLs + (result.unassignedBundleURL.map { [$0] } ?? [])
        for outputBundleURL in outputBundles {
            try await writeDerivativeProvenance(
                workflowName: "lungfish fastq demultiplex derivative",
                request: request,
                sourceBundleURL: sourceBundleURL,
                sourceSequenceFormat: sourceSequenceFormat,
                outputBundleURL: outputBundleURL,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }
    }

    func derivativeProvenanceArgv(
        request: FASTQDerivativeRequest,
        operation: FASTQDerivativeOperation?,
        sourceBundleURL: URL,
        outputBundleURL: URL
    ) -> [String] {
        var argv = [
            "lungfish-app-workflow:fastq-derivative",
            "--source-bundle",
            sourceBundleURL.path,
            "--operation",
            request.operationKindString,
            "--output-bundle",
            outputBundleURL.path,
        ]
        argv += request.provenanceCLIArguments
        if let randomSeed = operation?.randomSeed {
            argv += ["--random-seed", String(randomSeed)]
        }
        return argv
    }

    func derivativeProvenanceOptions(
        request: FASTQDerivativeRequest,
        operation: FASTQDerivativeOperation?,
        sourceBundleURL: URL,
        outputBundleURL: URL
    ) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [
            "operation": .string(request.operationKindString),
            "sourceBundle": .file(sourceBundleURL),
            "outputBundle": .file(outputBundleURL),
        ]
        explicit.merge(request.provenanceExplicitOptions) { _, new in new }
        if let randomSeed = operation?.randomSeed {
            explicit["randomSeed"] = .integer(Int(randomSeed))
        }
        let defaults = request.provenanceDefaultOptions
        var resolved = defaults
        resolved.merge(explicit) { _, explicit in explicit }
        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: resolved
        )
    }

    func derivativeAdditionalInputDescriptors(
        for request: FASTQDerivativeRequest,
        sourceBundleURL: URL
    ) async throws -> [ProvenanceFileDescriptor] {
        var references: [(url: URL, format: FileFormat)] = []

        switch request {
        case .adapterTrim(let mode, _, _, let fastaFilename) where mode == .fastaFile:
            if let fastaFilename,
               let fastaURL = try? FASTQBundle.validatedBundleMemberURL(
                for: fastaFilename,
                in: sourceBundleURL,
                field: "adapterTrim.fastaFilename"
               ) {
                references.append((fastaURL, .fasta))
            }
        case .contaminantFilter(let mode, let referenceFasta, _, _):
            switch mode {
            case .phix:
                if let phixReference = CoreToolLocator.bbToolsPhiXReferenceURL(
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ) {
                    references.append((phixReference, .fasta))
                }
            case .custom:
                if let refURL = resolveReferenceInputURL(referenceFasta, relativeTo: sourceBundleURL) {
                    references.append((refURL, .fasta))
                }
            }
        case .primerRemoval(let configuration) where configuration.source == .reference:
            if let refURL = resolveReferenceInputURL(configuration.referenceFasta, relativeTo: sourceBundleURL) {
                references.append((refURL, .fasta))
            }
        case .sequencePresenceFilter(_, let fastaPath, _, _, _, _, _):
            if let fastaURL = resolveReferenceInputURL(fastaPath, relativeTo: sourceBundleURL) {
                references.append((fastaURL, .fasta))
            }
        case .demultiplex(_, let customCSVPath, _, _, _, _, _, _, _, _, _):
            if let csvURL = resolveReferenceInputURL(customCSVPath, relativeTo: sourceBundleURL) {
                references.append((csvURL, .text))
            }
        case .humanReadScrub(let databaseID, _):
            let databaseURL = try await humanScrubberDatabasePath(databaseID)
            references.append((databaseURL, .unknown))
        default:
            break
        }

        var seen = Set<String>()
        return try references.compactMap { reference in
            let path = reference.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return try ProvenanceFileDescriptor.file(
                url: reference.url,
                format: reference.format,
                role: .input
            )
        }
    }

    func resolveReferenceInputURL(_ path: String?, relativeTo bundleURL: URL) -> URL? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return bundleURL.appendingPathComponent(path)
    }

    func derivativeOutputDescriptors(in bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            throw FASTQDerivativeError.derivedManifestMissing
        }
        var outputURLs = derivativePayloadURLs(in: bundleURL, manifest: manifest)
        let manifestURL = FASTQBundle.derivedManifestURL(in: bundleURL)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            outputURLs.append(manifestURL)
        }
        let readManifestURL = bundleURL.appendingPathComponent(ReadManifest.filename)
        if FileManager.default.fileExists(atPath: readManifestURL.path) {
            outputURLs.append(readManifestURL)
        }
        var seen = Set<String>()
        return try outputURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }.map { url in
            try ProvenanceFileDescriptor.file(
                url: url,
                format: provenanceFileFormat(forPayloadAt: url),
                role: .output
            )
        }
    }

    func derivativePayloadURLs(in bundleURL: URL, manifest: FASTQDerivedBundleManifest) -> [URL] {
        switch manifest.payload {
        case .subset(let readIDListFilename):
            return existingPayloadURLs(in: bundleURL, filenames: [readIDListFilename, "preview.fastq"])
        case .trim(let trimPositionFilename):
            return existingPayloadURLs(in: bundleURL, filenames: [trimPositionFilename, "preview.fastq"])
        case .full(let fastqFilename):
            return existingPayloadURLs(in: bundleURL, filenames: [fastqFilename])
        case .fullPaired(let r1Filename, let r2Filename):
            return existingPayloadURLs(in: bundleURL, filenames: [r1Filename, r2Filename])
        case .fullMixed(let classification):
            return existingPayloadURLs(in: bundleURL, filenames: classification.files.map(\.filename))
        case .fullFASTA(let fastaFilename):
            return existingPayloadURLs(in: bundleURL, filenames: [fastaFilename])
        case .demuxedVirtual(_, let readIDListFilename, let previewFilename, let trimPositionsFilename, let orientMapFilename):
            return existingPayloadURLs(
                in: bundleURL,
                filenames: [readIDListFilename, previewFilename, trimPositionsFilename, orientMapFilename].compactMap { $0 }
            )
        case .demuxGroup:
            return []
        case .orientMap(let orientMapFilename, let previewFilename):
            return existingPayloadURLs(in: bundleURL, filenames: [orientMapFilename, previewFilename])
        }
    }

    func existingPayloadURLs(in bundleURL: URL, filenames: [String]) -> [URL] {
        filenames.map { bundleURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func provenanceFileFormat(forPayloadAt url: URL) -> FileFormat {
        if let sequenceFormat = SequenceFormat.from(url: url) {
            return provenanceFileFormat(for: sequenceFormat)
        }
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "txt", "tsv":
            return .text
        default:
            return .unknown
        }
    }

    func stripOutputs(
        _ outputPaths: Set<String>,
        from steps: [ProvenanceStep]
    ) -> [ProvenanceStep] {
        steps.map { step in
            let outputs = step.outputs.filter { !outputPaths.contains(standardizedPath($0.path)) }
            guard outputs != step.outputs else { return step }
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                inputs: step.inputs,
                outputs: outputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    func addDependencies(
        _ dependencyIDs: [UUID],
        to steps: [ProvenanceStep]
    ) -> [ProvenanceStep] {
        guard !dependencyIDs.isEmpty else { return steps }
        return steps.map { step in
            let dependsOn = step.dependsOn + dependencyIDs.filter { !step.dependsOn.contains($0) }
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                inputs: step.inputs,
                outputs: step.outputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    func provenanceIntermediateDirectory(in bundleURL: URL) throws -> URL {
        let directory = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent("intermediates", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func copyReplacingItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func deduplicatedProvenanceDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { descriptor in
            seen.insert("\(descriptor.role)|\(standardizedPath(descriptor.path))").inserted
        }
    }

    func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func orientProvenanceOptions(
        sourceInputRecord: FileRecord,
        referenceURL: URL,
        wordLength: Int,
        dbMask: String,
        saveUnoriented: Bool,
        extraArguments: [String]
    ) -> ProvenanceOptions {
        let sourceURL = URL(fileURLWithPath: sourceInputRecord.path)
        let extraArgumentValues = extraArguments.map(ParameterValue.string)
        let resolved: [String: ParameterValue] = [
            "input": .file(sourceURL),
            "reference": .file(referenceURL),
            "wordLength": .integer(wordLength),
            "dbMask": .string(dbMask),
            "qMask": .string(dbMask),
            "saveUnoriented": .boolean(saveUnoriented),
            "threads": .integer(0),
            "extraArguments": .array(extraArgumentValues),
        ]
        return ProvenanceOptions(
            explicit: resolved,
            defaults: [
                "wordLength": .integer(12),
                "dbMask": .string("dust"),
                "qMask": .string("dust"),
                "saveUnoriented": .boolean(true),
                "threads": .integer(0),
                "extraArguments": .array([]),
            ],
            resolvedDefaults: resolved
        )
    }

    func durableSourceInputRecord(
        for sourceBundleURL: URL,
        sequenceFormat: SequenceFormat
    ) throws -> FileRecord {
        if !FASTQBundle.isDerivedBundle(sourceBundleURL),
           let primaryURL = FASTQBundle.resolvePrimarySequenceURL(for: sourceBundleURL) {
            return ProvenanceRecorder.fileRecord(
                url: primaryURL,
                format: provenanceFileFormat(for: sequenceFormat),
                role: .input
            )
        }

        if let manifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL) {
            switch manifest.payload {
            case .full(let fastqFilename):
                if let payloadURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: fastqFilename,
                    in: sourceBundleURL,
                    field: "payload.full.fastqFilename"
                ), FileManager.default.fileExists(atPath: payloadURL.path) {
                    return ProvenanceRecorder.fileRecord(url: payloadURL, format: .fastq, role: .input)
                }
            case .fullFASTA(let fastaFilename):
                if let payloadURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: fastaFilename,
                    in: sourceBundleURL,
                    field: "payload.fullFASTA.fastaFilename"
                ), FileManager.default.fileExists(atPath: payloadURL.path) {
                    return ProvenanceRecorder.fileRecord(url: payloadURL, format: .fasta, role: .input)
                }
            default:
                break
            }
        }

        return try durableBundleInputRecord(
            for: sourceBundleURL,
            format: provenanceFileFormat(for: sequenceFormat)
        )
    }

    func durableBundleInputRecord(for bundleURL: URL, format: FileFormat) throws -> FileRecord {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: bundleURL, role: .input)
        let sizeBytes = manifest.files.reduce(UInt64(0)) { partial, descriptor in
            partial + (descriptor.fileSize ?? 0)
        }
        let digestInput = manifest.files
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    String(descriptor.fileSize ?? 0),
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return FileRecord(
            path: bundleURL.path,
            sha256: digest,
            sizeBytes: sizeBytes,
            format: format,
            role: .input
        )
    }

    func provenanceFileFormat(for sequenceFormat: SequenceFormat) -> FileFormat {
        switch sequenceFormat {
        case .fasta:
            return .fasta
        case .fastq:
            return .fastq
        }
    }

    func runNativeTool(
        _ tool: NativeTool,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?
    ) async throws -> NativeToolResult {
        let startedAt = Date()
        let result = try await runner.run(
            tool,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        let completedAt = Date()
        if let provenanceCollector {
            let toolVersion = await runner.getToolVersion(tool)
            provenanceCollector.append(
                FASTQDerivativeNativeToolExecution(
                    tool: tool,
                    toolVersion: toolVersion,
                    result: result,
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        }
        return result
    }

    /// Parses seqkit stats tabular output into FASTQDatasetStatistics.
    func parseFASTQStats(_ output: String) -> FASTQDatasetStatistics? {
        // Header-driven so a seqkit column change cannot shift values between fields.
        guard let row = try? SeqkitStatsParser.parse(output) else { return nil }

        return FASTQDatasetStatistics(
            readCount: row.numSeqs, baseCount: Int64(row.sumLen),
            meanReadLength: row.avgLen, minReadLength: row.minLen, maxReadLength: row.maxLen,
            medianReadLength: Int(row.avgLen), n50ReadLength: 0,
            meanQuality: 0, q20Percentage: 0, q30Percentage: 0, gcContent: 0,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
    }

    /// Runs cutadapt-based demultiplexing and returns the most representative output bundle.
    ///
    /// The demultiplex output directory is created next to the source bundle and contains one
    /// `.lungfishfastq` bundle per barcode (plus optional `unassigned.lungfishfastq`).
    /// Returns the largest assigned barcode bundle for immediate selection in the UI.
    func createDemultiplexDerivative(
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        rootBundleURL: URL,
        rootFASTQFilename: String,
        inputSequenceFormat: SequenceFormat,
        pairingMode: IngestionMetadata.PairingMode?,
        kitID: String,
        customCSVPath: String?,
        location: String,
        maxDistanceFrom5Prime: Int,
        maxDistanceFrom3Prime: Int,
        errorRate: Double,
        engine: DemultiplexEngine = .cutadapt,
        minimumOverlap: Int? = nil,
        symmetryMode: BarcodeSymmetryMode? = nil,
        searchReverseComplement: Bool? = nil,
        unassignedDisposition: UnassignedDisposition = .keep,
        allowIndels: Bool = true,
        trimBarcodes: Bool,
        sampleAssignments: [FASTQSampleBarcodeAssignment],
        kitOverride: BarcodeKitDefinition?,
        batchOperationID: UUID?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let provenanceStartedAt = Date()
        let barcodeKit: BarcodeKitDefinition
        if let kitOverride {
            // Use the caller-provided kit directly (e.g. pruned by scout)
            barcodeKit = kitOverride
        } else if let customCSVPath, !customCSVPath.isEmpty {
            let csvURL: URL
            if customCSVPath.hasPrefix("/") {
                csvURL = URL(fileURLWithPath: customCSVPath)
            } else {
                csvURL = sourceBundleURL.appendingPathComponent(customCSVPath)
            }
            guard FileManager.default.fileExists(atPath: csvURL.path) else {
                throw FASTQDerivativeError.invalidOperation("Custom barcode CSV not found: \(csvURL.path)")
            }
            barcodeKit = try BarcodeKitRegistry.loadCustomKit(from: csvURL, name: "Custom")
        } else if let builtin = BarcodeKitRegistry.kit(byID: kitID) {
            barcodeKit = builtin
        } else {
            throw FASTQDerivativeError.invalidOperation("Unknown barcode kit: \(kitID)")
        }

        let barcodeLocation: BarcodeLocation
        switch location.lowercased() {
        case "fiveprime", "5prime", "five_prime":
            barcodeLocation = .fivePrime
        case "threeprime", "3prime", "three_prime":
            barcodeLocation = .threePrime
        case "bothends", "both_ends", "both-ends", "both":
            barcodeLocation = .bothEnds
        default:
            throw FASTQDerivativeError.invalidOperation("Unsupported barcode location: \(location)")
        }

        // Create demux output as a child directory inside the source bundle
        // This produces a parent-child hierarchy: parent.lungfishfastq/demux/barcode01/...
        let outputDirectory = sourceBundleURL.appendingPathComponent("demux", isDirectory: true)
        // Remove prior demux results if re-running
        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var shouldCleanOutputDirectoryOnFailure = true
        defer {
            if shouldCleanOutputDirectoryOnFailure {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }
        OperationMarker.markInProgress(outputDirectory, detail: "Creating derivative FASTQ\u{2026}")
        defer { OperationMarker.clearInProgress(outputDirectory) }

        progress?("Demultiplexing reads...")
        let pipeline = DemultiplexingPipeline()
        let effectiveTrimBarcodes = engine == .exactBareBarcode ? false : trimBarcodes
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: sourceFASTQ,
                sourceBundleURL: sourceBundleURL,
                barcodeKit: barcodeKit,
                outputDirectory: outputDirectory,
                barcodeLocation: barcodeLocation,
                symmetryMode: symmetryMode,
                errorRate: errorRate,
                minimumOverlap: minimumOverlap,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                trimBarcodes: effectiveTrimBarcodes,
                searchReverseComplement: searchReverseComplement,
                unassignedDisposition: unassignedDisposition,
                engine: engine,
                sampleAssignments: sampleAssignments,
                rootBundleURL: rootBundleURL,
                rootFASTQFilename: rootFASTQFilename,
                inputPairingMode: pairingMode,
                inputSequenceFormat: inputSequenceFormat,
                useNoIndels: !allowIndels
            ),
            progress: { fraction, message in
                let percent = Int((fraction * 100.0).rounded())
                progress?("Demultiplexing (\(percent)%): \(message)")
            }
        )

        // Prefer selecting the largest assigned barcode bundle; fall back to unassigned.
        let selectedBundle: URL
        if let topBarcode = result.manifest.barcodes.max(by: { $0.readCount < $1.readCount }) {
            selectedBundle = outputDirectory.appendingPathComponent(topBarcode.bundleRelativePath, isDirectory: true)
        } else if let unassigned = result.unassignedBundleURL {
            selectedBundle = unassigned
        } else {
            throw FASTQDerivativeError.emptyResult
        }

        if let batchOperationID {
            let outputBundles = result.outputBundleURLs + (result.unassignedBundleURL.map { [$0] } ?? [])
            for outputBundleURL in outputBundles {
                try attachBatchOperationID(batchOperationID, to: outputBundleURL)
            }
        }

        try await writeDemultiplexDerivativeProvenance(
            request: .demultiplex(
                kitID: kitID,
                customCSVPath: customCSVPath,
                location: location,
                symmetryMode: symmetryMode,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                errorRate: errorRate,
                engine: engine,
                trimBarcodes: effectiveTrimBarcodes,
                sampleAssignments: sampleAssignments,
                kitOverride: kitOverride
            ),
            sourceBundleURL: sourceBundleURL,
            sourceSequenceFormat: inputSequenceFormat,
            result: result,
            startedAt: provenanceStartedAt,
            completedAt: Date()
        )

        // Persist manifest in source bundle so downstream batch workflows can discover demux runs.
        if FASTQBundle.isBundleURL(sourceBundleURL) {
            let sourceScopedManifest = DemultiplexManifest(
                version: result.manifest.version,
                runID: result.manifest.runID,
                demultiplexedAt: result.manifest.demultiplexedAt,
                barcodeKit: result.manifest.barcodeKit,
                parameters: result.manifest.parameters,
                barcodes: result.manifest.barcodes,
                unassigned: result.manifest.unassigned,
                outputDirectoryRelativePath: relativePath(from: sourceBundleURL, to: outputDirectory),
                inputReadCount: result.manifest.inputReadCount
            )
            try? sourceScopedManifest.save(to: sourceBundleURL)
        }

        if !sampleAssignments.isEmpty {
            persistDemultiplexedSampleMetadata(
                for: result,
                outputDirectory: outputDirectory,
                sourceBundleURL: sourceBundleURL,
                assignments: sampleAssignments
            )
        }

        progress?("Demultiplex complete: \(result.manifest.barcodes.count) barcode bundle(s)")
        derivativeLogger.info("Created demultiplex output at \(outputDirectory.path, privacy: .public)")
        shouldCleanOutputDirectoryOnFailure = false
        return selectedBundle
    }

    func persistDemultiplexedSampleMetadata(
        for result: DemultiplexResult,
        outputDirectory: URL,
        sourceBundleURL: URL,
        assignments: [FASTQSampleBarcodeAssignment]
    ) {
        var assignmentLookup: [String: FASTQSampleBarcodeAssignment] = [:]
        for assignment in assignments {
            assignmentLookup[normalizeSampleKey(assignment.sampleID)] = assignment
        }
        guard !assignmentLookup.isEmpty else { return }

        for barcode in result.manifest.barcodes {
            let key = normalizeSampleKey(barcode.barcodeID)
            guard let assignment = assignmentLookup[key] else { continue }

            let bundleURL = outputDirectory.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            guard let payloadFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
                  FileManager.default.fileExists(atPath: payloadFASTQ.path) else {
                continue
            }

            var metadata = FASTQMetadataStore.load(for: payloadFASTQ) ?? PersistedFASTQMetadata()
            var demux = metadata.demultiplexMetadata ?? FASTQDemultiplexMetadata()

            // Child bundles only need the single resolved sample assignment.
            let resolvedAssignment = FASTQSampleBarcodeAssignment(
                sampleID: assignment.sampleID,
                sampleName: assignment.sampleName,
                forwardBarcodeID: assignment.forwardBarcodeID ?? barcode.barcodeID,
                forwardSequence: barcode.forwardSequence ?? assignment.forwardSequence,
                reverseBarcodeID: assignment.reverseBarcodeID,
                reverseSequence: barcode.reverseSequence ?? assignment.reverseSequence,
                metadata: assignment.metadata
            )
            demux.sampleAssignments = [resolvedAssignment]
            metadata.demultiplexMetadata = demux
            FASTQMetadataStore.save(metadata, for: payloadFASTQ)
        }

        // Preserve full sample-assignment metadata on the demultiplexed source as well.
        if let sourceFASTQ = FASTQBundle.resolvePrimaryFASTQURL(for: sourceBundleURL) {
            var sourceMetadata = FASTQMetadataStore.load(for: sourceFASTQ) ?? PersistedFASTQMetadata()
            var sourceDemux = sourceMetadata.demultiplexMetadata ?? FASTQDemultiplexMetadata()
            sourceDemux.sampleAssignments = assignments
            sourceMetadata.demultiplexMetadata = sourceDemux
            FASTQMetadataStore.save(sourceMetadata, for: sourceFASTQ)
        }
    }

    func normalizeSampleKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .lowercased()
    }

    func convertFASTQSequencesToFASTA(inputURL: URL, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: inputURL) {
            var content = ">\(record.identifier)"
            if let description = record.description, !description.isEmpty {
                content += " \(description)"
            }
            content += "\n"
            content += wrappedSequence(record.sequence)
            if let data = content.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    func wrappedSequence(_ sequence: String, lineWidth: Int = 60) -> String {
        guard !sequence.isEmpty else { return "\n" }
        var output = ""
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            output += sequence[index..<end] + "\n"
            index = end
        }
        return output
    }

    /// Creates a derivative bundle for operations that produce multiple classified files
    /// (e.g. paired-end merge produces R1, R2, and merged files).
    func createMixedOutputDerivative(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        sourceBundleURL: URL,
        sourceSequenceFormat: SequenceFormat,
        resolvedRootBundleURL: URL,
        rootFASTQFilename: String,
        pairingMode: IngestionMetadata.PairingMode?,
        baseLineage: [FASTQDerivativeOperation],
        nativeTemporaryPathRoots: [String],
        batchOperationID: UUID?,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let provenanceStartedAt = Date()
        let nativeProvenanceCollector = FASTQDerivativeNativeProvenanceCollector()
        // Build the operation metadata first (for bundle naming)
        let operation: FASTQDerivativeOperation
        let classification: ReadClassification

        let outputBundle = try createOutputBundleURL(
            sourceBundleURL: sourceBundleURL,
            request: request
        )
        try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)
        var shouldCleanOutputBundleOnFailure = true
        defer {
            if shouldCleanOutputBundleOnFailure {
                try? FileManager.default.removeItem(at: outputBundle)
            }
        }
        OperationMarker.markInProgress(outputBundle, detail: "Creating derivative FASTQ\u{2026}")
        defer { OperationMarker.clearInProgress(outputBundle) }

        switch request {
        case .pairedEndMerge(let strictness, let minOverlap):
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "PE merge requires interleaved paired-end input."
                )
            }
            progress?("Merging overlapping pairs...")
            let (result, cls) = try await runBBMerge(
                sourceFASTQ: sourceFASTQ,
                outputBundleURL: outputBundle,
                strictness: strictness,
                minOverlap: minOverlap,
                provenanceCollector: nativeProvenanceCollector
            )
            classification = cls
            operation = FASTQDerivativeOperation(
                kind: .pairedEndMerge,
                mergeStrictness: strictness,
                mergeMinOverlap: minOverlap,
                mergeCountDuplicates: true,
                toolUsed: "bbmerge",
                toolCommand: result.toolCommand
            )

        case .pairedEndRepair:
            guard isInterleavedBundle(sourceBundleURL) else {
                throw FASTQDerivativeError.invalidOperation(
                    "PE repair requires interleaved paired-end input."
                )
            }
            progress?("Repairing paired-end reads...")
            let (result, cls) = try await runBBRepair(
                sourceFASTQ: sourceFASTQ,
                outputBundleURL: outputBundle,
                provenanceCollector: nativeProvenanceCollector
            )
            classification = cls
            operation = FASTQDerivativeOperation(
                kind: .pairedEndRepair,
                toolUsed: "repair",
                toolCommand: result.toolCommand
            )

        default:
            throw FASTQDerivativeError.invalidOperation(
                "Mixed-output execution requested for unsupported operation: \(request)"
            )
        }

        guard classification.totalReadCount > 0 else {
            // Clean up the empty bundle
            try? FileManager.default.removeItem(at: outputBundle)
            throw FASTQDerivativeError.emptyResult
        }

        // Compute statistics from the largest output file for dashboard display
        progress?("Computing output statistics...")
        let largestFile = classification.files.max(by: { $0.readCount < $1.readCount })
        let statsURL: URL
        if let largestFile {
            statsURL = outputBundle.appendingPathComponent(largestFile.filename)
        } else {
            throw FASTQDerivativeError.emptyResult
        }
        let reader = FASTQReader(validateSequence: false)
        let (stats, _) = try await reader.computeStatistics(from: statsURL, sampleLimit: 0)

        let lineage = baseLineage + [operation]

        // Save the read manifest alongside the derived manifest
        let readManifest = ReadManifest(
            classification: classification,
            sourceOperation: operation.kind.rawValue
        )
        try readManifest.save(to: outputBundle)

        let mixedParentPath = FASTQBundle.projectRelativePath(for: sourceBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: sourceBundleURL)
        let mixedRootPath = FASTQBundle.projectRelativePath(for: resolvedRootBundleURL, from: outputBundle)
            ?? relativePathFromBundle(outputBundle, to: resolvedRootBundleURL)

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: mixedParentPath,
            rootBundleRelativePath: mixedRootPath,
            rootFASTQFilename: rootFASTQFilename,
            payload: .fullMixed(classification),
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode,
            readClassification: classification,
            batchOperationID: batchOperationID
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)
        let nativeReplayContext = derivativeNativeReplayContext(
            sourceFASTQ: sourceFASTQ,
            sourceBundleURL: sourceBundleURL,
            sourceSequenceFormat: sourceSequenceFormat,
            transformedFASTQ: nil,
            outputBundleURL: outputBundle,
            payload: .fullMixed(classification),
            temporaryPathRoots: nativeTemporaryPathRoots
        )
        try await writeDerivativeProvenance(
            workflowName: "lungfish fastq \(request.operationKindString) derivative",
            request: request,
            operation: operation,
            sourceBundleURL: sourceBundleURL,
            sourceSequenceFormat: sourceSequenceFormat,
            outputBundleURL: outputBundle,
            nativeExecutions: nativeProvenanceCollector.snapshot(),
            nativeReplayContext: nativeReplayContext,
            startedAt: provenanceStartedAt,
            completedAt: Date()
        )

        progress?("Created derived dataset: \(outputBundle.lastPathComponent) (\(classification.compositionLabel))")
        derivativeLogger.info("Created mixed-output derivative bundle at \(outputBundle.path, privacy: .public)")
        shouldCleanOutputBundleOnFailure = false
        return outputBundle
    }

    /// Creates output bundle URL for a request (used by mixed-output path which doesn't have an operation yet).
    func createOutputBundleURL(
        sourceBundleURL: URL,
        request: FASTQDerivativeRequest
    ) throws -> URL {
        let derivDir = try FASTQBundle.ensureDerivativesDirectory(in: sourceBundleURL)
        let suffix: String
        switch request {
        case .pairedEndMerge: suffix = "merge"
        case .pairedEndRepair: suffix = "repair"
        default: suffix = "derived"
        }
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let bundleName = "\(suffix)-\(shortID).\(FASTQBundle.directoryExtension)"
        return derivDir.appendingPathComponent(bundleName)
    }

}
