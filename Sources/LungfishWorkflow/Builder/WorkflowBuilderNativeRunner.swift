// WorkflowBuilderNativeRunner.swift - Native Workflow Builder FASTQ execution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public protocol WorkflowBuilderRecipeExecuting: Sendable {
    func execute(recipe: Recipe, input: StepInput, context: StepContext) async throws -> RecipeExecutionResult
}

extension RecipeEngine: WorkflowBuilderRecipeExecuting {}

public struct WorkflowBuilderNativeRunResult: Sendable {
    public let plan: WorkflowBuilderExecutablePlan
    public let outputBundleURL: URL
    public let outputFASTQURL: URL
    public let planURL: URL
    public let provenanceURL: URL
    public let recipeResult: RecipeExecutionResult
}

public enum WorkflowBuilderNativeRunnerError: Error, LocalizedError, Sendable, Equatable {
    case noFASTQPayload(String)
    case ambiguousFASTQPayload(String)
    case unsupportedOutputFormat(RecipeFileFormat)

    public var errorDescription: String? {
        switch self {
        case .noFASTQPayload(let path):
            return "No FASTQ payload was found in bundle: \(path)"
        case .ambiguousFASTQPayload(let path):
            return "Could not resolve a single FASTQ input layout for bundle: \(path)"
        case .unsupportedOutputFormat(let format):
            return "Workflow Builder runner cannot bundle recipe output format: \(format.rawValue)"
        }
    }
}

public struct WorkflowBuilderNativeRunner: Sendable {
    private let recipeExecutor: any WorkflowBuilderRecipeExecuting
    private let nativeToolRunner: NativeToolRunner
    private let provenanceWriteInterceptor: (@Sendable () throws -> Void)?

    public init(
        recipeExecutor: any WorkflowBuilderRecipeExecuting = RecipeEngine(),
        nativeToolRunner: NativeToolRunner = .shared
    ) {
        self.recipeExecutor = recipeExecutor
        self.nativeToolRunner = nativeToolRunner
        self.provenanceWriteInterceptor = nil
    }

    init(
        recipeExecutor: any WorkflowBuilderRecipeExecuting,
        nativeToolRunner: NativeToolRunner = .shared,
        provenanceWriteInterceptor: (@Sendable () throws -> Void)?
    ) {
        self.recipeExecutor = recipeExecutor
        self.nativeToolRunner = nativeToolRunner
        self.provenanceWriteInterceptor = provenanceWriteInterceptor
    }

    public func run(
        graph: WorkflowGraph,
        projectURL: URL,
        runDirectoryURL: URL,
        workflowBundleURL: URL,
        argv: [String],
        threads: Int = 4
    ) async throws -> WorkflowBuilderNativeRunResult {
        let startedAt = Date()
        let plan = try WorkflowBuilderPlanCompiler().compile(
            graph: graph,
            projectURL: projectURL,
            runDirectoryURL: runDirectoryURL,
            lungfishCLIExecutable: argv.first ?? "lungfish-cli"
        )
        let planURL = runDirectoryURL.appendingPathComponent("builder-plan.json")
        try writePlan(plan, to: planURL)

        let input = try resolveStepInput(from: plan.inputBundleURL)
        try RecipeEngine().validate(recipe: plan.recipe, inputFormat: input.format)

        let workspace = runDirectoryURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sampleName = plan.inputBundleURL.deletingPathExtension().lastPathComponent
        let context = StepContext(
            workspace: workspace,
            threads: threads,
            sampleName: sampleName,
            runner: nativeToolRunner,
            progress: { _, _ in }
        )

        let recipeResult = try await recipeExecutor.execute(recipe: plan.recipe, input: input, context: context)
        let outputBundleURL = try availableOutputBundleURL(for: plan)
        let stagingOutputBundleURL = stagingOutputBundleURL(for: outputBundleURL)
        let provenanceURL = outputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let outputFiles: [URL]
        do {
            let stagedOutputFiles = try await materializeOutputBundle(
                recipeOutput: recipeResult.output,
                plan: plan,
                input: input,
                outputBundleURL: stagingOutputBundleURL,
                recordedOutputBundleURL: outputBundleURL,
                stepRecords: recipeResult.stepRecords
            )
            outputFiles = stagedOutputFiles.map { outputBundleURL.appendingPathComponent($0.lastPathComponent) }
            guard !outputFiles.isEmpty else {
                throw WorkflowBuilderNativeRunnerError.unsupportedOutputFormat(recipeResult.output.format)
            }

            try writeProvenance(
                plan: plan,
                workflowBundleURL: workflowBundleURL,
                argv: argv,
                threads: threads,
                input: input,
                outputBundleURL: outputBundleURL,
                outputFiles: outputFiles,
                actualOutputBundleURL: stagingOutputBundleURL,
                actualOutputFiles: stagedOutputFiles,
                planURL: planURL,
                provenanceURL: stagingOutputBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
                recipeResult: recipeResult,
                startedAt: startedAt
            )
            try FileManager.default.moveItem(at: stagingOutputBundleURL, to: outputBundleURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingOutputBundleURL)
            try? FileManager.default.removeItem(at: outputBundleURL)
            throw error
        }

        return WorkflowBuilderNativeRunResult(
            plan: plan,
            outputBundleURL: outputBundleURL,
            outputFASTQURL: outputFiles[0],
            planURL: planURL,
            provenanceURL: provenanceURL,
            recipeResult: recipeResult
        )
    }

    private func resolveStepInput(from bundleURL: URL) throws -> StepInput {
        if let paired = FASTQBundle.pairedFASTQURLs(forDerivedBundle: bundleURL) {
            return StepInput(r1: paired.r1, r2: paired.r2, format: .pairedR1R2)
        }

        if let classified = FASTQBundle.classifiedFileURLs(for: bundleURL),
           let r1 = classified[.pairedR1],
           let r2 = classified[.pairedR2] {
            return StepInput(r1: r1, r2: r2, format: .pairedR1R2)
        }

        let fastqFiles = try fastqPayloadFiles(in: bundleURL)
        guard !fastqFiles.isEmpty else {
            throw WorkflowBuilderNativeRunnerError.noFASTQPayload(bundleURL.path)
        }
        if fastqFiles.count == 1 {
            let pairingMode = FASTQMetadataStore.load(for: fastqFiles[0])?.ingestion?.pairingMode
            return StepInput(
                r1: fastqFiles[0],
                format: pairingMode == .interleaved ? .interleaved : .single
            )
        }

        let pairs = FASTQBatchImporter.detectPairs(from: fastqFiles)
        if pairs.count == 1, let r2 = pairs[0].r2 {
            return StepInput(r1: pairs[0].r1, r2: r2, format: .pairedR1R2)
        }

        throw WorkflowBuilderNativeRunnerError.ambiguousFASTQPayload(bundleURL.path)
    }

    private func fastqPayloadFiles(in bundleURL: URL) throws -> [URL] {
        if let manifest = try? FASTQSourceFileManifest.load(from: bundleURL) {
            return manifest.resolveFileURLs(relativeTo: bundleURL)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { FASTQBundle.isFASTQFileURL($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func availableOutputBundleURL(for plan: WorkflowBuilderExecutablePlan) throws -> URL {
        let root = plan.runDirectoryURL.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let baseName = "\(plan.inputBundleURL.deletingPathExtension().lastPathComponent)-\(slug(for: plan.workflowName))"
        let base = root.appendingPathComponent("\(baseName).lungfishfastq", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        for index in 2...999 {
            let candidate = root.appendingPathComponent("\(baseName)-\(index).lungfishfastq", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: base.path])
    }

    private func stagingOutputBundleURL(for outputBundleURL: URL) -> URL {
        outputBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputBundleURL.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
    }

    private func materializeOutputBundle(
        recipeOutput: StepOutput,
        plan: WorkflowBuilderExecutablePlan,
        input: StepInput,
        outputBundleURL: URL,
        recordedOutputBundleURL: URL,
        stepRecords: [RecipeStepResult]
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: outputBundleURL, withIntermediateDirectories: true)
        let sampleSlug = slug(for: plan.inputBundleURL.deletingPathExtension().lastPathComponent)
        let copiedFiles: [URL]
        let payload: FASTQDerivativePayload
        let readClassification: ReadClassification?
        let pairingMode: IngestionMetadata.PairingMode

        switch recipeOutput.format {
        case .single, .interleaved:
            let output = outputBundleURL.appendingPathComponent(
                "\(sampleSlug)\(fastqOutputSuffix(for: recipeOutput.r1))"
            )
            try copyReplacing(recipeOutput.r1, to: output)
            copiedFiles = [output]
            payload = .full(fastqFilename: output.lastPathComponent)
            readClassification = nil
            pairingMode = recipeOutput.format == .interleaved ? .interleaved : .singleEnd

        case .pairedR1R2:
            guard let r2 = recipeOutput.r2 else {
                throw WorkflowBuilderNativeRunnerError.unsupportedOutputFormat(recipeOutput.format)
            }
            let outR1 = outputBundleURL.appendingPathComponent(
                "\(sampleSlug)_R1\(fastqOutputSuffix(for: recipeOutput.r1))"
            )
            let outR2 = outputBundleURL.appendingPathComponent(
                "\(sampleSlug)_R2\(fastqOutputSuffix(for: r2))"
            )
            try copyReplacing(recipeOutput.r1, to: outR1)
            try copyReplacing(r2, to: outR2)
            copiedFiles = [outR1, outR2]
            payload = .fullPaired(r1Filename: outR1.lastPathComponent, r2Filename: outR2.lastPathComponent)
            readClassification = nil
            pairingMode = .pairedEnd

        case .merged:
            var entries: [ReadClassification.FileEntry] = []
            let merged = outputBundleURL.appendingPathComponent(
                "\(sampleSlug)_merged\(fastqOutputSuffix(for: recipeOutput.r1))"
            )
            try copyReplacing(recipeOutput.r1, to: merged)
            entries.append(.init(filename: merged.lastPathComponent, role: .merged, readCount: recipeOutput.readCount ?? 0))
            var urls = [merged]
            if let r2 = recipeOutput.r2 {
                let unmergedR1 = outputBundleURL.appendingPathComponent(
                    "\(sampleSlug)_unmerged_R1\(fastqOutputSuffix(for: r2))"
                )
                try copyReplacing(r2, to: unmergedR1)
                urls.append(unmergedR1)
                entries.append(.init(filename: unmergedR1.lastPathComponent, role: .pairedR1, readCount: 0))
            }
            if let r3 = recipeOutput.r3 {
                let unmergedR2 = outputBundleURL.appendingPathComponent(
                    "\(sampleSlug)_unmerged_R2\(fastqOutputSuffix(for: r3))"
                )
                try copyReplacing(r3, to: unmergedR2)
                urls.append(unmergedR2)
                entries.append(.init(filename: unmergedR2.lastPathComponent, role: .pairedR2, readCount: 0))
            }
            copiedFiles = urls
            let classification = ReadClassification(files: entries)
            payload = .fullMixed(classification)
            readClassification = classification
            pairingMode = .interleaved
            try ReadManifest(classification: classification, sourceOperation: "workflow-builder").save(to: outputBundleURL)
        }

        let statistics = try await cachedStatistics(for: copiedFiles[0], readCount: recipeOutput.readCount)
        let checksum = try PayloadChecksum.sha256Hex(fileAt: copiedFiles[0])
        let sourceManifest = FASTQBundle.loadDerivedManifest(in: plan.inputBundleURL)
        let rootBundleURL = sourceManifest
            .map { FASTQBundle.resolveBundle(relativePath: $0.rootBundleRelativePath, from: plan.inputBundleURL) }
            ?? plan.inputBundleURL
        let rootFASTQFilename = sourceManifest?.rootFASTQFilename ?? input.r1.lastPathComponent
        let lineage = (sourceManifest?.lineage ?? []) + derivativeOperations(
            for: plan.steps,
            stepRecords: stepRecords
        )
        let operation = lineage.last ?? FASTQDerivativeOperation(kind: .lengthFilter)

        let manifest = FASTQDerivedBundleManifest(
            name: recordedOutputBundleURL.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: relativeBundlePath(for: plan.inputBundleURL, from: recordedOutputBundleURL),
            rootBundleRelativePath: relativeBundlePath(for: rootBundleURL, from: recordedOutputBundleURL),
            rootFASTQFilename: rootFASTQFilename,
            payload: payload,
            lineage: lineage,
            operation: operation,
            cachedStatistics: statistics,
            pairingMode: pairingMode,
            readClassification: readClassification,
            sequenceFormat: .fastq,
            payloadChecksums: PayloadChecksum(checksums: Dictionary(uniqueKeysWithValues: try copiedFiles.map { url in
                (url.lastPathComponent, try PayloadChecksum.sha256Hex(fileAt: url))
            })),
            materializationState: .materialized(checksum: checksum)
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundleURL)

        let metadataURL = copiedFiles[0]
        var metadata = PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(
            isClumpified: false,
            isCompressed: copiedFiles[0].pathExtension.lowercased() == "gz",
            pairingMode: pairingMode,
            qualityBinning: plan.recipe.qualityBinning?.rawValue,
            originalFilenames: [input.r1.lastPathComponent] + (input.r2.map { [$0.lastPathComponent] } ?? []),
            ingestionDate: Date(),
            originalSizeBytes: fileSizeSum([input.r1, input.r2, input.r3].compactMap { $0 }),
            recipeApplied: RecipeAppliedInfo(
                recipeID: plan.recipe.id,
                recipeName: plan.recipe.name,
                stepResults: stepRecords
            )
        )
        FASTQMetadataStore.save(metadata, for: metadataURL)

        return copiedFiles
    }

    private func derivativeOperations(
        for steps: [WorkflowBuilderExecutableStep],
        stepRecords: [RecipeStepResult]
    ) -> [FASTQDerivativeOperation] {
        let recordsByBuilderStep = executionRecordsByBuilderStep(steps: steps, stepRecords: stepRecords)
        return steps.enumerated().map { index, step in
            let record = recordsByBuilderStep.indices.contains(index) ? recordsByBuilderStep[index] : nil
            let command = step.argv.joined(separator: " ")
            switch step.nodeType {
            case .fastpDedup:
                return FASTQDerivativeOperation(
                    kind: .deduplicate,
                    toolUsed: record?.tool ?? "fastp",
                    toolVersion: record?.toolVersion,
                    toolCommand: record?.commandLine ?? command
                )
            case .fastpTrim:
                return FASTQDerivativeOperation(
                    kind: .fastpTrim,
                    qualityThreshold: step.parameters["quality"].flatMap(Int.init),
                    windowSize: step.parameters["window"].flatMap(Int.init),
                    adapterMode: step.parameters["detectAdapter"] == "true" ? .autoDetect : nil,
                    toolUsed: record?.tool ?? "fastp",
                    toolVersion: record?.toolVersion,
                    toolCommand: record?.commandLine ?? command
                )
            case .deaconHumanScrub:
                return FASTQDerivativeOperation(
                    kind: .humanReadScrub,
                    humanScrubRemoveReads: true,
                    humanScrubDatabaseID: step.parameters["database"],
                    toolUsed: record?.tool ?? "deacon",
                    toolVersion: record?.toolVersion,
                    toolCommand: record?.commandLine ?? command
                )
            case .fastpMerge:
                return FASTQDerivativeOperation(
                    kind: .pairedEndMerge,
                    mergeMinOverlap: step.parameters["minOverlap"].flatMap(Int.init),
                    toolUsed: record?.tool ?? "fastp",
                    toolVersion: record?.toolVersion,
                    toolCommand: record?.commandLine ?? command
                )
            case .seqkitLengthFilter:
                return FASTQDerivativeOperation(
                    kind: .lengthFilter,
                    minLength: step.parameters["minLength"].flatMap(Int.init),
                    maxLength: step.parameters["maxLength"].flatMap(Int.init),
                    toolUsed: record?.tool ?? "seqkit",
                    toolVersion: record?.toolVersion,
                    toolCommand: record?.commandLine ?? command
                )
            case .sampleInput, .fastqInput, .fastqBundleInput, .fastaInput, .bamInput, .sampleSheet, .qualityControl, .trimming, .alignment, .variantCalling, .quantification, .assembly, .report, .export, .projectOutput:
                return FASTQDerivativeOperation(kind: .lengthFilter, toolCommand: command)
            }
        }
    }

    private func executionRecordsByBuilderStep(
        steps: [WorkflowBuilderExecutableStep],
        stepRecords: [RecipeStepResult]
    ) -> [RecipeStepResult?] {
        var records: [RecipeStepResult?] = []
        var stepIndex = 0
        var recordIndex = 0

        while stepIndex < steps.count {
            if isFusibleFastpBuilderStep(steps[stepIndex]) {
                var fusionEnd = stepIndex + 1
                while fusionEnd < steps.count, isFusibleFastpBuilderStep(steps[fusionEnd]) {
                    fusionEnd += 1
                }
                let record = stepRecords.indices.contains(recordIndex) ? stepRecords[recordIndex] : nil
                records.append(contentsOf: Array(repeating: record, count: fusionEnd - stepIndex))
                recordIndex += 1
                stepIndex = fusionEnd
            } else {
                let record = stepRecords.indices.contains(recordIndex) ? stepRecords[recordIndex] : nil
                records.append(record)
                recordIndex += 1
                stepIndex += 1
            }
        }

        return records
    }

    private func isFusibleFastpBuilderStep(_ step: WorkflowBuilderExecutableStep) -> Bool {
        switch step.nodeType {
        case .fastpDedup, .fastpTrim:
            return true
        case .sampleInput, .fastqInput, .fastqBundleInput, .fastaInput, .bamInput, .sampleSheet, .qualityControl, .trimming, .alignment, .variantCalling, .quantification, .assembly, .report, .export, .projectOutput, .deaconHumanScrub, .fastpMerge, .seqkitLengthFilter:
            return false
        }
    }

    private func writeProvenance(
        plan: WorkflowBuilderExecutablePlan,
        workflowBundleURL: URL,
        argv: [String],
        threads: Int,
        input: StepInput,
        outputBundleURL: URL,
        outputFiles: [URL],
        actualOutputBundleURL: URL,
        actualOutputFiles: [URL],
        planURL: URL,
        provenanceURL: URL,
        recipeResult: RecipeExecutionResult,
        startedAt: Date
    ) throws {
        let inputURLs = [input.r1, input.r2, input.r3].compactMap { $0 }
        let inputRecords = inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) }
        let outputRecords = zip(actualOutputFiles, outputFiles).map { actualURL, recordedURL in
            provenanceFileRecord(actualURL: actualURL, recordedURL: recordedURL, format: .fastq, role: .output)
        }
        let outputBundleRecord = provenanceFileRecord(
            actualURL: actualOutputBundleURL,
            recordedURL: outputBundleURL,
            format: .unknown,
            role: .output
        )
        let planRecord = ProvenanceRecorder.fileRecord(url: planURL, format: .json, role: .output)

        var steps: [StepExecution] = []
        var dependencyIDs: [UUID] = []
        for (index, record) in recipeResult.stepRecords.enumerated() {
            let startTime = startedAt.addingTimeInterval(Double(index) * 0.001)
            let step = StepExecution(
                toolName: record.tool,
                toolVersion: record.toolVersion ?? "unknown",
                command: record.commandArguments ?? [record.tool],
                inputs: index == 0 ? inputRecords : [],
                outputs: index == recipeResult.stepRecords.count - 1 ? outputRecords : [],
                exitCode: 0,
                wallTime: record.durationSeconds,
                stderr: nil,
                dependsOn: dependencyIDs,
                startTime: startTime,
                endTime: startTime.addingTimeInterval(record.durationSeconds)
            )
            steps.append(step)
            dependencyIDs = [step.id]
        }

        let completedAt = Date()
        let workflowGraphURL = workflowGraphURL(for: workflowBundleURL)
        let wrapperStep = StepExecution(
            toolName: "lungfish-cli workflow builder-run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: argv,
            inputs: [
                ProvenanceRecorder.fileRecord(url: workflowGraphURL, format: .json, role: .input),
                ProvenanceRecorder.fileRecord(url: plan.inputBundleURL, format: .unknown, role: .input),
            ],
            outputs: outputRecords + [outputBundleRecord, planRecord],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            dependsOn: dependencyIDs,
            startTime: startedAt,
            endTime: completedAt
        )
        steps.append(wrapperStep)

        let run = WorkflowRun(
            name: plan.workflowName,
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: steps,
            parameters: provenanceParameters(
                plan: plan,
                workflowBundleURL: workflowBundleURL,
                threads: threads,
                outputBundleURL: outputBundleURL
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try provenanceWriteInterceptor?()
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
    }

    private func provenanceFileRecord(
        actualURL: URL,
        recordedURL: URL,
        format: FileFormat,
        role: FileRole
    ) -> FileRecord {
        let actual = ProvenanceRecorder.fileRecord(url: actualURL, format: format, role: role)
        return FileRecord(
            path: recordedURL.path,
            sha256: actual.sha256,
            sizeBytes: actual.sizeBytes,
            format: actual.format,
            role: actual.role
        )
    }

    private func workflowGraphURL(for workflowURL: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workflowURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return workflowURL.appendingPathComponent("graph.json")
        }
        return workflowURL
    }

    private func provenanceParameters(
        plan: WorkflowBuilderExecutablePlan,
        workflowBundleURL: URL,
        threads: Int,
        outputBundleURL: URL
    ) -> [String: ParameterValue] {
        [
            "workflowName": .string(plan.workflowName),
            "workflowGraphID": .string(plan.graphID.uuidString),
            "workflowBundle": .file(workflowBundleURL),
            "project": .file(plan.projectURL),
            "runDirectory": .file(plan.runDirectoryURL),
            "inputBundle": .file(plan.inputBundleURL),
            "outputBundle": .file(outputBundleURL),
            "recipeID": .string(plan.recipe.id),
            "recipeName": .string(plan.recipe.name),
            "recipeRequiredInput": .string(plan.recipe.requiredInput.rawValue),
            "qualityBinning": .string(plan.recipe.qualityBinning?.rawValue ?? "none"),
            "threads": .integer(threads),
            "operations": .array(plan.steps.map { .string($0.operation) }),
            "resolvedDefaults": .dictionary([
                "runner": .string("native-recipe-engine"),
                "failurePolicy": .string("stop-on-first-failing-step"),
            ]),
        ]
    }

    private func writePlan(_ plan: WorkflowBuilderExecutablePlan, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url, options: .atomic)
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func fastqOutputSuffix(for source: URL) -> String {
        let lowercased = source.lastPathComponent.lowercased()
        if lowercased.hasSuffix(".fastq.gz") || lowercased.hasSuffix(".fq.gz") {
            return ".fastq.gz"
        }
        return ".fastq"
    }

    private func cachedStatistics(for fastqURL: URL, readCount: Int?) async throws -> FASTQDatasetStatistics {
        let reader = FASTQReader(validateSequence: false)
        do {
            return try await reader.computeStatistics(from: fastqURL, sampleLimit: 0).statistics
        } catch {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fastqURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return .placeholder(readCount: readCount ?? 0, baseCount: size)
        }
    }

    private func relativeBundlePath(for targetURL: URL, from bundleURL: URL) -> String {
        FASTQBundle.projectRelativePath(for: targetURL, from: bundleURL)
            ?? Self.relativePath(from: bundleURL, to: targetURL)
            ?? targetURL.standardizedFileURL.path
    }

    private static func relativePath(from source: URL, to target: URL) -> String? {
        let sourceComponents = source.deletingLastPathComponent().standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var index = 0
        while index < sourceComponents.count,
              index < targetComponents.count,
              sourceComponents[index] == targetComponents[index] {
            index += 1
        }
        let up = Array(repeating: "..", count: sourceComponents.count - index)
        let down = targetComponents[index...]
        let components = up + down
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func slug(for value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        return slug.isEmpty ? "workflow-output" : slug
    }

    private func fileSizeSum(_ urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }
}
