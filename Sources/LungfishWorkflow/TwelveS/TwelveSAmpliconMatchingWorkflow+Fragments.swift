// TwelveSAmpliconMatchingWorkflow+Fragments.swift - Reading a sample's reads as fragments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 12S matching counts fragments. A merged read, an orphan and a read of a
// single-end run are one fragment each. An unmerged pair is one fragment
// whose two mates are read together, R2 as the reverse complement of the
// record as sequenced, because the matcher reads the forward strand. An
// orphan whose name marks it as mate 2 is read as its reverse complement too.
// docs/contracts/READ-PAIRING.md says how the resolver hands the reads over.

import Foundation
import LungfishCore
import LungfishIO

/// One fragment of a sample as 12S matching counts it.
enum TwelveSFragment: Equatable, Sendable {
    /// A merged read, an orphan or a read of a single-end run, on the
    /// forward strand of its fragment.
    case single(sequence: String, weight: Int)
    /// An unmerged pair. `r2` is the reverse complement of the R2 record.
    case pair(r1: String, r2: String, weight: Int)
}

extension TwelveSAmpliconMatchingWorkflow {

    static let consumerID = "twelve-s.amplicon-matching"

    /// The capability 12S matching declares, pairs and single reads in one
    /// run as separate files, so a mixed stream reaches it split by name.
    static var readPairingCapability: ReadPairingCapability {
        ReadPairingCapabilityRegistry.capability(for: consumerID) ?? .bothInOneRunAsSeparateFiles
    }

    /// The folder beside the output that holds everything a run writes before
    /// it replaces the earlier output: materialized and split reads and the
    /// chimera review. It is removed when the run ends, however it ends.
    static func scratchDirectory(for config: TwelveSAmpliconMatchingConfiguration) -> URL {
        config.outputDirectory.appendingPathComponent(
            ".lungfish-12s-scratch-\(UUID().uuidString.lowercased().prefix(8))",
            isDirectory: true
        )
    }

    // MARK: - Fragments of a plan

    /// Visits every fragment of `plan` once, mate pairs first, then single
    /// reads, then any stream that mixes both. Returns what the reading warns
    /// of, such as mates paired by position.
    @discardableResult
    static func readFragments(
        of plan: ReadSetPlan,
        _ body: (TwelveSFragment) throws -> Void
    ) async throws -> [String] {
        var warnings: [String] = []
        for run in plan.runs {
            for pair in run.matePairs {
                switch pair.files {
                case let .separate(r1, r2):
                    if let warning = try await readSeparateMates(r1: r1, r2: r2, body) {
                        warnings.append(warning)
                    }
                case let .interleaved(url):
                    try await readInterleavedMates(in: url, body)
                }
            }
            for single in run.singleReads {
                for try await record in TwelveSFastqReader(url: single.url).records() {
                    try body(singleRead(record, role: single.role, platform: plan.sequencingPlatform))
                }
            }
            for stream in run.mixedStreams {
                try await readMixedStream(
                    in: stream.url, role: stream.singleReadRole, platform: plan.sequencingPlatform, body
                )
            }
        }
        return warnings
    }

    /// R1 and R2 files whose records correspond by position, as the files of
    /// a recorded pair do. The names are checked record by record with the
    /// rule the materializer uses (`FASTQPairInterleaver.recordedMates`, the
    /// owner's N2 rule). Names whose mate numbers say they are not one
    /// fragment stop the run. Names with no mate number are paired by
    /// position, as a legacy bundle names them, and the returned warning
    /// says so, in the materializer's words.
    private static func readSeparateMates(
        r1: URL,
        r2: URL,
        _ body: (TwelveSFragment) throws -> Void
    ) async throws -> String? {
        var first = TwelveSFastqReader(url: r1).records().makeAsyncIterator()
        var second = TwelveSFastqReader(url: r2).records().makeAsyncIterator()
        var pairs = 0
        var pairedByPosition = 0
        var firstPairedByPosition: (String, String)?
        while true {
            let mate1 = try await first.next()
            let mate2 = try await second.next()
            switch (mate1, mate2) {
            case (nil, nil):
                guard let names = firstPairedByPosition else { return nil }
                return "Warning: \(pairedByPosition) of the \(pairs) record pairs of \(r1.lastPathComponent) and "
                    + "\(r2.lastPathComponent) carry no mate number in their names, the first being "
                    + "'\(names.0)' and '\(names.1)', so they were paired by position."
            case let (mate1?, mate2?):
                switch FASTQPairInterleaver.recordedMates(mate1.identifier, mate2.identifier) {
                case .mates:
                    break
                case .unmarked:
                    pairedByPosition += 1
                    if firstPairedByPosition == nil {
                        firstPairedByPosition = (mate1.identifier, mate2.identifier)
                    }
                case .notMates:
                    throw TwelveSAmpliconMatchingError.mateMismatch(
                        "Record \(pairs + 1) of \(r1.lastPathComponent) is \(readName(mate1)) and of "
                            + "\(r2.lastPathComponent) is \(readName(mate2)), so the two files do not hold "
                            + "the same fragments in the same order."
                    )
                }
                pairs += 1
                try body(.pair(
                    r1: normalized(mate1.sequence),
                    r2: reverseComplement(mate2.sequence),
                    weight: mate1.readCountWeight
                ))
            case (nil, .some), (.some, nil):
                throw TwelveSAmpliconMatchingError.mateMismatch(
                    "\(r1.lastPathComponent) and \(r2.lastPathComponent) hold different numbers of records "
                        + "(\(pairs) pairs matched before one file ended), so the pairs cannot be matched."
                )
            }
        }
    }

    /// One file in which every R1 record is followed by its R2 record.
    private static func readInterleavedMates(
        in url: URL,
        _ body: (TwelveSFragment) throws -> Void
    ) async throws {
        var pending: TwelveSFastqRecord?
        var pairs = 0
        for try await record in TwelveSFastqReader(url: url).records() {
            guard let mate1 = pending else {
                pending = record
                continue
            }
            guard FASTQReadLayoutClassifier.areMates(mate1.identifier, record.identifier) else {
                throw TwelveSAmpliconMatchingError.mateMismatch(
                    "Records \(2 * pairs + 1) and \(2 * pairs + 2) of \(url.lastPathComponent) are "
                        + "\(readName(mate1)) and \(readName(record)), not the two mates of one fragment."
                )
            }
            pairs += 1
            pending = nil
            try body(.pair(
                r1: normalized(mate1.sequence),
                r2: reverseComplement(record.sequence),
                weight: mate1.readCountWeight
            ))
        }
        if let mate1 = pending {
            throw TwelveSAmpliconMatchingError.mateMismatch(
                "\(url.lastPathComponent) holds an odd number of records (\(2 * pairs + 1)), "
                    + "so its last record \(readName(mate1)) has no mate."
            )
        }
    }

    /// One file of adjacent mate pairs and single reads, paired by name. The
    /// resolver splits such a file for this capability, so this path is a
    /// safety net and never a silent record-by-record count.
    private static func readMixedStream(
        in url: URL,
        role: ReadSetReadRole,
        platform: SequencingPlatform?,
        _ body: (TwelveSFragment) throws -> Void
    ) async throws {
        var pending: TwelveSFastqRecord?
        for try await record in TwelveSFastqReader(url: url).records() {
            guard let previous = pending else {
                pending = record
                continue
            }
            if FASTQReadLayoutClassifier.areMates(previous.identifier, record.identifier) {
                pending = nil
                try body(.pair(
                    r1: normalized(previous.sequence),
                    r2: reverseComplement(record.sequence),
                    weight: previous.readCountWeight
                ))
            } else {
                pending = record
                try body(singleRead(previous, role: role, platform: platform))
            }
        }
        if let previous = pending {
            try body(singleRead(previous, role: role, platform: platform))
        }
    }

    /// A read without a mate, on the forward strand of its fragment as the
    /// matcher reads it. A read whose name marks it as mate 2, such as the
    /// orphan R2 of a repair derivative, is the reverse strand of its
    /// fragment, so it is read as its reverse complement, as the R2 of a pair
    /// is. A merged read keeps R1's orientation whatever its name, and long
    /// reads, which are never paired, are read as sequenced (review A, N5).
    static func singleRead(
        _ record: TwelveSFastqRecord,
        role: ReadSetReadRole,
        platform: SequencingPlatform?
    ) -> TwelveSFragment {
        let onReverseStrand = role != .merged
            && !ReadSetResolver.isLongRead(platform)
            && marksMateTwo(record.identifier)
        return .single(
            sequence: onReverseStrand ? reverseComplement(record.sequence) : normalized(record.sequence),
            weight: record.readCountWeight
        )
    }

    /// Whether a header names mate 2 by `/2` on its read ID or a Casava
    /// ` 2:` comment, the marks `FASTQReadLayoutClassifier` pairs mates by.
    static func marksMateTwo(_ header: String) -> Bool {
        let readID = String(header.prefix { $0 != " " && $0 != "\t" })
        return (ReadPair.parse(from: readID) ?? ReadPair.parse(from: header))?.readNumber == 2
    }

    static func normalized(_ sequence: String) -> String {
        sequence.uppercased()
    }

    /// The forward-strand sequence of an R2 record.
    static func reverseComplement(_ sequence: String) -> String {
        TranslationEngine.reverseComplement(normalized(sequence))
    }

    private static func readName(_ record: TwelveSFastqRecord) -> String {
        record.identifier.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? record.identifier
    }

    // MARK: - What the run tells the user

    /// The progress line that names the fragments counted and the pairs left
    /// out, for the CLI's stderr and the Operations panel.
    static func fragmentSummary(
        singleReads: Int,
        pairs: Int,
        discordantByReason: [TwelveSPairDiscordance: Int]
    ) -> String {
        let fragments = singleReads + pairs
        var text = pairs == 0
            ? "Counted \(fragments) fragments, all merged or single reads."
            : "Counted \(fragments) fragments, \(singleReads) merged or single reads and \(pairs) pairs."
        let discordant = discordantByReason.values.reduce(0, +)
        if discordant > 0 {
            text += " Left out \(discordant) discordant \(discordant == 1 ? "pair" : "pairs")"
                + " (\(reasonList(discordantByReason)))."
        }
        return text
    }

    /// `1 pair with different targets, 1 pair with one mate unresolved`, in
    /// the order of the reasons.
    static func reasonList(_ counts: [TwelveSPairDiscordance: Int]) -> String {
        TwelveSPairDiscordance.allCases
            .compactMap { reason in
                guard let count = counts[reason], count > 0 else { return nil }
                return TwelveSPairDiscordance.countPhrase(count, reasonName: reason.displayName)
            }
            .joined(separator: ", ")
    }

    // MARK: - Provenance of the read-set steps

    /// A split or interleave the resolver wrote, as a provenance step. Its
    /// files are checksummed now, while they exist. They live in the scratch
    /// folder and are removed when the run ends, which the step records. The
    /// step runs in process, so its argv describes it and is not a command to
    /// run, and it records no durable replay, as the Kraken2 read-set steps
    /// do (review A, N2). The run's own replay is the whole 12S command.
    static func provenanceStep(for step: ReadSetStep) throws -> ProvenanceStep {
        ProvenanceStep(
            toolName: step.toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: step.command,
            durableReplayArgv: nil,
            reproducibleCommand: nil,
            resolvedOptions: [
                "pairs": .integer(step.pairCount),
                "singleReads": .integer(step.singleReadCount),
                "intermediateOutputs": .boolean(true),
                "outputsRemovedAfterRun": .boolean(true),
            ],
            inputs: try step.inputURLs.map { try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .input) },
            outputs: try step.outputURLs.map { try ProvenanceFileDescriptor.file(url: $0, format: .fastq, role: .output) },
            exitStatus: 0,
            wallTimeSeconds: max(0, step.endedAt.timeIntervalSince(step.startedAt)),
            startedAt: step.startedAt,
            completedAt: step.endedAt
        )
    }

    /// The envelope without the run-level records of files under `scratch`,
    /// which the run removed. The steps keep their historically true records,
    /// as the Kraken2 pipeline's read-set steps do.
    static func droppingScratchFiles(from envelope: ProvenanceEnvelope, under scratch: URL) -> ProvenanceEnvelope {
        let prefix = scratch.standardizedFileURL.path + "/"
        func keep(_ descriptor: ProvenanceFileDescriptor) -> Bool {
            !URL(fileURLWithPath: descriptor.path).standardizedFileURL.path.hasPrefix(prefix)
        }
        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files.filter(keep),
            output: envelope.output,
            outputs: envelope.outputs.filter(keep),
            steps: envelope.steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: envelope.signatures,
            legacyWorkflowRun: envelope.legacyRun
        )
    }
}

extension TwelveSChimeraReviewResult {
    /// The same review with every file under `source` recorded under
    /// `destination`, for a review run in the scratch folder whose files
    /// then moved into the result bundle.
    func relocatingFiles(from source: URL, to destination: URL) -> TwelveSChimeraReviewResult {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        func relocated(_ path: String) -> String {
            if path == sourcePath { return destinationPath }
            if path.hasPrefix(sourcePath + "/") { return destinationPath + path.dropFirst(sourcePath.count) }
            return path
        }
        func relocated(_ url: URL) -> URL {
            URL(fileURLWithPath: relocated(url.standardizedFileURL.path))
        }
        return TwelveSChimeraReviewResult(
            statusesBySequenceID: statusesBySequenceID,
            stderr: stderr,
            exitStatus: exitStatus,
            argv: argv.map(relocated),
            startedAt: startedAt,
            completedAt: completedAt,
            inputs: inputs.map(relocated),
            outputs: outputs.map(relocated),
            toolVersion: toolVersion
        )
    }
}
