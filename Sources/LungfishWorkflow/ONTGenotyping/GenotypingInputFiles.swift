// GenotypingInputFiles.swift - The FASTQ files one amplicon genotyping input holds, and the reads a run of it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `resolveInputFASTQURLs(for:)` lists the files an input holds. Mode
// detection and failure provenance use that listing. A run reads its inputs
// through `plannedInputReads(for:readType:workDirectory:materializer:)`,
// which plans a `.lungfishfastq` bundle with ReadSetResolver
// (docs/contracts/READ-PAIRING.md). Illumina reads reach the pair merger as
// one stream with every pair adjacent and every single read after the pairs.
// ONT reads arrive as every read on its own, and an ONT sample bundle of
// several chunks is its chunks joined in import order. A virtual bundle is
// materialized first and never read from its preview.

import Foundation
import LungfishIO

extension ONTBarcodeDemuxGenotypingPipeline {
    /// The FASTQ files `inputURL` holds: a loose file, the FASTQ files of a
    /// folder, every chunk of a chunked root (or the original file of a
    /// chunk the bundle no longer holds), or a bundle's first physical file.
    /// A virtual bundle lists its preview, which only mode detection may read.
    public static func resolveInputFASTQURLs(for inputURL: URL) throws -> [URL] {
        let standardized = inputURL.standardizedFileURL
        if FASTQBundle.isFASTQFileURL(standardized) {
            return [standardized]
        }
        guard FASTQBundle.isBundleURL(standardized) else {
            if Self.urlIsDirectory(standardized) {
                return Self.resolveRawFASTQDirectoryURLs(for: standardized)
            }
            return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
        }
        if FASTQSourceFileManifest.exists(in: standardized) {
            let manifest = try FASTQSourceFileManifest.load(from: standardized)
            return manifest.files.compactMap { entry in
                if let bundleRelativeURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: entry.filename,
                    in: standardized,
                    field: "source-files[].filename",
                    allowExistingSymlinkEscape: true
                ), FileManager.default.fileExists(atPath: bundleRelativeURL.path) {
                    return bundleRelativeURL
                }
                let originalURL = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
                return nil
            }
        }
        return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
    }

    /// The inputs a run's provenance records for `inputURL`. A paired, mixed
    /// or virtual derivative is recorded as the bundle, because the file it
    /// lists is R1, one role file or the preview, and the run read every
    /// read. Any other input is recorded as the files it lists.
    public static func provenanceInputURLs(for inputURL: URL) -> [URL] {
        let standardized = inputURL.standardizedFileURL
        switch FASTQBundle.loadDerivedManifest(in: standardized)?.payload {
        case .fullPaired?, .fullMixed?, .subset?, .trim?, .orientMap?, .demuxedVirtual?:
            return [standardized]
        default:
            return (try? resolveInputFASTQURLs(for: standardized)) ?? [standardized]
        }
    }

    static func urlIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func resolveRawFASTQDirectoryURLs(for directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("._") {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if url.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                    enumerator.skipDescendants()
                }
                continue
            }
            if FASTQBundle.isFASTQFileURL(url) {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

// MARK: - The reads a run reads

/// The reads one genotyping input gives a run, and how they were planned.
struct GenotypingInputReads: Sendable {
    /// The input as the user named it.
    let inputURL: URL
    /// The files the run reads, in order. A bundle gives one file.
    let fastqURLs: [URL]
    /// The read-set plan of a bundle. Nil for a loose file, a folder of
    /// FASTQ files, a chunked root or a FASTA payload, which are read as
    /// ``ONTBarcodeDemuxGenotypingPipeline/resolveInputFASTQURLs(for:)`` lists them.
    let plan: ReadSetPlan?
    /// The interleave that made one stream of a plan of several files.
    let streamStep: ReadSetStep?
    /// The join of every chunk of a chunked root read as one sample.
    var concatenation: SequenceInputConcatenation? = nil
    /// When the resolver ran, which covers the materialization of a virtual bundle.
    let planStartedAt: Date
    let planEndedAt: Date

    /// Every split and interleave the planning wrote, in order.
    var steps: [ReadSetStep] {
        (plan?.steps ?? []) + (streamStep.map { [$0] } ?? [])
    }

    /// Whether the planning wrote a file the run reads. A bundle of one file
    /// read in place writes none, so its run records nothing new.
    var wroteFiles: Bool {
        (plan?.wasMaterialized ?? false) || !steps.isEmpty || concatenation != nil
    }

    /// The file a virtual bundle was materialized to.
    var materializedURL: URL? {
        guard let plan, plan.wasMaterialized else { return nil }
        return plan.steps.first?.inputURLs.first ?? plan.executionURLs.first
    }

    /// The plan as the run's provenance records it, or nil when the planning
    /// wrote no file.
    func provenanceRecord(sample: String) -> [String: Any]? {
        guard wroteFiles, let plan else { return nil }
        func count(_ value: Int?) -> Any { value.map { $0 as Any } ?? NSNull() }
        return [
            "sample": sample,
            "input": inputURL.path,
            "capability": plan.capability.provenanceName,
            "sourceLayout": plan.sourceLayout.rawValue,
            "layoutReason": plan.layoutReason,
            "materialized": materializedURL?.path as Any? ?? NSNull(),
            "readFASTQs": fastqURLs.map(\.path),
            "pairedFragments": count(plan.composition.pairedFragments),
            "mergedReads": count(plan.composition.mergedReads),
            "orphanReads": count(plan.composition.orphanReads),
            "singleEndReads": count(plan.composition.singleEndReads),
            "mergedOrOrphanReads": count(plan.composition.mergedOrOrphanReads),
            "steps": steps.map { step -> [String: Any] in
                [
                    "toolName": step.toolName,
                    "kind": step.kind.rawValue,
                    "inputs": step.inputURLs.map(\.path),
                    "outputs": step.outputURLs.map(\.path),
                    "pairs": step.pairCount,
                    "singleReads": step.singleReadCount,
                ]
            },
        ]
    }

    /// The canonical provenance steps of the files the planning wrote: the
    /// `cat` join of a chunked root, the materialization of a virtual
    /// bundle, then each split and interleave with its record counts. Empty
    /// when it wrote none.
    func provenanceSteps(workflowVersion: String) throws -> [ProvenanceStep] {
        guard wroteFiles else { return [] }
        var result: [ProvenanceStep] = []
        if let concatenation {
            result.append(ProvenanceStep(stepExecution: try concatenation.stepExecution(
                toolVersion: workflowVersion,
                startedAt: planStartedAt,
                endedAt: planEndedAt
            )))
        }
        if let materialized = materializedURL {
            let command = CLISequenceInputMaterialization.materializationCommand(
                originalURL: inputURL,
                executionURL: materialized
            )
            result.append(ProvenanceStep(
                toolName: CLISequenceInputMaterialization.materializationToolName,
                toolVersion: ProvenanceVersion.required(workflowVersion),
                argv: command,
                durableReplayArgv: command,
                inputs: try CLISequenceInputMaterialization.originalInputDescriptors(for: inputURL),
                outputs: [
                    try CLISequenceInputMaterialization.executionInputDescriptor(
                        originalURL: inputURL,
                        executionURL: materialized
                    ),
                ],
                exitStatus: 0,
                wallTimeSeconds: max(0, planEndedAt.timeIntervalSince(planStartedAt)),
                startedAt: planStartedAt,
                completedAt: planEndedAt
            ))
        }
        for step in steps {
            result.append(ProvenanceStep(stepExecution: try step.stepExecution(toolVersion: workflowVersion)))
        }
        return result
    }
}

extension ONTBarcodeDemuxGenotypingPipeline {

    /// The capability a read type plans its inputs with, from the
    /// `genotype.illumina-mhc` and `genotype.ont-mhc` declarations.
    static func readPairingCapability(for readType: AmpliconGenotypingReadType) -> ReadPairingCapability {
        let isONT = readType == .ont
        return ReadPairingCapabilityRegistry.capability(for: isONT ? "genotype.ont-mhc" : "genotype.illumina-mhc")
            ?? (isONT ? .singleReadsOnly : .bothInOneRunAsNameInterleavedStream)
    }

    /// The reads one input gives a run.
    ///
    /// A `.lungfishfastq` bundle is planned by ``ReadSetResolver`` with the
    /// read type's capability and comes back as one file. A plan of one file
    /// is that file, read in place (L1, L2, L3 and L5a) or as the resolver
    /// wrote it (a materialized virtual bundle, or the stream of a merge or
    /// repair derivative). A plan of several files becomes one stream: every
    /// mate pair with each R1 record followed by its R2 record, mate names
    /// checked, then every single read. A written file that holds pairs and
    /// single reads carries the layout hint, so the pair merger splits it by
    /// fragment name past the bounded layout scan.
    ///
    /// A loose file, a file inside a bundle, a folder, a chunked root and a
    /// FASTA payload are read as ``resolveInputFASTQURLs(for:)`` lists them.
    /// With `joinsChunks`, a chunked root of several chunks is one sample
    /// instead, every chunk joined in import order by the join the
    /// materializer and the other one-run consumers use
    /// (``ResolvedSequenceInputs/concatenateMultiFileBundle(_:into:)``), and
    /// the join is a `cat` provenance step. ONT sample bundles ask for it,
    /// since each ONT read stands alone. Illumina chunks may be the two mates
    /// of each pair, so they are never joined end to end (final review A, S2).
    static func plannedInputReads(
        for inputURL: URL,
        readType: AmpliconGenotypingReadType,
        workDirectory: URL,
        joinsChunks: Bool = false,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: .shared)
    ) async throws -> GenotypingInputReads {
        let standardized = inputURL.standardizedFileURL
        let runClock = ProvenanceRunClock()
        let startedAt = runClock.startedAt
        guard plansThroughResolver(standardized) else {
            if joinsChunks, let joined = try ResolvedSequenceInputs.concatenateMultiFileBundle(standardized, into: workDirectory) {
                return GenotypingInputReads(
                    inputURL: standardized,
                    fastqURLs: [joined.outputURL],
                    plan: nil,
                    streamStep: nil,
                    concatenation: joined,
                    planStartedAt: startedAt,
                    planEndedAt: runClock.now
                )
            }
            return GenotypingInputReads(
                inputURL: standardized,
                fastqURLs: try resolveInputFASTQURLs(for: standardized),
                plan: nil,
                streamStep: nil,
                planStartedAt: startedAt,
                planEndedAt: startedAt
            )
        }
        let plan = try await ReadSetResolver(materializationDirectory: workDirectory, materializer: materializer)
            .plan(for: standardized, capability: readPairingCapability(for: readType))
        let endedAt = runClock.now
        let stream = try oneStream(for: plan, workDirectory: workDirectory)
        return GenotypingInputReads(
            inputURL: standardized,
            fastqURLs: [stream.url],
            plan: plan,
            streamStep: stream.step,
            planStartedAt: startedAt,
            planEndedAt: endedAt
        )
    }

    /// The reads of every input, each planned on its own.
    static func plannedInputReads(
        for inputURLs: [URL],
        readType: AmpliconGenotypingReadType,
        workDirectory: URL
    ) async throws -> [GenotypingInputReads] {
        var result: [GenotypingInputReads] = []
        for inputURL in inputURLs {
            result.append(try await plannedInputReads(for: inputURL, readType: readType, workDirectory: workDirectory))
        }
        return result
    }

    /// The plans of the samples whose planning wrote a file, for the input
    /// preparation record. Empty when none did, so a run of one-file bundles
    /// records nothing new.
    static func readSetPlanRecords(_ samples: [IlluminaSampleInput]) -> [[String: Any]] {
        samples.compactMap { $0.inputReads?.provenanceRecord(sample: $0.sampleID) }
    }

    /// The provenance steps that wrote the files a run read, input by input.
    static func readSetProvenanceSteps(_ inputReads: [GenotypingInputReads]) throws -> [ProvenanceStep] {
        try inputReads.flatMap { try $0.provenanceSteps(workflowVersion: WorkflowRun.currentAppVersion) }
    }

    /// Whether `url` is a bundle the read-set resolver plans. A chunked root
    /// keeps its listing, which falls back to a chunk's original file, and a
    /// FASTA payload holds no FASTQ reads.
    private static func plansThroughResolver(_ url: URL) -> Bool {
        guard FASTQBundle.isBundleURL(url), !FASTQSourceFileManifest.exists(in: url) else { return false }
        if case .fullFASTA = FASTQBundle.loadDerivedManifest(in: url)?.payload { return false }
        return true
    }

    /// The one file a run reads for `plan`, and the interleave that wrote it
    /// when the plan held several files.
    private static func oneStream(
        for plan: ReadSetPlan,
        workDirectory: URL
    ) throws -> (url: URL, step: ReadSetStep?) {
        let files = plan.executionURLs
        let workPath = workDirectory.standardizedFileURL.path + "/"
        if files.count == 1, let file = files.first {
            if file.standardizedFileURL.path.hasPrefix(workPath), let stream = plan.mixedStreams.first,
               let pairs = stream.pairCount, let singles = stream.singleReadCount {
                markMixed(file, pairs: pairs, singles: singles, role: stream.singleReadRole)
            }
            return (file, nil)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let output = workDirectory.appendingPathComponent("\(ReadSetResolver.outputStem(for: plan.inputURL)).stream.fastq")
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        let runClock = ProvenanceRunClock()
        var pairs = 0
        var singles = 0
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            for pair in plan.matePairs {
                switch pair.files {
                case .separate(let r1, let r2):
                    do {
                        pairs += try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true).r1Records
                    } catch let error as FASTQPairInterleaver.InterleaveError {
                        throw ReadSetResolverError.mateNameMismatch(r1Path: r1.path, r2Path: r2.path, detail: error.localizedDescription)
                    }
                case .interleaved(let url):
                    pairs += try ReadSetResolver.copyRecords(of: url, to: handle) / 2
                }
            }
            for stream in plan.mixedStreams {
                let counts = try FASTQPairInterleaver.countMixed(interleaved: stream.url)
                _ = try ReadSetResolver.copyRecords(of: stream.url, to: handle)
                pairs += counts.pairs
                singles += counts.unpaired
            }
            for single in plan.singleReads {
                singles += try ReadSetResolver.copyRecords(of: single.url, to: handle)
            }
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
        let roles = Set(plan.singleReads.map(\.role) + plan.mixedStreams.map(\.singleReadRole))
        if pairs > 0, singles > 0 {
            markMixed(output, pairs: pairs, singles: singles, role: roles.count == 1 ? roles.first! : .mergedOrOrphan)
        }
        let step = ReadSetStep(
            kind: .interleaveByName,
            inputURLs: files,
            outputURLs: [output],
            pairCount: pairs,
            singleReadCount: singles,
            startedAt: runClock.startedAt,
            endedAt: runClock.now
        )
        return (output, step)
    }

    /// Records beside a written stream that it holds `pairs` adjacent pairs
    /// and `singles` single reads.
    private static func markMixed(_ url: URL, pairs: Int, singles: Int, role: ReadSetReadRole) {
        guard let hint = FASTQMixedLayoutHint.classification(
            pairs: pairs,
            singles: singles,
            singleRole: role == .merged ? .merged : .unpaired,
            filename: url.lastPathComponent
        ) else { return }
        FASTQMixedLayoutHint.write(hint, beside: url)
    }
}
