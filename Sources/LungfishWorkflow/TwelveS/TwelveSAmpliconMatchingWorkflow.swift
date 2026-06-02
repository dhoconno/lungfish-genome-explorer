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
    public let threads: Int
    public let runChimeraReview: Bool
    public let forceOverwrite: Bool
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
        threads: Int = 1,
        runChimeraReview: Bool = true,
        forceOverwrite: Bool = false,
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
        self.threads = max(1, threads)
        self.runChimeraReview = runChimeraReview
        self.forceOverwrite = forceOverwrite
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

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "At least one merged FASTQ input is required."
        case let .missingInput(path):
            return "FASTQ input does not exist: \(path)"
        case let .missingReference(path):
            return "12S reference FASTA does not exist: \(path)"
        case let .outputExists(path):
            return "12S output bundle already exists: \(path)"
        case let .emptyReference(path):
            return "12S reference FASTA contains no records: \(path)"
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
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            if config.forceOverwrite {
                try FileManager.default.removeItem(at: bundleURL)
            } else {
                throw TwelveSAmpliconMatchingError.outputExists(bundleURL.path)
            }
        }

        progressHandler?(0.06, "Preparing 12S output workspace.")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        do {
            progressHandler?(0.12, "Loading 12S reference records.")
            let referenceIndex = try TwelveSReferenceIndex.load(
                from: config.referenceFASTA,
                metadataURL: config.referenceMetadata
            )
            guard !referenceIndex.records.isEmpty else {
                throw TwelveSAmpliconMatchingError.emptyReference(config.referenceFASTA.path)
            }
            progressHandler?(0.25, "Resolving FASTQ inputs.")
            let resolvedInputs = try await resolveInputs(config.inputFASTQs, workspace: bundleURL)
            let classifier = TwelveSAmpliconReadClassifier(
                references: referenceIndex.records,
                minimumSoftClipBases: config.minimumSoftClipBases,
                maximumIndelBases: config.maximumIndelBases
            )
            progressHandler?(0.40, "Matching reads to 12S references.")
            let classified = try await classifyInputs(
                resolvedInputs,
                classifier: classifier,
                references: referenceIndex.records,
                threads: config.threads
            )
            let unresolved = makeUnresolvedSequences(from: classified.unresolvedCounts)
            let chimeraResult: TwelveSChimeraReviewResult
            if config.runChimeraReview {
                progressHandler?(0.70, "Reviewing unresolved sequences for chimeras.")
                chimeraResult = try await chimeraReviewer.review(
                    unresolvedSequences: unresolved,
                    outputDirectory: bundleURL.appendingPathComponent("vsearch", isDirectory: true),
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
                chimeraResult: chimeraResult,
                startedAt: startedAt,
                completedAt: Date()
            )
            progressHandler?(1.0, "12S amplicon matching complete.")
            return TwelveSAmpliconMatchingResult(bundleURL: bundleURL.standardizedFileURL)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    private func validate(_ config: TwelveSAmpliconMatchingConfiguration) throws {
        guard !config.inputFASTQs.isEmpty else {
            throw TwelveSAmpliconMatchingError.noInputs
        }
        for input in config.inputFASTQs where !FileManager.default.fileExists(atPath: input.path) {
            throw TwelveSAmpliconMatchingError.missingInput(input.path)
        }
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

    private struct ClassifiedReads {
        var sampleOrder: [String] = []
        var inputReadsBySample: [String: Int] = [:]
        var exactReadsBySample: [String: Int] = [:]
        var ambiguousReadsBySample: [String: Int] = [:]
        var countsByTarget: [String: [String: Int]] = [:]
        var unresolvedCounts: [String: [String: Int]] = [:]
    }

    private struct ResolvedInput: Sendable {
        let sourceURL: URL
        let fastqURLs: [URL]
    }

    private struct SampleMetadataSnapshot: Sendable {
        let resolved: ResolvedSampleMetadata?
        let resolvedRelativePath: String?
        let manifestRelativePath: String?
        let analysisOriginalRelativePath: String?
    }

    private func resolveInputs(_ inputURLs: [URL], workspace: URL) async throws -> [ResolvedInput] {
        var resolved: [ResolvedInput] = []
        let resolver = FASTQSourceResolver()
        let tempDirectory = workspace.appendingPathComponent("materialized-fastq", isDirectory: true)
        for inputURL in inputURLs {
            if FASTQBundle.isBundleURL(inputURL) {
                let fastqs = try await resolver.resolve(
                    bundleURL: inputURL,
                    tempDirectory: tempDirectory,
                    progress: { _, _ in }
                )
                resolved.append(ResolvedInput(sourceURL: inputURL, fastqURLs: fastqs))
            } else {
                resolved.append(ResolvedInput(sourceURL: inputURL, fastqURLs: [inputURL]))
            }
        }
        return resolved
    }

    private func classifyInputs(
        _ inputs: [ResolvedInput],
        classifier: TwelveSAmpliconReadClassifier,
        references: [TwelveSReferenceRecord],
        threads: Int
    ) async throws -> ClassifiedReads {
        var classified = ClassifiedReads()
        var perSampleSequenceCounts: [(sampleID: String, counts: [String: Int], inputReads: Int)] = []
        var uniqueSequences = Set<String>()

        for input in inputs {
            let sampleID = Self.sampleID(for: input.sourceURL)
            classified.sampleOrder.append(sampleID)
            var counts: [String: Int] = [:]
            var inputReads = 0
            for fastqURL in input.fastqURLs {
                let reader = TwelveSFastqReader(url: fastqURL)
                for try await record in reader.records() {
                    let normalizedSequence = record.sequence.uppercased()
                    counts[normalizedSequence, default: 0] += 1
                    uniqueSequences.insert(normalizedSequence)
                    inputReads += 1
                }
            }
            classified.inputReadsBySample[sampleID, default: 0] += inputReads
            perSampleSequenceCounts.append((sampleID: sampleID, counts: counts, inputReads: inputReads))
        }

        let classifications = await classifyUniqueSequences(
            Array(uniqueSequences).sorted(),
            classifier: classifier,
            threads: threads
        )
        var ambiguousCandidates: [String: [String]] = [:]
        for sample in perSampleSequenceCounts {
            for (normalizedSequence, count) in sample.counts {
                guard let classification = classifications[normalizedSequence] else { continue }
                switch classification {
                case let .exact(targetID, _):
                    classified.exactReadsBySample[sample.sampleID, default: 0] += count
                    classified.countsByTarget[targetID, default: [:]][sample.sampleID, default: 0] += count
                case let .ambiguous(targetIDs):
                    classified.ambiguousReadsBySample[sample.sampleID, default: 0] += count
                    classified.unresolvedCounts[normalizedSequence, default: [:]][sample.sampleID, default: 0] += count
                    ambiguousCandidates[normalizedSequence] = targetIDs
                case .unresolved:
                    classified.unresolvedCounts[normalizedSequence, default: [:]][sample.sampleID, default: 0] += count
                }
            }
        }

        // Pass B: reassign cross-species identical-sequence ambiguous reads to the
        // most-abundant candidate species (strict plurality). See
        // TwelveSAbundanceReassigner.
        applyAbundanceReassignment(&classified, ambiguousCandidates: ambiguousCandidates, references: references)

        return classified
    }

    /// Maps each species (display name) to its canonical target — the longest
    /// reference sequence, tie-broken by smallest targetID — matching the
    /// classifier's same-species canonicalization.
    private func canonicalTargetForSpecies(_ references: [TwelveSReferenceRecord]) -> [String: String] {
        var best: [String: TwelveSReferenceRecord] = [:]
        for ref in references {
            if let existing = best[ref.displayName] {
                if ref.sequence.count > existing.sequence.count
                    || (ref.sequence.count == existing.sequence.count && ref.targetID < existing.targetID) {
                    best[ref.displayName] = ref
                }
            } else {
                best[ref.displayName] = ref
            }
        }
        return best.mapValues(\.targetID)
    }

    private func applyAbundanceReassignment(
        _ classified: inout ClassifiedReads,
        ambiguousCandidates: [String: [String]],
        references: [TwelveSReferenceRecord]
    ) {
        guard !ambiguousCandidates.isEmpty else { return }
        let speciesForTarget = Dictionary(
            references.map { ($0.targetID, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        // Snapshot the per-sample unresolved counts before reassignment so we can
        // shift the moved reads from ambiguous→exact per sample.
        let unresolvedBefore = classified.unresolvedCounts
        let result = TwelveSAbundanceReassigner.reassign(
            ambiguousCandidates: ambiguousCandidates,
            unresolvedCounts: classified.unresolvedCounts,
            countsByTarget: classified.countsByTarget,
            speciesForTarget: speciesForTarget,
            canonicalTargetForSpecies: canonicalTargetForSpecies(references)
        )
        guard !result.moves.isEmpty else { return }

        classified.countsByTarget = result.countsByTarget
        classified.unresolvedCounts = result.unresolvedCounts

        // Moved reads shift from ambiguous to exact, per sample.
        var movedTotal = 0
        for move in result.moves {
            guard let perSample = unresolvedBefore[move.sequence] else { continue }
            for (sampleID, reads) in perSample {
                classified.exactReadsBySample[sampleID, default: 0] += reads
                classified.ambiguousReadsBySample[sampleID, default: 0] -= reads
                movedTotal += reads
            }
        }
        let speciesMoves = result.moves
            .map { "\($0.toSpecies) (+\($0.reads))" }
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

    private func makeUnresolvedSequences(
        from unresolvedCounts: [String: [String: Int]]
    ) -> [TwelveSUnresolvedSequence] {
        unresolvedCounts
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
                TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_\(index + 1)",
                    sequence: entry.sequence,
                    readCount: entry.readCount,
                    sampleCounts: entry.sampleCounts,
                    chimeraStatus: .notReviewed
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

        try FileManager.default.copyItem(at: config.referenceFASTA, to: referenceCopyURL)
        try writeTargets(references, to: targetTableURL)
        try writeAlternateMatches(references, to: alternateMatchesTableURL)
        try writeCountMatrix(
            references: references,
            sampleOrder: classified.sampleOrder,
            countsByTarget: classified.countsByTarget,
            to: countMatrixURL
        )
        let samples = makeSamples(classified: classified, unresolvedSequences: unresolvedSequences)
        let sampleMetadataSnapshot = try writeSampleMetadataSnapshot(
            config: config,
            bundleURL: bundleURL,
            sampleOrder: classified.sampleOrder
        )
        try writeSamples(samples, to: sampleTableURL)
        try writeReadFate(samples: samples, to: readFateURL)
        try writeUnresolvedTable(unresolvedSequences, to: unresolvedTableURL)
        try writeUnresolvedFasta(unresolvedSequences, to: unresolvedFastaURL)

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
        unresolvedSequences: [TwelveSUnresolvedSequence]
    ) -> [TwelveSAmpliconSampleResult] {
        classified.sampleOrder.map { sampleID in
            let inputReads = classified.inputReadsBySample[sampleID, default: 0]
            let exactReads = classified.exactReadsBySample[sampleID, default: 0]
            let ambiguousReads = classified.ambiguousReadsBySample[sampleID, default: 0]
            let unresolvedReads = inputReads - exactReads
            let chimeraReads = unresolvedSequences.reduce(0) { total, unresolved in
                let count = unresolved.sampleCounts[sampleID, default: 0]
                return unresolved.chimeraStatus == .candidate || unresolved.chimeraStatus == .confirmed
                    ? total + count
                    : total
            }
            return TwelveSAmpliconSampleResult(
                sampleID: sampleID,
                displayName: sampleID,
                inputReads: inputReads,
                exactMatchReads: exactReads,
                unresolvedReads: unresolvedReads,
                ambiguousExactReads: ambiguousReads,
                chimeraCandidateReads: chimeraReads,
                exactMatchPercent: percent(exactReads, inputReads),
                unresolvedPercent: percent(unresolvedReads, inputReads)
            )
        }
    }

    private func writeTargets(_ references: [TwelveSReferenceRecord], to url: URL) throws {
        var lines = [
            "target_id\tdisplay_name\tscientific_name\tcommon_name\ttaxid\ttaxon_group\ttaxonomy\tname_source\tlocus\tlength\tn_refs\tn_species\tprimer_pairs\tsource_header"
        ]
        for reference in references {
            let target = reference.target
            lines.append([
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
            ].map(Self.tsvEscape).joined(separator: "\t"))
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
                ].map(Self.tsvEscape).joined(separator: "\t"))
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
            lines.append(row.map(Self.tsvEscape).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSamples(_ samples: [TwelveSAmpliconSampleResult], to url: URL) throws {
        var lines = [
            "sample_id\tdisplay_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent"
        ]
        for sample in samples {
            lines.append([
                sample.sampleID,
                sample.displayName,
                String(sample.inputReads),
                String(sample.exactMatchReads),
                String(sample.unresolvedReads),
                String(sample.ambiguousExactReads),
                String(sample.chimeraCandidateReads),
                Self.formatDouble(sample.exactMatchPercent),
                Self.formatDouble(sample.unresolvedPercent),
            ].map(Self.tsvEscape).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReadFate(samples: [TwelveSAmpliconSampleResult], to url: URL) throws {
        let readFate = TwelveSAmpliconReadFate(
            totalReads: samples.reduce(0) { $0 + $1.inputReads },
            exactMatchReads: samples.reduce(0) { $0 + $1.exactMatchReads },
            unresolvedReads: samples.reduce(0) { $0 + $1.unresolvedReads },
            ambiguousExactReads: samples.reduce(0) { $0 + $1.ambiguousExactReads },
            chimeraCandidateReads: samples.reduce(0) { $0 + $1.chimeraCandidateReads }
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
            ].map(Self.tsvEscape).joined(separator: "\t"))
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

    private func writeProvenance(
        config: TwelveSAmpliconMatchingConfiguration,
        bundleURL: URL,
        chimeraResult: TwelveSChimeraReviewResult,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv: [String]
        if config.argv.isEmpty {
            argv = replayArgv(for: config)
        } else {
            argv = config.argv
        }
        let referenceOptionURL = config.referenceBundleURL ?? config.referenceFASTA
        var explicitOptions: [String: ParameterValue] = [
            "inputs": .array(config.inputFASTQs.map { .file($0) }),
            "reference": .file(referenceOptionURL),
            "outputDirectory": .file(config.outputDirectory),
            "outputName": .string(config.outputName),
            "minimumSoftClipBases": .integer(config.minimumSoftClipBases),
            "maximumIndelBases": .integer(config.maximumIndelBases),
            "threads": .integer(config.threads),
            "runChimeraReview": .boolean(config.runChimeraReview),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ]
        var resolvedOptions: [String: ParameterValue] = [
            "minimumSoftClipBases": .integer(config.minimumSoftClipBases),
            "maximumIndelBases": .integer(config.maximumIndelBases),
            "threads": .integer(config.threads),
            "runChimeraReview": .boolean(config.runChimeraReview),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ]
        if let referenceBundleURL = config.referenceBundleURL {
            explicitOptions["referenceBundle"] = .file(referenceBundleURL)
            resolvedOptions["referenceBundle"] = .file(referenceBundleURL)
            resolvedOptions["referenceFASTA"] = .file(config.referenceFASTA)
        }
        if let referenceMetadata = config.referenceMetadata {
            explicitOptions["referenceMetadata"] = .file(referenceMetadata)
            resolvedOptions["referenceMetadata"] = .file(referenceMetadata)
        }
        if let sampleMetadata = config.sampleMetadata {
            explicitOptions["sampleMetadata"] = .file(sampleMetadata)
            resolvedOptions["sampleMetadata"] = .file(sampleMetadata)
        }
        let fastqMetadataURLs = Self.fastqMetadataInputURLs(for: config.inputFASTQs)
        if !fastqMetadataURLs.isEmpty {
            resolvedOptions["fastqMetadataInputs"] = .array(fastqMetadataURLs.map { .file($0) })
        }
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish fastq 12s-match",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(Self.commandLine(from: argv))
        .options(
            explicit: explicitOptions,
            defaults: [
                "minimumSoftClipBases": .integer(1),
                "maximumIndelBases": .integer(3),
                "threads": .integer(1),
                "runChimeraReview": .boolean(true),
                "forceOverwrite": .boolean(false),
            ],
            resolved: resolvedOptions
        )
        .runtime(ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser))

        let inputDescriptors = try config.inputFASTQs.map { input in
            if FASTQBundle.isBundleURL(input) {
                return try Self.directoryDescriptor(url: input, format: .unknown, role: .input)
            }
            return try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        }
        let referenceDescriptor = try ProvenanceFileDescriptor.file(
            url: config.referenceFASTA,
            format: .fasta,
            role: .reference
        )
        var matchingStepInputs = inputDescriptors
        if let referenceBundleURL = config.referenceBundleURL {
            matchingStepInputs.append(
                try Self.directoryDescriptor(url: referenceBundleURL, format: .unknown, role: .reference)
            )
        }
        matchingStepInputs.append(referenceDescriptor)
        if let referenceMetadata = config.referenceMetadata {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: referenceMetadata, format: .text, role: .reference)
            )
        }
        if let sampleMetadata = config.sampleMetadata {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: sampleMetadata, format: .text, role: .input)
            )
        }
        for metadataURL in fastqMetadataURLs {
            matchingStepInputs.append(
                try ProvenanceFileDescriptor.file(url: metadataURL, format: .text, role: .input)
            )
        }

        let payloadDescriptors = try bundlePayloadURLs(in: bundleURL).map {
            try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .output)
        }
        let matchingStepOutputs = [
            try Self.directoryDescriptor(url: bundleURL, format: .unknown, role: .output)
        ] + payloadDescriptors
        let matchingStep = ProvenanceStep(
            toolName: "lungfish-cli",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: Self.commandLine(from: argv),
            inputs: matchingStepInputs,
            outputs: matchingStepOutputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
        builder = builder.step(matchingStep)

        if !chimeraResult.argv.isEmpty {
            let step = ProvenanceStep(
                toolName: NativeTool.vsearch.executableName,
                toolVersion: chimeraResult.toolVersion ?? "unknown",
                argv: chimeraResult.argv,
                durableReplayArgv: chimeraResult.argv,
                reproducibleCommand: Self.commandLine(from: chimeraResult.argv),
                inputs: try chimeraResult.inputs.map {
                    try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .input)
                },
                outputs: try chimeraResult.outputs.map {
                    try ProvenanceFileDescriptor.file(url: $0, format: Self.fileFormat(for: $0), role: .output)
                },
                exitStatus: Int(chimeraResult.exitStatus),
                wallTimeSeconds: zip(chimeraResult.startedAt, chimeraResult.completedAt).map { $1.timeIntervalSince($0) },
                stderr: chimeraResult.stderr,
                startedAt: chimeraResult.startedAt,
                completedAt: chimeraResult.completedAt
            )
            builder = builder.step(step)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            stderr: chimeraResult.stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )
        try ProvenanceWriter().write(envelope, to: bundleURL)
    }

    private static func fastqMetadataInputURLs(for inputURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for inputURL in inputURLs where FASTQBundle.isBundleURL(inputURL) {
            let candidate: URL?
            if FASTQBundleCSVMetadata.exists(in: inputURL) {
                candidate = FASTQBundleCSVMetadata.metadataURL(in: inputURL)
            } else {
                let folderURL = inputURL.deletingLastPathComponent()
                candidate = FASTQFolderMetadata.exists(in: folderURL)
                    ? FASTQFolderMetadata.metadataURL(in: folderURL)
                    : nil
            }
            guard let candidate = candidate?.standardizedFileURL,
                  FileManager.default.fileExists(atPath: candidate.path),
                  seen.insert(candidate.path).inserted else {
                continue
            }
            urls.append(candidate)
        }
        return urls
    }

    private func replayArgv(for config: TwelveSAmpliconMatchingConfiguration) -> [String] {
        let referenceURL = config.referenceBundleURL ?? config.referenceFASTA
        var argv = [
            "lungfish-cli", "fastq", "12s-match",
        ] + config.inputFASTQs.map(\.path) + [
            "--reference", referenceURL.path,
        ]
        if let referenceMetadata = config.referenceMetadata,
           !isBundledReferenceMetadata(referenceMetadata, for: config.referenceBundleURL) {
            argv += ["--reference-metadata", referenceMetadata.path]
        }
        if let sampleMetadata = config.sampleMetadata {
            argv += ["--sample-metadata", sampleMetadata.path]
        }
        argv += [
            "--output-dir", config.outputDirectory.path,
            "--output-name", config.outputName,
        ]
        if config.minimumSoftClipBases != 1 {
            argv += ["--min-soft-clip", String(config.minimumSoftClipBases)]
        }
        if config.maximumIndelBases != 3 {
            argv += ["--max-indels", String(config.maximumIndelBases)]
        }
        if config.threads != 1 {
            argv += ["--threads", String(config.threads)]
        }
        if !config.runChimeraReview {
            argv.append("--no-chimera-review")
        }
        if config.forceOverwrite {
            argv.append("--force")
        }
        return argv
    }

    private func isBundledReferenceMetadata(_ metadataURL: URL, for bundleURL: URL?) -> Bool {
        guard let bundleURL,
              let bundledURL = TwelveSReferenceBundle.targetMetadataURL(in: bundleURL) else {
            return false
        }
        return metadataURL.standardizedFileURL == bundledURL.standardizedFileURL
    }

    private func bundlePayloadURLs(in bundleURL: URL) -> [URL] {
        var urls = [
            TwelveSAmpliconResultBundle.manifestURL(in: bundleURL),
            bundleURL.appendingPathComponent("reference.fa"),
            bundleURL.appendingPathComponent("targets.tsv"),
            bundleURL.appendingPathComponent("target-alternate-matches.tsv"),
            bundleURL.appendingPathComponent("sample-target-counts.tsv"),
            bundleURL.appendingPathComponent("samples.tsv"),
            bundleURL.appendingPathComponent("read-fate.json"),
            bundleURL.appendingPathComponent("unresolved-sequences.tsv"),
            bundleURL.appendingPathComponent("unresolved-sequences.fasta"),
        ]
        let metadataDirectory = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        if let metadataPayloads = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: metadataPayloads.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func fileFormat(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "fa", "fasta", "fna":
            return .fasta
        case "fastq", "fq":
            return .fastq
        case "json":
            return .json
        case "tsv", "txt":
            return .text
        default:
            return .unknown
        }
    }

    private static func directoryDescriptor(
        url: URL,
        format: FileFormat?,
        role: FileRole
    ) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: role)
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: format,
            role: role
        )
    }

    private static func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    private static func sampleID(for inputURL: URL) -> String {
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

    private static func tsvEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func formatDouble(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func commandLine(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private func percent(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }
}

private func zip<T, U>(_ first: T?, _ second: U?) -> (T, U)? {
    guard let first, let second else { return nil }
    return (first, second)
}
