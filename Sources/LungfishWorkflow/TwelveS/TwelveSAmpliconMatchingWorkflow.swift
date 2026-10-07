import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import os.log

private let twelveSWorkflowLogger = Logger(subsystem: "com.lungfish.workflow", category: "TwelveSAmplicon")

public struct TwelveSAmpliconMatchingConfiguration: Equatable, Sendable {
    public let inputFASTQs: [URL]
    public let referenceFASTA: URL
    public let referenceMetadata: URL?
    public let referenceBundleURL: URL?
    public let sampleMetadata: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let minimumSoftClipBases: Int
    public let maximumIndelBases: Int
    public let matchingMode: TwelveSAmpliconMatchingMode
    public let threads: Int
    public let runChimeraReview: Bool
    public let forceOverwrite: Bool
    /// How cross-species identical-sequence ambiguous reads are resolved.
    public let ambiguityResolution: TwelveSAbundanceReassigner.ResolutionPolicy
    public let argv: [String]

    public init(
        inputFASTQs: [URL],
        referenceFASTA: URL,
        referenceMetadata: URL? = nil,
        referenceBundleURL: URL? = nil,
        sampleMetadata: URL? = nil,
        outputDirectory: URL,
        outputName: String,
        minimumSoftClipBases: Int = 1,
        maximumIndelBases: Int = 3,
        matchingMode: TwelveSAmpliconMatchingMode = .illuminaExact,
        threads: Int = 1,
        runChimeraReview: Bool = true,
        forceOverwrite: Bool = false,
        ambiguityResolution: TwelveSAbundanceReassigner.ResolutionPolicy = .anyNonzeroLead,
        argv: [String] = []
    ) {
        self.inputFASTQs = inputFASTQs.map(\.standardizedFileURL)
        self.referenceFASTA = referenceFASTA.standardizedFileURL
        self.referenceMetadata = referenceMetadata?.standardizedFileURL
        self.referenceBundleURL = referenceBundleURL?.standardizedFileURL
        self.sampleMetadata = sampleMetadata?.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = outputName
        self.minimumSoftClipBases = minimumSoftClipBases
        self.maximumIndelBases = maximumIndelBases
        self.matchingMode = matchingMode
        self.threads = max(1, threads)
        self.runChimeraReview = runChimeraReview
        self.forceOverwrite = forceOverwrite
        self.ambiguityResolution = ambiguityResolution
        self.argv = argv
    }
}

public struct TwelveSAmpliconMatchingResult: Equatable, Sendable {
    public let bundleURL: URL
}

public enum TwelveSAmpliconMatchingError: Error, LocalizedError, Equatable {
    case noInputs
    case missingInput(String)
    case missingReference(String)
    case outputExists(String)
    case emptyReference(String)
    /// A bundle whose full reads cannot be found, such as a root that holds
    /// only its preview.
    case noReadsInInput(String)
    /// The two mates of a pair do not correspond, by name or by count.
    case mateMismatch(String)
    /// Two inputs would be one sample, which a result holds once.
    case duplicateSampleID(sampleID: String, first: String, second: String)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "At least one FASTQ file or .lungfishfastq bundle is required."
        case let .missingInput(path):
            return "FASTQ input does not exist: \(path)"
        case let .missingReference(path):
            return "12S reference FASTA does not exist: \(path)"
        case let .outputExists(path):
            return "12S output bundle already exists: \(path)"
        case let .emptyReference(path):
            return "12S reference FASTA contains no records: \(path)"
        case let .noReadsInInput(path):
            return "No full reads could be found in \(path), which holds only a preview of its reads or has lost them. Re-import the FASTQ file, then run 12S matching on the new bundle."
        case let .mateMismatch(detail):
            return detail
        case let .duplicateSampleID(sampleID, first, second):
            return first == second
                ? "The input \(first) is named twice. Name each input once."
                : "The inputs \(first) and \(second) are both sample \(sampleID), and a 12S result holds each sample once. Rename one of them or run them separately."
        }
    }
}

public struct TwelveSAmpliconMatchingWorkflow: Sendable {
    public typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let chimeraReviewer: any TwelveSChimeraReviewing

    public init(chimeraReviewer: any TwelveSChimeraReviewing = TwelveSVSearchChimeraReviewer()) {
        self.chimeraReviewer = chimeraReviewer
    }

    public func run(
        _ config: TwelveSAmpliconMatchingConfiguration,
        progressHandler: ProgressHandler? = nil
    ) async throws -> TwelveSAmpliconMatchingResult {
        let startedAt = Date()
        progressHandler?(0.02, "Validating 12S amplicon matching inputs.")
        try validate(config)

        let bundleURL = config.outputDirectory.appendingPathComponent(
            "\(config.outputName).\(TwelveSAmpliconResultBundle.directoryExtension)",
            isDirectory: true
        )
        let earlierOutputExists = FileManager.default.fileExists(atPath: bundleURL.path)
        if earlierOutputExists, !config.forceOverwrite {
            throw TwelveSAmpliconMatchingError.outputExists(bundleURL.path)
        }

        // Every refusal comes before anything is written, and the reads and
        // the chimera review run in a scratch folder beside the output, so an
        // earlier output is replaced only once this run has a complete result
        // to put in its place. The scratch folder goes however the run ends.
        progressHandler?(0.12, "Loading 12S reference records.")
        let referenceIndex = try TwelveSReferenceIndex.load(
            from: config.referenceFASTA,
            metadataURL: config.referenceMetadata
        )
        guard !referenceIndex.records.isEmpty else {
            throw TwelveSAmpliconMatchingError.emptyReference(config.referenceFASTA.path)
        }

        let scratchDirectory = Self.scratchDirectory(for: config)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        progressHandler?(0.25, "Resolving FASTQ inputs.")
        let resolvedInputs = try await resolveInputs(
            config.inputFASTQs, scratchDirectory: scratchDirectory, progressHandler: progressHandler
        )
        // The files a split wrote live in the scratch folder, so their
        // provenance is taken now, while they exist.
        let readSetSteps = try resolvedInputs.flatMap(\.plan.steps).map(Self.provenanceStep)
        let classifier = TwelveSAmpliconReadClassifier(
            references: referenceIndex.records,
            minimumSoftClipBases: config.minimumSoftClipBases,
            maximumIndelBases: config.maximumIndelBases,
            matchingMode: config.matchingMode
        )
        progressHandler?(0.40, "Matching reads to 12S references.")
        let classified = try await classifyInputs(
            resolvedInputs,
            classifier: classifier,
            references: referenceIndex.records,
            ambiguityResolution: config.ambiguityResolution,
            threads: config.threads
        )
        progressHandler?(0.66, classified.fragmentSummary)
        classified.readWarnings.forEach { progressHandler?(0.66, $0) }
        let unresolved = makeUnresolvedSequences(from: classified)
        let scratchChimeraDirectory = scratchDirectory.appendingPathComponent("vsearch", isDirectory: true)
        let chimeraResult: TwelveSChimeraReviewResult
        if config.runChimeraReview {
            progressHandler?(0.70, "Reviewing unresolved sequences for chimeras.")
            chimeraResult = try await chimeraReviewer.review(
                unresolvedSequences: unresolved,
                outputDirectory: scratchChimeraDirectory,
                threads: config.threads
            )
        } else {
            progressHandler?(0.70, "Skipping chimera review.")
            chimeraResult = TwelveSChimeraReviewResult(
                statusesBySequenceID: Dictionary(uniqueKeysWithValues: unresolved.map {
                    ($0.sequenceID, TwelveSChimeraStatus.notReviewed)
                })
            )
        }
        let reviewedUnresolved = unresolved.map { unresolved in
            TwelveSUnresolvedSequence(
                sequenceID: unresolved.sequenceID,
                sequence: unresolved.sequence,
                readCount: unresolved.readCount,
                sampleCounts: unresolved.sampleCounts,
                chimeraStatus: chimeraResult.statusesBySequenceID[unresolved.sequenceID] ?? unresolved.chimeraStatus,
                note: unresolved.note
            )
        }

        // Everything that could be refused has been accepted and every tool
        // has finished. The earlier output waits aside while the new bundle
        // is written, and comes back if writing it fails.
        progressHandler?(0.80, "Preparing 12S output workspace.")
        let earlierOutput = try earlierOutputExists ? SetAsideOutput.setAside(bundleURL) : nil
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            // The bundle carries a run record until the last step and stays
            // out of the sidebar while it is written.
            try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "12S amplicon matching"), in: bundleURL)
            let bundleChimeraDirectory = bundleURL.appendingPathComponent("vsearch", isDirectory: true)
            var relocatedChimeraResult = chimeraResult
            if FileManager.default.fileExists(atPath: scratchChimeraDirectory.path) {
                try FileManager.default.moveItem(at: scratchChimeraDirectory, to: bundleChimeraDirectory)
                relocatedChimeraResult = chimeraResult.relocatingFiles(
                    from: scratchChimeraDirectory,
                    to: bundleChimeraDirectory
                )
            }
            progressHandler?(0.84, "Writing 12S result bundle tables.")
            try writeBundle(
                config: config,
                bundleURL: bundleURL,
                references: referenceIndex.records,
                classified: classified,
                unresolvedSequences: reviewedUnresolved
            )
            progressHandler?(0.94, "Writing reproducibility provenance.")
            try writeProvenance(
                config: config,
                bundleURL: bundleURL,
                resolvedInputs: resolvedInputs,
                readSetSteps: readSetSteps,
                classified: classified,
                chimeraResult: relocatedChimeraResult,
                scratchDirectory: scratchDirectory,
                startedAt: startedAt,
                completedAt: Date()
            )
            AnalysisRunRecord.markComplete(bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            try Self.restoreEarlierResult(earlierOutput, after: error)
            throw error
        }
        earlierOutput?.discard()
        progressHandler?(1.0, "12S amplicon matching complete.")
        return TwelveSAmpliconMatchingResult(bundleURL: bundleURL.standardizedFileURL)
    }

    private func validate(_ config: TwelveSAmpliconMatchingConfiguration) throws {
        guard !config.inputFASTQs.isEmpty else {
            throw TwelveSAmpliconMatchingError.noInputs
        }
        for input in config.inputFASTQs where !FileManager.default.fileExists(atPath: input.path) {
            throw TwelveSAmpliconMatchingError.missingInput(input.path)
        }
        try Self.refuseDuplicateSampleIDs(config.inputFASTQs)
        guard FileManager.default.fileExists(atPath: config.referenceFASTA.path) else {
            throw TwelveSAmpliconMatchingError.missingReference(config.referenceFASTA.path)
        }
        if let referenceBundleURL = config.referenceBundleURL,
           !FileManager.default.fileExists(atPath: referenceBundleURL.path) {
            throw TwelveSAmpliconMatchingError.missingReference(referenceBundleURL.path)
        }
        if let referenceMetadata = config.referenceMetadata,
           !FileManager.default.fileExists(atPath: referenceMetadata.path) {
            throw TwelveSAmpliconMatchingError.missingReference(referenceMetadata.path)
        }
        if let sampleMetadata = config.sampleMetadata,
           !FileManager.default.fileExists(atPath: sampleMetadata.path) {
            throw TwelveSAmpliconMatchingError.missingInput(sampleMetadata.path)
        }
    }

    /// Every count is in fragments. A merged read, an orphan and a read of a
    /// single-end run are one fragment each, and an unmerged pair is one.
    struct ClassifiedReads {
        var sampleOrder: [String] = []
        var inputReadsBySample: [String: Int] = [:]
        var singleReadFragmentsBySample: [String: Int] = [:]
        var pairedFragmentsBySample: [String: Int] = [:]
        var exactReadsBySample: [String: Int] = [:]
        var ambiguousReadsBySample: [String: Int] = [:]
        /// Reads reassigned from cross-species ambiguity to an abundant species —
        /// tracked separately from exact reads (never laundered in).
        var reassignedReadsBySample: [String: Int] = [:]
        /// Unmerged pairs whose mates gave different calls. They count in
        /// `inputReadsBySample` and nowhere else.
        var discordantPairsBySample: [String: Int] = [:]
        var discordantPairsByReasonBySample: [String: [TwelveSPairDiscordance: Int]] = [:]
        var countsByTarget: [String: [String: Int]] = [:]
        var unresolvedCounts: [String: [String: Int]] = [:]
        /// The unresolved and ambiguous sequences that unmerged pairs fed,
        /// under the R1 sequence, and the ones merged or single reads fed.
        var pairFedUnresolvedSequences: Set<String> = []
        var singleFedUnresolvedSequences: Set<String> = []
        /// The abundance reassignment decisions, persisted for audit.
        var reassignmentMoves: [TwelveSAbundanceReassigner.Move] = []
        /// What reading the inputs warned of, such as mates paired by position.
        var readWarnings: [String] = []

        var sawPairs: Bool {
            pairedFragmentsBySample.values.contains { $0 > 0 }
        }

        var discordantPairsByReason: [TwelveSPairDiscordance: Int] {
            discordantPairsByReasonBySample.values.reduce(into: [:]) { totals, byReason in
                for (reason, count) in byReason { totals[reason, default: 0] += count }
            }
        }

        var fragmentSummary: String {
            TwelveSAmpliconMatchingWorkflow.fragmentSummary(
                singleReads: singleReadFragmentsBySample.values.reduce(0, +),
                pairs: pairedFragmentsBySample.values.reduce(0, +),
                discordantByReason: discordantPairsByReason
            )
        }

        /// Counts one fragment's call, a single read's or a concordant pair's.
        mutating func count(
            _ classification: TwelveSReadClassification,
            sequence: String,
            sample sampleID: String,
            weight: Int,
            fedByPair: Bool,
            ambiguousCandidates: inout [String: [String]]
        ) {
            switch classification {
            case let .exact(targetID, _):
                exactReadsBySample[sampleID, default: 0] += weight
                countsByTarget[targetID, default: [:]][sampleID, default: 0] += weight
                return
            case let .ambiguous(targetIDs):
                ambiguousReadsBySample[sampleID, default: 0] += weight
                unresolvedCounts[sequence, default: [:]][sampleID, default: 0] += weight
                ambiguousCandidates[sequence] = targetIDs
            case .unresolved:
                unresolvedCounts[sequence, default: [:]][sampleID, default: 0] += weight
            }
            if fedByPair {
                pairFedUnresolvedSequences.insert(sequence)
            } else {
                singleFedUnresolvedSequences.insert(sequence)
            }
        }
    }

    struct ResolvedInput: Sendable {
        let sourceURL: URL
        let plan: ReadSetPlan
    }

    /// The fragments of one sample, deduplicated by sequence so each distinct
    /// sequence is classified once.
    private struct SampleFragments {
        struct PairKey: Hashable {
            let r1: String
            let r2: String
        }

        let sampleID: String
        var singleCounts: [String: Int] = [:]
        var pairCounts: [PairKey: Int] = [:]
        var singleReadFragments = 0
        var pairedFragments = 0
    }

    private struct SampleMetadataSnapshot: Sendable {
        let resolved: ResolvedSampleMetadata
        let resolvedRelativePath: String?
        let manifestRelativePath: String?
        let analysisOriginalRelativePath: String?
    }

    private func classifyInputs(
        _ inputs: [ResolvedInput],
        classifier: TwelveSAmpliconReadClassifier,
        references: [TwelveSReferenceRecord],
        ambiguityResolution: TwelveSAbundanceReassigner.ResolutionPolicy,
        threads: Int
    ) async throws -> ClassifiedReads {
        var classified = ClassifiedReads()
        var samples: [SampleFragments] = []
        var uniqueSequences = Set<String>()

        for input in inputs {
            let sampleID = Self.sampleID(for: input.sourceURL)
            classified.sampleOrder.append(sampleID)
            var sample = SampleFragments(sampleID: sampleID)
            classified.readWarnings += try await Self.readFragments(of: input.plan) { fragment in
                switch fragment {
                case let .single(sequence, weight):
                    sample.singleCounts[sequence, default: 0] += weight
                    sample.singleReadFragments += weight
                    uniqueSequences.insert(sequence)
                case let .pair(r1, r2, weight):
                    sample.pairCounts[SampleFragments.PairKey(r1: r1, r2: r2), default: 0] += weight
                    sample.pairedFragments += weight
                    uniqueSequences.insert(r1)
                    uniqueSequences.insert(r2)
                }
            }
            classified.inputReadsBySample[sampleID, default: 0] += sample.singleReadFragments + sample.pairedFragments
            classified.singleReadFragmentsBySample[sampleID, default: 0] += sample.singleReadFragments
            classified.pairedFragmentsBySample[sampleID, default: 0] += sample.pairedFragments
            samples.append(sample)
        }

        let classifications = await classifyUniqueSequences(
            Array(uniqueSequences).sorted(),
            classifier: classifier,
            threads: threads
        )
        var ambiguousCandidates: [String: [String]] = [:]
        for sample in samples {
            for (sequence, count) in sample.singleCounts {
                guard let classification = classifications[sequence] else { continue }
                classified.count(
                    classification, sequence: sequence, sample: sample.sampleID, weight: count,
                    fedByPair: false, ambiguousCandidates: &ambiguousCandidates
                )
            }
            // A concordant pair counts as its R1 read, once. Its mate only
            // confirms the call or, when it disagrees, vetoes the fragment.
            for (pair, count) in sample.pairCounts {
                guard let first = classifications[pair.r1], let second = classifications[pair.r2] else { continue }
                switch TwelveSFragmentCall.join(r1: first, r2: second) {
                case let .concordant(classification):
                    classified.count(
                        classification, sequence: pair.r1, sample: sample.sampleID, weight: count,
                        fedByPair: true, ambiguousCandidates: &ambiguousCandidates
                    )
                case let .discordant(reason):
                    classified.discordantPairsBySample[sample.sampleID, default: 0] += count
                    classified.discordantPairsByReasonBySample[sample.sampleID, default: [:]][reason, default: 0] += count
                }
            }
        }

        // Pass B: reassign cross-species identical-sequence ambiguous reads to the
        // most-abundant candidate species (strict plurality). See
        // TwelveSAbundanceReassigner.
        applyAbundanceReassignment(&classified, ambiguousCandidates: ambiguousCandidates,
                                   references: references, policy: ambiguityResolution)

        return classified
    }

    /// The biological species key for a reference (scientific name), so multiple
    /// reference variants of the same species count together for abundance —
    /// matching the bundle's `scientificNameKey` grouping (NOT raw displayName).
    private func speciesKey(for ref: TwelveSReferenceRecord) -> String {
        let target = ref.target
        return target.scientificName ?? target.displayName
    }

    /// Maps each species (scientific name) to its canonical target — the longest
    /// reference sequence, tie-broken by smallest targetID.
    private func canonicalTargetForSpecies(_ references: [TwelveSReferenceRecord]) -> [String: String] {
        var best: [String: TwelveSReferenceRecord] = [:]
        for ref in references {
            let key = speciesKey(for: ref)
            if let existing = best[key] {
                if ref.sequence.count > existing.sequence.count
                    || (ref.sequence.count == existing.sequence.count && ref.targetID < existing.targetID) {
                    best[key] = ref
                }
            } else {
                best[key] = ref
            }
        }
        return best.mapValues(\.targetID)
    }

    private func applyAbundanceReassignment(
        _ classified: inout ClassifiedReads,
        ambiguousCandidates: [String: [String]],
        references: [TwelveSReferenceRecord],
        policy: TwelveSAbundanceReassigner.ResolutionPolicy
    ) {
        guard !ambiguousCandidates.isEmpty else { return }
        let speciesForTarget = Dictionary(
            references.map { ($0.targetID, speciesKey(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ambiguousCandidates,
            unresolvedCounts: classified.unresolvedCounts,
            countsByTarget: classified.countsByTarget,
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalTargetForSpecies(references),
            policy: policy
        )
        guard !result.moves.isEmpty else { return }

        classified.countsByTarget = result.countsByTarget
        classified.unresolvedCounts = result.unresolvedCounts
        classified.reassignmentMoves = result.moves

        // Each move carries its exact (sequence, sample, reads), so the per-sample
        // accounting is precise: the reads leave ambiguous and become a distinct
        // reassigned channel (NOT folded into exact reads).
        var movedTotal = 0
        for move in result.moves {
            classified.reassignedReadsBySample[move.sample, default: 0] += move.reads
            classified.ambiguousReadsBySample[move.sample, default: 0] -= move.reads
            movedTotal += move.reads
        }
        let speciesMoves = result.moves
            .reduce(into: [String: Int]()) { $0[$1.toSpecies, default: 0] += $1.reads }
            .map { "\($0.key) (+\($0.value))" }
            .sorted()
            .joined(separator: ", ")
        twelveSWorkflowLogger.info(
            "12S abundance reassignment: moved \(movedTotal, privacy: .public) reads from cross-species ambiguity to: \(speciesMoves, privacy: .public)"
        )
    }

    private func classifyUniqueSequences(
        _ sequences: [String],
        classifier: TwelveSAmpliconReadClassifier,
        threads: Int
    ) async -> [String: TwelveSReadClassification] {
        guard !sequences.isEmpty else { return [:] }
        let workerCount = max(1, min(max(1, threads), sequences.count))
        if workerCount == 1 {
            return Dictionary(uniqueKeysWithValues: sequences.map {
                ($0, classifier.classify(readSequence: $0))
            })
        }

        let chunkSize = max(1, (sequences.count + workerCount - 1) / workerCount)
        return await withTaskGroup(of: [String: TwelveSReadClassification].self) { group in
            for start in stride(from: 0, to: sequences.count, by: chunkSize) {
                let end = min(sequences.count, start + chunkSize)
                let chunk = Array(sequences[start..<end])
                group.addTask {
                    var local: [String: TwelveSReadClassification] = [:]
                    local.reserveCapacity(chunk.count)
                    for sequence in chunk {
                        local[sequence] = classifier.classify(readSequence: sequence)
                    }
                    return local
                }
            }

            var merged: [String: TwelveSReadClassification] = [:]
            merged.reserveCapacity(sequences.count)
            for await local in group {
                merged.merge(local) { _, new in new }
            }
            return merged
        }
    }

    /// The unresolved and ambiguous sequences with their fragment counts. A
    /// row that unmerged pairs fed says so, since it shows the R1 sequence.
    private func makeUnresolvedSequences(from classified: ClassifiedReads) -> [TwelveSUnresolvedSequence] {
        classified.unresolvedCounts
            .map { sequence, sampleCounts in
                (sequence: sequence, sampleCounts: sampleCounts, readCount: sampleCounts.values.reduce(0, +))
            }
            .sorted {
                if $0.readCount != $1.readCount {
                    return $0.readCount > $1.readCount
                }
                return $0.sequence < $1.sequence
            }
            .enumerated()
            .map { index, entry in
                let note: String?
                if classified.pairFedUnresolvedSequences.contains(entry.sequence) {
                    note = classified.singleFedUnresolvedSequences.contains(entry.sequence)
                        ? "merged reads and unmerged pairs"
                        : "unmerged pairs, R1 shown"
                } else {
                    note = nil
                }
                return TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_\(index + 1)",
                    sequence: entry.sequence,
                    readCount: entry.readCount,
                    sampleCounts: entry.sampleCounts,
                    chimeraStatus: .notReviewed,
                    note: note
                )
            }
    }

    private func writeBundle(
        config: TwelveSAmpliconMatchingConfiguration,
        bundleURL: URL,
        references: [TwelveSReferenceRecord],
        classified: ClassifiedReads,
        unresolvedSequences: [TwelveSUnresolvedSequence]
    ) throws {
        let referenceCopyURL = bundleURL.appendingPathComponent("reference.fa")
        let targetTableURL = bundleURL.appendingPathComponent("targets.tsv")
        let alternateMatchesTableURL = bundleURL.appendingPathComponent("target-alternate-matches.tsv")
        let countMatrixURL = bundleURL.appendingPathComponent("sample-target-counts.tsv")
        let sampleTableURL = bundleURL.appendingPathComponent("samples.tsv")
        let readFateURL = bundleURL.appendingPathComponent("read-fate.json")
        let unresolvedTableURL = bundleURL.appendingPathComponent("unresolved-sequences.tsv")
        let unresolvedFastaURL = bundleURL.appendingPathComponent("unresolved-sequences.fasta")
        let reassignmentsTableURL = bundleURL.appendingPathComponent("reassignments.tsv")

        try FileManager.default.copyItem(at: config.referenceFASTA, to: referenceCopyURL)
        try writeTargets(references, to: targetTableURL)
        try writeAlternateMatches(references, to: alternateMatchesTableURL)
        try writeCountMatrix(
            references: references,
            sampleOrder: classified.sampleOrder,
            countsByTarget: classified.countsByTarget,
            to: countMatrixURL
        )
        let sampleMetadataSnapshot = try writeSampleMetadataSnapshot(
            config: config,
            bundleURL: bundleURL,
            sampleOrder: classified.sampleOrder
        )
        let samples = makeSamples(
            classified: classified,
            unresolvedSequences: unresolvedSequences,
            sampleMetadata: sampleMetadataSnapshot.resolved
        )
        try writeSamples(samples, to: sampleTableURL)
        try writeReadFate(samples: samples, classified: classified, to: readFateURL)
        try writeUnresolvedTable(unresolvedSequences, to: unresolvedTableURL)
        try writeUnresolvedFasta(unresolvedSequences, to: unresolvedFastaURL)
        // Only emit the reassignments table when there were reassignments, so
        // the manifest path stays nil for runs (and tools) that never reassign.
        let wroteReassignments = !classified.reassignmentMoves.isEmpty
        if wroteReassignments {
            try writeReassignments(classified.reassignmentMoves, to: reassignmentsTableURL)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: config.outputName,
            analysisName: config.outputName,
            referencePath: referenceCopyURL.lastPathComponent,
            targetTablePath: targetTableURL.lastPathComponent,
            countMatrixPath: countMatrixURL.lastPathComponent,
            sampleTablePath: sampleTableURL.lastPathComponent,
            readFatePath: readFateURL.lastPathComponent,
            alternateMatchesTablePath: alternateMatchesTableURL.lastPathComponent,
            unresolvedTablePath: unresolvedTableURL.lastPathComponent,
            unresolvedFastaPath: unresolvedFastaURL.lastPathComponent,
            reassignmentsTablePath: wroteReassignments ? reassignmentsTableURL.lastPathComponent : nil,
            resolvedSampleMetadataPath: sampleMetadataSnapshot.resolvedRelativePath,
            sampleMetadataManifestPath: sampleMetadataSnapshot.manifestRelativePath,
            analysisSampleMetadataOriginalPath: sampleMetadataSnapshot.analysisOriginalRelativePath,
            provenancePath: ProvenanceWriter.provenanceFilename,
            createdAt: formatter.string(from: Date())
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
    }

    private func makeSamples(
        classified: ClassifiedReads,
        unresolvedSequences: [TwelveSUnresolvedSequence],
        sampleMetadata: ResolvedSampleMetadata
    ) -> [TwelveSAmpliconSampleResult] {
        classified.sampleOrder.map { sampleID in
            let inputReads = classified.inputReadsBySample[sampleID, default: 0]
            let exactReads = classified.exactReadsBySample[sampleID, default: 0]
            let ambiguousReads = classified.ambiguousReadsBySample[sampleID, default: 0]
            let reassignedReads = classified.reassignedReadsBySample[sampleID, default: 0]
            let discordantPairs = classified.discordantPairsBySample[sampleID, default: 0]
            // Reassigned reads are no longer ambiguous and are tracked as their
            // own channel (not folded into exact reads), so they leave the
            // unresolved pool too. A discordant pair is in no pool at all.
            let unresolvedReads = inputReads - exactReads - reassignedReads - discordantPairs
            let chimeraReads = unresolvedSequences.reduce(0) { total, unresolved in
                let count = unresolved.sampleCounts[sampleID, default: 0]
                return unresolved.chimeraStatus == .candidate || unresolved.chimeraStatus == .confirmed
                    ? total + count
                    : total
            }
            return TwelveSAmpliconSampleResult(
                sampleID: sampleID,
                displayName: Self.displayName(forSampleID: sampleID, sampleMetadata: sampleMetadata),
                inputReads: inputReads,
                exactMatchReads: exactReads,
                unresolvedReads: unresolvedReads,
                ambiguousExactReads: ambiguousReads,
                chimeraCandidateReads: chimeraReads,
                reassignedReads: reassignedReads,
                discordantPairs: discordantPairs,
                exactMatchPercent: percent(exactReads, inputReads),
                unresolvedPercent: percent(unresolvedReads, inputReads)
            )
        }
    }

    private static func displayName(forSampleID sampleID: String, sampleMetadata: ResolvedSampleMetadata) -> String {
        guard let record = sampleMetadata.records[sampleID] else { return sampleID }
        for preferredColumn in ["sample_name", "display_name", "name", "sample"] {
            if let value = metadataValue(in: record, normalizedColumn: preferredColumn) {
                return value
            }
        }
        return sampleID
    }

    private static func metadataValue(in record: [String: String], normalizedColumn: String) -> String? {
        for (key, value) in record
        where normalizeMetadataColumn(key) == normalizedColumn {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func normalizeMetadataColumn(_ column: String) -> String {
        column.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private func writeTargets(_ references: [TwelveSReferenceRecord], to url: URL) throws {
        var lines = [
            "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header"
        ]
        for reference in references {
            let target = reference.target
            let fields: [String] = [
                reference.targetID,
                target.displayName,
                target.scientificName ?? "",
                target.commonName ?? "",
                target.taxid ?? "",
                target.taxonGroup ?? "",
                target.taxonomy ?? "",
                target.nameSource ?? "",
                target.locus ?? "",
                target.length.map(String.init) ?? String(reference.sequence.count),
                reference.metadata["n_refs"] ?? "",
                reference.metadata["n_species"] ?? "",
                reference.metadata["primer_pairs"] ?? "",
                reference.sourceHeader,
            ]
            lines.append(fields.map(DelimitedText.tsvField).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeAlternateMatches(_ references: [TwelveSReferenceRecord], to url: URL) throws {
        var lines = [
            "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\treason"
        ]
        for reference in references {
            for match in reference.alternateMatches {
                lines.append([
                    reference.targetID,
                    match.displayName,
                    match.scientificName ?? "",
                    match.commonName ?? "",
                    match.taxid ?? "",
                    match.taxonGroup ?? "",
                    match.taxonomy ?? "",
                    match.nameSource ?? "",
                    match.reason ?? "",
                ].map(DelimitedText.tsvField).joined(separator: "\t"))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeCountMatrix(
        references: [TwelveSReferenceRecord],
        sampleOrder: [String],
        countsByTarget: [String: [String: Int]],
        to url: URL
    ) throws {
        var lines = [(["target_id"] + sampleOrder).joined(separator: "\t")]
        for reference in references {
            let counts = countsByTarget[reference.targetID, default: [:]]
            let row = [reference.targetID] + sampleOrder.map { String(counts[$0, default: 0]) }
            lines.append(row.map(DelimitedText.tsvField).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSamples(_ samples: [TwelveSAmpliconSampleResult], to url: URL) throws {
        var lines = [
            "sample\tsample_name\tsample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent\treassigned_reads\tdiscordant_pairs"
        ]
        for sample in samples {
            lines.append([
                sample.sampleID,
                sample.displayName,
                sample.sampleID,
                sample.displayName,
                String(sample.inputReads),
                String(sample.exactMatchReads),
                String(sample.unresolvedReads),
                String(sample.ambiguousExactReads),
                String(sample.chimeraCandidateReads),
                Self.formatDouble(sample.exactMatchPercent),
                Self.formatDouble(sample.unresolvedPercent),
                String(sample.reassignedReads),
                String(sample.discordantPairs),
            ].map(DelimitedText.tsvField).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReadFate(
        samples: [TwelveSAmpliconSampleResult],
        classified: ClassifiedReads,
        to url: URL
    ) throws {
        let readFate = TwelveSAmpliconReadFate(
            totalReads: samples.reduce(0) { $0 + $1.inputReads },
            exactMatchReads: samples.reduce(0) { $0 + $1.exactMatchReads },
            unresolvedReads: samples.reduce(0) { $0 + $1.unresolvedReads },
            ambiguousExactReads: samples.reduce(0) { $0 + $1.ambiguousExactReads },
            chimeraCandidateReads: samples.reduce(0) { $0 + $1.chimeraCandidateReads },
            discordantPairs: samples.reduce(0) { $0 + $1.discordantPairs },
            discordantPairsByReason: Dictionary(
                uniqueKeysWithValues: classified.discordantPairsByReason
                    .filter { $0.value > 0 }
                    .map { ($0.key.rawValue, $0.value) }
            ),
            pairedFragments: classified.pairedFragmentsBySample.values.reduce(0, +)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(readFate).write(to: url, options: .atomic)
    }

    private func writeSampleMetadataSnapshot(
        config: TwelveSAmpliconMatchingConfiguration,
        bundleURL: URL,
        sampleOrder: [String]
    ) throws -> SampleMetadataSnapshot {
        let metadataDirectory = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        var sourceTables = sourceFASTQSampleMetadataTables(
            inputURLs: config.inputFASTQs,
            sampleOrder: sampleOrder
        )
        let analysisOriginalRelativePath: String?
        if let sampleMetadataURL = config.sampleMetadata {
            let ext = sampleMetadataURL.pathExtension.isEmpty ? "txt" : sampleMetadataURL.pathExtension
            let originalURL = metadataDirectory.appendingPathComponent("analysis-sample-metadata.original.\(ext)")
            try FileManager.default.copyItem(at: sampleMetadataURL, to: originalURL)
            let data = try Data(contentsOf: sampleMetadataURL)
            let analysisTable = try SampleMetadataTable.parseDelimited(
                data: data,
                knownSampleIDs: sampleOrder,
                source: SampleMetadataSourceSummary(
                    kind: .analysisOverride,
                    path: sampleMetadataURL.standardizedFileURL.path
                )
            )
            sourceTables.append(analysisTable)
            analysisOriginalRelativePath = "metadata/\(originalURL.lastPathComponent)"
        } else {
            analysisOriginalRelativePath = nil
        }

        let resolved = SampleMetadataResolver.resolve(
            sampleIDs: sampleOrder,
            sourceTables: sourceTables
        )
        let resolvedURL = metadataDirectory.appendingPathComponent("resolved-sample-metadata.tsv")
        try resolved.writeTSV(to: resolvedURL)

        let manifest = TwelveSSampleMetadataSnapshotManifest(
            schemaVersion: 1,
            precedence: [
                "analysisOverride",
                "fastqBundle",
                "fastqFolder",
                "intrinsic",
            ],
            emptyOverrideCells: "empty analysis metadata cells do not clear lower-precedence values",
            sampleCount: sampleOrder.count,
            columns: resolved.columns,
            sources: resolved.sources,
            warnings: resolved.warnings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = metadataDirectory.appendingPathComponent("sample-metadata-manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return SampleMetadataSnapshot(
            resolved: resolved,
            resolvedRelativePath: "metadata/\(resolvedURL.lastPathComponent)",
            manifestRelativePath: "metadata/\(manifestURL.lastPathComponent)",
            analysisOriginalRelativePath: analysisOriginalRelativePath
        )
    }

    private func sourceFASTQSampleMetadataTables(
        inputURLs: [URL],
        sampleOrder: [String]
    ) -> [SampleMetadataTable] {
        var tables: [SampleMetadataTable] = []
        let sampleSet = Set(sampleOrder)
        for inputURL in inputURLs where FASTQBundle.isBundleURL(inputURL) {
            let sampleID = Self.sampleID(for: inputURL)
            guard sampleSet.contains(sampleID) else { continue }
            let parentURL = inputURL.deletingLastPathComponent()
            let resolvedFolderMetadata = FASTQFolderMetadata.loadResolved(from: parentURL)
            guard let metadata = resolvedFolderMetadata.samples[sampleID] else { continue }
            let record = metadata.sampleMetadataRecord
            guard !record.isEmpty else { continue }
            let sourceKind: SampleMetadataSourceKind
            let sourceURL: URL
            if FASTQBundleCSVMetadata.exists(in: inputURL) {
                sourceKind = .fastqBundle
                sourceURL = FASTQBundleCSVMetadata.metadataURL(in: inputURL)
            } else {
                sourceKind = .fastqFolder
                sourceURL = FASTQFolderMetadata.metadataURL(in: parentURL)
            }
            tables.append(
                SampleMetadataTable(
                    columns: Array(record.keys).sorted(),
                    records: [sampleID: record],
                    source: SampleMetadataSourceSummary(
                        kind: sourceKind,
                        path: sourceURL.standardizedFileURL.path,
                        totalRows: 1,
                        matchedSampleCount: 1,
                        unmatchedRowCount: 0,
                        missingSampleCount: max(0, sampleOrder.count - 1)
                    )
                )
            )
        }
        return tables
    }

    private func writeUnresolvedTable(_ unresolved: [TwelveSUnresolvedSequence], to url: URL) throws {
        var lines = ["sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote"]
        for sequence in unresolved {
            let sampleCounts = sequence.sampleCounts
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            lines.append([
                sequence.sequenceID,
                sequence.sequence,
                String(sequence.readCount),
                sampleCounts,
                sequence.chimeraStatus.rawValue,
                sequence.note ?? "",
            ].map(DelimitedText.tsvField).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReassignments(_ moves: [TwelveSAbundanceReassigner.Move], to url: URL) throws {
        var lines = ["sequence_id\tsample_id\tto_species\tto_target_id\treads\tdecided_by\tcandidate_species"]
        for move in moves.sorted(by: {
            $0.sequence != $1.sequence ? $0.sequence < $1.sequence : $0.sample < $1.sample
        }) {
            let decidedBy = move.decidedBy == .perSample ? "perSample" : "pooled"
            lines.append([
                move.sequence,
                move.sample,
                move.toSpecies,
                move.toTarget,
                String(move.reads),
                decidedBy,
                move.candidateSpecies.joined(separator: ";"),
            ].map(DelimitedText.tsvField).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeUnresolvedFasta(_ unresolved: [TwelveSUnresolvedSequence], to url: URL) throws {
        var text = ""
        for sequence in unresolved {
            text += ">\(sequence.sequenceID) read_count=\(sequence.readCount) chimera_status=\(sequence.chimeraStatus.rawValue)\n"
            text += "\(sequence.sequence)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func sampleID(for inputURL: URL) -> String {
        var name = inputURL.lastPathComponent
        if FASTQBundle.isBundleURL(inputURL) {
            return inputURL.deletingPathExtension().lastPathComponent
        }
        for suffix in [".fastq.gz", ".fq.gz", ".fastq", ".fq"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    private static func formatDouble(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func percent(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }
}
