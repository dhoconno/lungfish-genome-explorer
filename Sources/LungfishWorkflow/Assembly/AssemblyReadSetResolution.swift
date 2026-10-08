// AssemblyReadSetResolution.swift - The reads of one assembly sample as pairs, merged reads and single reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. `lungfish-cli assemble` and
// the app's in-process assembly (Reassemble) both resolve their inputs here,
// so a sample reaches the assembler in the same files and roles through
// either one.

import Foundation
import LungfishIO

/// Why the inputs of an assembly could not be resolved.
public enum AssemblyReadSetResolutionError: LocalizedError, Sendable, Equatable {
    /// `--read-layout` states the layout of one file, and the bundle holds
    /// its pairs and single reads in several files.
    case readLayoutNamesABundleOfSeveralFiles(bundleName: String)
    /// The sample holds a set of reads the assemblers cannot take whole.
    case unsupportedReadSet(String)

    public var errorDescription: String? {
        switch self {
        case .readLayoutNamesABundleOfSeveralFiles(let bundleName):
            return "--read-layout describes one input file; \(bundleName) holds pairs and single reads in several files."
        case .unsupportedReadSet(let message):
            return message
        }
    }
}

/// The inputs of one assembly resolved to the files the assembler reads.
///
/// A sample that holds mate pairs and single reads together (a merge or
/// repair derivative, a file of merged reads followed by pairs, or a virtual
/// subset of either) resolves to an R1 file, an R2 file and the single-read
/// files, and ``inputRoles`` says which is which, so the assembler is handed
/// the pair as a pair (owner decision 1 of 2026-10-03). Every other sample
/// resolves as ``ResolvedSequenceInputs/resolveForAssembly(inputURLs:materializationDirectory:materializer:progress:)``
/// resolves it.
public struct AssemblyResolvedInputs: Sendable {
    /// The execution files and the inputs they came from.
    public let inputs: ResolvedSequenceInputs
    /// What each of ``ResolvedSequenceInputs/executionInputURLs`` is, or nil
    /// when the sample does not hold pairs and single reads together.
    public let inputRoles: [AssemblyInputRole]?
    /// The read-set plan behind ``inputRoles``.
    public let plan: ReadSetPlan?

    public init(inputs: ResolvedSequenceInputs, inputRoles: [AssemblyInputRole]? = nil, plan: ReadSetPlan? = nil) {
        self.inputs = inputs
        self.inputRoles = inputRoles
        self.plan = plan
    }

    /// The request the managed pipeline runs for these inputs, and the layout
    /// resolution it was built from.
    ///
    /// `pairedEnd` is the caller's `--paired` flag, and a bundle that holds
    /// the R1 and R2 files of one mate pair is assembled as pairs as well.
    /// `explicitLayout` is the recorded `--read-layout`, and the layout of the
    /// one execution file is resolved by
    /// ``AssemblyRunRequest/resolveInputLayout(tool:readType:pairedEnd:explicit:originalInputURLs:executionInputURLs:pooled:)``.
    public func request(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        projectName: String,
        outputDirectory: URL,
        pairedEnd: Bool,
        explicitLayout: FASTQInputLayout?,
        threads: Int,
        memoryGB: Int? = nil,
        minContigLength: Int? = nil,
        selectedProfileID: String? = nil,
        extraArguments: [String] = [],
        profileSelectionBasis: String? = nil
    ) -> (request: AssemblyRunRequest, layout: FASTQInputLayoutResolution?) {
        let pairedEnd = pairedEnd || inputs.resolvedAsMatePair
        let layout = AssemblyRunRequest.resolveInputLayout(
            tool: tool,
            readType: readType,
            pairedEnd: pairedEnd,
            explicit: explicitLayout,
            originalInputURLs: inputs.originalInputURLs,
            executionInputURLs: inputs.executionInputURLs,
            pooled: inputs.pooledLayoutResolution
        )
        let request = AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputs.executionInputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: threads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments,
            profileSelectionBasis: profileSelectionBasis,
            inputLayout: layout?.layout,
            inputRoles: inputRoles
        )
        return (request, layout)
    }

    /// The provenance steps that wrote the execution files of a sample that
    /// holds pairs and single reads: the materialization of a virtual bundle,
    /// then each split by fragment name with its record counts. Empty for
    /// every other sample, which has no step of its own.
    public func provenanceSteps(workflowVersion: String) throws -> [ProvenanceStep] {
        guard let plan, inputRoles != nil else { return [] }
        var steps: [ProvenanceStep] = []
        if plan.wasMaterialized, let materialized = plan.steps.first?.inputURLs.first {
            let command = CLISequenceInputMaterialization.materializationCommand(
                originalURL: plan.inputURL,
                executionURL: materialized
            )
            let startedAt = inputs.materializationStartedAt ?? plan.steps.first?.startedAt
            let endedAt = inputs.materializationEndedAt ?? startedAt
            steps.append(
                ProvenanceStep(
                    toolName: CLISequenceInputMaterialization.materializationToolName,
                    toolVersion: workflowVersion,
                    argv: command,
                    durableReplayArgv: command,
                    inputs: try AssemblyInputMaterialization.originalInputDescriptors(for: plan.inputURL),
                    outputs: [
                        try AssemblyInputMaterialization.executionInputDescriptor(
                            originalURL: plan.inputURL,
                            executionURL: materialized
                        ),
                    ],
                    exitStatus: 0,
                    wallTimeSeconds: startedAt.flatMap { start in endedAt.map { max(0, $0.timeIntervalSince(start)) } },
                    startedAt: startedAt,
                    completedAt: endedAt
                )
            )
        }
        for step in plan.steps {
            steps.append(try Self.provenanceStep(for: step, workflowVersion: workflowVersion))
        }
        return steps
    }

    /// The run parameters that record the read-set plan: the fragment counts
    /// by kind, the capability used and where the reads came from. Empty for
    /// a sample that does not hold pairs and single reads together.
    public var provenanceParameters: [String: ParameterValue] {
        inputRoles == nil ? [:] : (plan?.provenanceParameters ?? [:])
    }

    private static func provenanceStep(for step: ReadSetStep, workflowVersion: String) throws -> ProvenanceStep {
        func descriptors(_ urls: [URL], role: FileRole) throws -> [ProvenanceFileDescriptor] {
            try urls.map { try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: role) }
        }
        return ProvenanceStep(
            toolName: step.toolName,
            toolVersion: workflowVersion,
            argv: step.command,
            resolvedOptions: [
                "pairs": .integer(step.pairCount),
                "singleReads": .integer(step.singleReadCount),
            ],
            inputs: try descriptors(step.inputURLs, role: .input),
            outputs: try descriptors(step.outputURLs, role: .output),
            exitStatus: 0,
            wallTimeSeconds: max(0, step.endedAt.timeIntervalSince(step.startedAt)),
            startedAt: step.startedAt,
            completedAt: step.endedAt
        )
    }
}

public enum AssemblyReadSetResolution {

    /// Resolves `inputURLs` to the files `tool` reads.
    ///
    /// A short-read assembler given one sample (one bundle, or one loose
    /// file) and no `--paired` flag reads the sample as ``ReadSetResolver``
    /// plans it. A sample that holds pairs and single reads comes out as an
    /// R1 file, an R2 file and the single-read files, each with its role.
    /// Every other input resolves as
    /// ``ResolvedSequenceInputs/resolveForAssembly(inputURLs:materializationDirectory:materializer:progress:)``
    /// resolves it, so a sample of only single reads or only pairs keeps its
    /// command.
    ///
    /// `explicitLayout` is the recorded `--read-layout`. It states the layout
    /// of one file, so it overrides a loose file and a bundle's one file, and
    /// it is refused for a bundle whose pairs and single reads are in several
    /// files, as it is for a bundle that holds the R1 and R2 files of a mate
    /// pair.
    public static func resolve(
        inputURLs: [URL],
        tool: AssemblyTool,
        pairedEnd: Bool,
        explicitLayout: FASTQInputLayout?,
        materializationDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> AssemblyResolvedInputs {
        let sampleURLs = AssemblyInputSamples.sampleURLs(inputURLs)
        for sampleURL in sampleURLs where !AssemblyInputMaterialization.requiresMaterialization(sampleURL) {
            guard SequenceInputResolver.resolvePrimarySequenceURL(for: sampleURL) != nil else {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(sampleURL.path)
            }
        }
        // The plan and the resolution after it both materialize a virtual
        // bundle, and the file is written once.
        let materializer = MaterializationMemo(base: materializer)
        if let capability = ReadPairingCapabilityRegistry.capability(for: "assemble.\(tool.rawValue)"),
           capability.kind == .bothInOneRun,
           !pairedEnd,
           sampleURLs.count == 1,
           let sampleURL = sampleURLs.first {
            let runClock = ProvenanceRunClock()
            let plan = try await ReadSetResolver(
                materializationDirectory: materializationDirectory,
                materializer: materializer
            ).plan(for: sampleURL, capability: capability, progress: progress)
            // A virtual subset of a merge or repair derivative reads as mixed
            // from its lineage, though the subset may hold only pairs or only
            // single reads. Only a sample that still holds both after the
            // split is assembled as a pair with single reads. Any other
            // sample resolves as it always did.
            do {
                if plan.sampleHoldsPairsAndSingleReads, !plan.matePairs.isEmpty, !plan.singleReads.isEmpty,
                   let resolved = try resolved(plan, sampleURL: sampleURL, explicitLayout: explicitLayout, runClock: runClock) {
                    return resolved
                }
            } catch {
                removeSplitFiles(of: plan)
                throw error
            }
            removeSplitFiles(of: plan)
        }
        return AssemblyResolvedInputs(
            inputs: try await ResolvedSequenceInputs.resolveForAssembly(
                inputURLs: inputURLs,
                materializationDirectory: materializationDirectory,
                materializer: materializer,
                progress: progress
            )
        )
    }

    /// Removes the files the plan's splits wrote, for a sample the run does
    /// not assemble from them.
    private static func removeSplitFiles(of plan: ReadSetPlan) {
        for step in plan.steps {
            for outputURL in step.outputURLs { try? FileManager.default.removeItem(at: outputURL) }
        }
    }

    /// The execution files of a plan that holds pairs and single reads, or
    /// nil when `explicitLayout` states the layout of one file as something
    /// else than mixed reads, so the file resolves as it always did.
    private static func resolved(
        _ plan: ReadSetPlan,
        sampleURL: URL,
        explicitLayout: FASTQInputLayout?,
        runClock: ProvenanceRunClock
    ) throws -> AssemblyResolvedInputs? {
        if let explicitLayout {
            // The roles of a merge or repair derivative are separate files.
            if plan.sourceLayout == .mixedDerivative {
                throw AssemblyReadSetResolutionError.readLayoutNamesABundleOfSeveralFiles(bundleName: sampleURL.lastPathComponent)
            }
            if explicitLayout != .mixedMergedAndPairs { return nil }
        }
        guard plan.runs.count == 1, let run = plan.runs.first, run.mixedStreams.isEmpty,
              run.matePairs.count == 1, case .separate(let r1, let r2) = run.matePairs[0].files else {
            throw AssemblyReadSetResolutionError.unsupportedReadSet(
                "\(sampleURL.lastPathComponent) holds pairs and single reads in a layout an assembler cannot take whole, \(plan.matePairs.count) sets of mate files. Nothing is assembled on part of a sample."
            )
        }
        let singleReads = run.singleReads
        let wroteFiles = plan.wasMaterialized || !plan.steps.isEmpty
        let endedAt = runClock.now
        return AssemblyResolvedInputs(
            inputs: ResolvedSequenceInputs(
                inputs: [
                    ResolvedSequenceInputs.Input(
                        originalURL: sampleURL,
                        executionURLs: [r1, r2] + singleReads.map(\.url),
                        wasMaterialized: wroteFiles
                    ),
                ],
                materializationStartedAt: wroteFiles ? runClock.startedAt : nil,
                materializationEndedAt: wroteFiles ? endedAt : nil
            ),
            inputRoles: [.mateR1, .mateR2] + singleReads.map { $0.role == .merged ? .merged : .single },
            plan: plan
        )
    }
}

/// Hands a bundle's materialized file back when it was already written, so
/// the read-set plan and the resolution that follows it share one file.
private actor MaterializationMemo: CLISequenceInputMaterializing {
    private let base: any CLISequenceInputMaterializing & Sendable
    private var written: [String: URL] = [:]

    init(base: any CLISequenceInputMaterializing & Sendable) {
        self.base = base
    }

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let key = "\(bundleURL.standardizedFileURL.path)\n\(tempDirectory.standardizedFileURL.path)"
        if let url = written[key], FileManager.default.fileExists(atPath: url.path) { return url }
        let url = try await base.materialize(bundleURL: bundleURL, tempDirectory: tempDirectory, progress: progress)
        written[key] = url
        return url
    }
}
