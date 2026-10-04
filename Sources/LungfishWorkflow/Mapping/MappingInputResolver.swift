// MappingInputResolver.swift - The reads a mapper is handed, for the Map Reads window and lungfish-cli map alike
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md is the contract. The window and
// `lungfish-cli map` both call `MappingInputResolver.resolve`, so a recorded
// command pairs, splits and interleaves a sample exactly as the window did.

import Foundation
import LungfishIO

/// The inputs of one mapping run after resolution.
public struct MappingResolvedInputs: Sendable {
    /// The request the pipeline runs: the files the mapper reads, the input
    /// each came from, whether they pair, the layout and, for bowtie2 and
    /// BBMap on a sample of pairs and single reads, its read sets.
    public let request: MappingRunRequest
    public let layoutResolution: FASTQInputLayoutResolution
    /// The files written for the run (a materialized virtual bundle or a
    /// concatenation) by the input they came from. `lungfish-cli map`
    /// records them before it maps.
    public let sequenceInputs: ResolvedSequenceInputs
    /// The read-set plan whose runs feed the mapper when the sample holds
    /// pairs and single reads, else nil. The pipeline records its steps.
    public let readSetPlan: ReadSetPlan?
}

public enum MappingInputResolverError: LocalizedError, Sendable, Equatable {
    /// `--read-layout` describes one file, and the bundle holds R1 and R2 files.
    case layoutForPairedBundle(name: String)
    /// The read-set plan has a shape a mapper cannot be handed.
    case unsupportedReadSetPlan(String)

    public var errorDescription: String? {
        switch self {
        case .layoutForPairedBundle(let name):
            return "--read-layout describes one input file; \(name) holds R1 and R2 files."
        case .unsupportedReadSetPlan(let detail):
            return "The reads cannot be handed to the mapper: \(detail)"
        }
    }
}

/// Decides which files a mapper reads and how they pair, for the Map Reads
/// window and `lungfish-cli map` alike.
///
/// One bundle input is planned by ``ReadSetResolver`` with the mapper's
/// declared ``ReadPairingCapability``. When the sample holds pairs and single
/// reads, the plan's runs feed the mapper: minimap2 `-x sr` and bwa-mem2 `-p`
/// read one stream with each R1 record followed by its R2 record and the
/// single reads after them, bowtie2 reads `-1 R1 -2 R2 -U singles`, and BBMap
/// maps the pairs and each file of single reads in separate runs. Any other
/// input resolves through ``ResolvedSequenceInputs`` as before, with the
/// pairing the plan found, so a sample of only single reads or only pairs
/// keeps its command. Loose files pair only when the caller says so
/// (`--paired`, or the window's two loose files named as mates), and two
/// bundles are never paired with each other.
public enum MappingInputResolver {

    /// The capability `tool` takes reads with in `modeID`, or nil when the
    /// run maps every record on its own (minimap2's long-read and assembly
    /// presets, BBMap's PacBio mode).
    public static func readPairingCapability(tool: MappingTool, modeID: String) -> ReadPairingCapability? {
        switch tool {
        case .minimap2 where modeID != MappingMode.defaultShortRead.id:
            return nil
        case .bbmap where modeID == MappingMode.bbmapPacBio.id:
            return nil
        default:
            return ReadPairingCapabilityRegistry.capability(for: tool.fastqConsumerDeclaration.consumerID)
        }
    }

    /// The R1 and R2 file when `inputURLs` are exactly two loose files,
    /// outside any bundle, named as the mates of one sample
    /// (``MatePairFileNaming``). The Map Reads window maps such files as
    /// pairs and records `--paired`. Two bundles are never paired by name,
    /// because each was imported and reordered on its own, so their records
    /// need not correspond by position.
    public static func looseMatePair(in inputURLs: [URL]) -> (r1: URL, r2: URL)? {
        guard inputURLs.count == 2,
              inputURLs.allSatisfy({ SequenceInputResolver.enclosingFASTQBundleURL(for: $0) == nil && !FASTQBundle.isBundleURL($0) })
        else { return nil }
        return MatePairFileNaming.matePair(in: inputURLs)
    }

    /// Resolves the inputs `request` names into the request the pipeline runs.
    ///
    /// - Parameters:
    ///   - request: the run as the user chose it. `inputFASTQURLs` are the
    ///     inputs as chosen, and `pairedEnd` binds two inputs as R1 and R2
    ///     (`--paired`).
    ///   - explicitLayout: `--read-layout` for one input file, which turns the
    ///     read-set plan off. A bundle that holds R1 and R2 files refuses it.
    ///   - materializer: writes a virtual bundle's reads. Each bundle is
    ///     materialized once per call.
    public static func resolve(
        request: MappingRunRequest,
        explicitLayout: FASTQInputLayout? = nil,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MappingResolvedInputs {
        let inputURLs = request.inputFASTQURLs
        // A loose file that is not a readable sequence file and a
        // container-only demultiplex group are refused before anything is written.
        for inputURL in inputURLs {
            if let message = CLISequenceInputMaterialization.unsupportedSequenceInputMessage(for: inputURL, operationName: "mapping") {
                throw CLISequenceInputMaterializationError.unsupportedSequenceInput(message)
            }
            if SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) == nil,
               SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) == nil {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(inputURL.standardizedFileURL.path)
            }
        }
        let directory = MappingResultLayoutService.inputMaterializationDirectory(in: request.outputDirectory)
        let reusing = ReusingMaterializer(base: materializer)

        var bundlePlan: (bundleURL: URL, plan: ReadSetPlan)?
        if inputURLs.count == 1, let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURLs[0]) {
            let capability = explicitLayout == nil ? readPairingCapability(tool: request.tool, modeID: request.modeID) : nil
            // A tool that maps every record on its own is planned with the
            // capability that writes nothing, only to learn how the sample pairs.
            let plan = try await ReadSetResolver(materializationDirectory: directory, materializer: reusing)
                .plan(for: inputURLs[0], capability: capability ?? .singleReadsOnly, progress: progress)
            if explicitLayout != nil, [.pairedFiles, .mixedDerivative, .pairedFilesWithSingleReads].contains(plan.sourceLayout) {
                throw MappingInputResolverError.layoutForPairedBundle(name: inputURLs[0].lastPathComponent)
            }
            if capability != nil, plan.sampleHoldsPairsAndSingleReads {
                return try await readSetResolution(request: request, plan: plan, bundleURL: bundleURL, materializer: reusing)
            }
            bundlePlan = (bundleURL, plan)
        }

        var resolved = try await ResolvedSequenceInputs.resolve(
            inputURLs: inputURLs,
            materializationDirectory: directory,
            materializer: reusing,
            concatenateUnpairedFiles: true,
            progress: progress
        )
        var pairedEnd = request.pairedEnd && resolved.executionInputURLs.count == 2
        if let bundlePlan, resolved.resolvedAsMatePair {
            if bundlePlan.plan.sourceLayout == .pairedFiles {
                pairedEnd = true
            } else if let concatenation = try ResolvedSequenceInputs.concatenateMultiFileBundle(bundlePlan.bundleURL, into: directory) {
                // The plan reads the two chunks as single reads (a Nanopore
                // or PacBio import, or no recorded short-read platform), so
                // they are pooled like any chunked root, never paired by name.
                resolved = ResolvedSequenceInputs(
                    inputs: [ResolvedSequenceInputs.Input(
                        originalURL: resolved.inputs[0].originalURL,
                        executionURLs: [concatenation.outputURL],
                        wasMaterialized: true,
                        concatenatedFrom: concatenation.memberURLs
                    )],
                    materializationStartedAt: resolved.materializationStartedAt ?? Date(),
                    materializationEndedAt: Date()
                )
            } else {
                pairedEnd = true
            }
        }
        resolved = await reusing.withMaterializationTimes(resolved)

        let layoutResolution: FASTQInputLayoutResolution
        if explicitLayout == nil, let pooled = resolved.pooledLayoutResolution {
            layoutResolution = pooled
        } else {
            layoutResolution = FASTQInputLayoutResolver.resolve(
                inputURLs: resolved.executionInputURLs,
                pairedFiles: pairedEnd,
                explicit: explicitLayout
            )
        }
        let resolvedRequest = request
            .withInputFASTQURLs(resolved.executionInputURLs, pairedEnd: pairedEnd)
            .withInputLineage(resolved)
            .withInputLayout(layoutResolution.layout)
        return MappingResolvedInputs(
            request: resolvedRequest,
            layoutResolution: layoutResolution,
            sequenceInputs: resolved,
            readSetPlan: nil
        )
    }

    /// The request for a sample of pairs and single reads, from its plan.
    private static func readSetResolution(
        request: MappingRunRequest,
        plan: ReadSetPlan,
        bundleURL: URL,
        materializer: ReusingMaterializer
    ) async throws -> MappingResolvedInputs {
        let originalURL = request.inputFASTQURLs[0].standardizedFileURL
        var executionURLs: [URL]
        var readSetLayout: MappingReadSetLayout?
        var pairedEnd = false
        var layout = FASTQInputLayout.mixedMergedAndPairs
        if plan.capability.kind == .bothInOneRun, plan.capability.mixedInput == .nameInterleavedStream {
            guard plan.mixedStreams.count == 1, plan.matePairs.isEmpty, plan.singleReads.isEmpty else {
                throw MappingInputResolverError.unsupportedReadSetPlan("a stream mapper needs one stream of pairs and single reads")
            }
            executionURLs = [plan.mixedStreams[0].url]
        } else {
            var r1Files: [URL] = []
            var r2Files: [URL] = []
            for pair in plan.matePairs {
                guard case .separate(let r1, let r2) = pair.files else {
                    throw MappingInputResolverError.unsupportedReadSetPlan("mates must be split into R1 and R2 files")
                }
                r1Files.append(r1)
                r2Files.append(r2)
            }
            guard plan.mixedStreams.isEmpty else {
                throw MappingInputResolverError.unsupportedReadSetPlan("a mixed stream was not split by name")
            }
            let singleFiles = plan.singleReads.map(\.url)
            if singleFiles.isEmpty, r1Files.count == 1 {
                executionURLs = [r1Files[0], r2Files[0]]
                pairedEnd = true
                layout = .pairedFiles
            } else if r1Files.isEmpty, singleFiles.count == 1 {
                executionURLs = singleFiles
                layout = .singleEnd
            } else {
                let sets = MappingReadSetLayout(r1Files: r1Files, r2Files: r2Files, singleReadFiles: singleFiles)
                readSetLayout = sets
                executionURLs = sets.allFiles
            }
        }

        // The materialized file of a virtual bundle, the input of any split.
        let materializedURL = plan.wasMaterialized ? await materializer.materializedURL(for: bundleURL) : nil
        let times = await materializer.interval
        let lineage = ResolvedSequenceInputs(
            inputs: [ResolvedSequenceInputs.Input(
                originalURL: originalURL,
                executionURLs: executionURLs,
                wasMaterialized: plan.wasMaterialized
            )],
            materializationStartedAt: times?.start,
            materializationEndedAt: times?.end
        )
        let sequenceInputs = ResolvedSequenceInputs(
            inputs: [ResolvedSequenceInputs.Input(
                originalURL: originalURL,
                executionURLs: materializedURL.map { [$0] } ?? executionURLs,
                wasMaterialized: materializedURL != nil
            )],
            materializationStartedAt: times?.start,
            materializationEndedAt: times?.end
        )
        let layoutResolution = FASTQInputLayoutResolution(
            layout: layout,
            source: plan.sourceLayout == .mixedDerivative ? .bundleMetadata : .contentScan,
            reason: plan.layoutReason
        )
        let resolvedRequest = request
            .withInputFASTQURLs(executionURLs, pairedEnd: pairedEnd)
            .withInputLineage(lineage)
            .withInputLayout(layout)
            .withReadSetLayout(readSetLayout)
        return MappingResolvedInputs(
            request: resolvedRequest,
            layoutResolution: layoutResolution,
            sequenceInputs: sequenceInputs,
            readSetPlan: plan
        )
    }
}

/// Materializes each virtual bundle once per resolution, so the read-set
/// plan and ``ResolvedSequenceInputs`` read the same file, and keeps when
/// the first materialization began and the last ended.
actor ReusingMaterializer: CLISequenceInputMaterializing {
    private let base: any CLISequenceInputMaterializing & Sendable
    private var materialized: [String: URL] = [:]
    private(set) var interval: (start: Date, end: Date)?

    init(base: any CLISequenceInputMaterializing & Sendable) {
        self.base = base
    }

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let key = bundleURL.standardizedFileURL.path
        if let url = materialized[key], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let began = Date()
        let url = try await base.materialize(bundleURL: bundleURL, tempDirectory: tempDirectory, progress: progress)
        materialized[key] = url.standardizedFileURL
        interval = (interval?.start ?? began, Date())
        return url
    }

    func materializedURL(for bundleURL: URL) -> URL? {
        materialized[bundleURL.standardizedFileURL.path]
    }

    /// `resolved` with the times this materializer measured, which cover a
    /// materialization the read-set plan ran before `resolved` reused it.
    func withMaterializationTimes(_ resolved: ResolvedSequenceInputs) -> ResolvedSequenceInputs {
        guard let interval, resolved.didMaterialize else { return resolved }
        return ResolvedSequenceInputs(
            inputs: resolved.inputs,
            materializationStartedAt: min(interval.start, resolved.materializationStartedAt ?? interval.start),
            materializationEndedAt: max(interval.end, resolved.materializationEndedAt ?? interval.end)
        )
    }
}
