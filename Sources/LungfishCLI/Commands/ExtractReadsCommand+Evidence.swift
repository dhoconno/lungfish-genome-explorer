// ExtractReadsCommand+Evidence.swift - extract reads on alignment evidence, with its index and filters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The stagers a run on alignment evidence uses, which a test stands in for.
struct ExtractReadsEvidenceStages: Sendable {
    /// The alignment's header, which a region run reads before it stages, to see that each region is on a contig.
    var header: @Sendable (AlignmentReadExtractionInvocation) async throws -> String = { invocation in
        try await AlignmentDataProvider(
            alignmentPath: invocation.alignmentURL.path,
            indexPath: invocation.indexURL.path,
            format: invocation.alignmentURL.pathExtension.lowercased() == "cram" ? .cram : .bam,
            referenceFastaPath: invocation.decodingReferenceURL?.path
        ).fetchHeader()
    }
    var region: @Sendable (BAMRegionExtractionConfig) async throws -> AlignmentReadExtractionTransaction = {
        try await AlignmentReadExtractionStager().stageRegion(config: $0)
    }
    var sources: @Sendable (ReadIDExtractionConfig, Int, String?) async throws -> AlignmentReadExtractionTransaction = {
        try await AlignmentReadExtractionStager().stageReadIDsFromSourceFASTQs(config: $0, recordsWithoutSequence: $1, missingSequenceMessage: $2)
    }
    var alignment: @Sendable (ReadIDBAMExtractionConfig, Int, String?) async throws -> AlignmentReadExtractionTransaction = {
        try await AlignmentReadExtractionStager().stageReadIDsFromBAM(config: $0, recordsWithoutSequence: $1, missingSequenceMessage: $2)
    }
    /// Runs after the staging, before the second check of the evidence.
    var beforeSecondCheck: @Sendable () async throws -> Void = {}
}

extension ExtractReadsSubcommand {
    /// Whether an option that needs `--index` was given.
    var evidenceOptionGiven: Bool {
        decodingReferenceFile != nil || minimumMapQ != nil || excludedFlags != nil || !readGroups.isEmpty
            || recordsWithoutSequence != 0
    }

    /// Checks a run given `--index`, which publishes reads of alignment evidence (Phase 2.10 lane A51).
    func validateEvidenceRun() throws {
        func refusal(_ message: String) -> CLIError { .validationFailed(errors: [message]) }
        guard byRegion || (byId && bamFile != nil) else {
            throw refusal("--index takes --by-region, or --by-id with --bam")
        }
        guard URL(fileURLWithPath: output).pathExtension.lowercased() == FASTQBundle.directoryExtension else {
            throw refusal("With --index, --output names the .\(FASTQBundle.directoryExtension) bundle the run publishes")
        }
        guard !createBundle, !excludeUnmapped, classifierFormat == "fastq" else {
            throw refusal("With --index the run publishes a FASTQ bundle and filters with --exclude-flags, so it takes no --bundle, --exclude-unmapped or --read-format fasta")
        }
        if let minimumMapQ, minimumMapQ < 0 {
            throw refusal("--min-mapq must not be negative")
        }
        if let excludedFlags, !(0...Int(UInt16.max)).contains(excludedFlags) {
            throw refusal("--exclude-flags must be a SAM flag value from 0 to 65535")
        }
        if byRegion {
            guard !regions.isEmpty else { throw refusal("At least one --region is required with --by-region") }
            guard recordsWithoutSequence == 0 else { throw refusal("--records-without-sequence applies to --by-id") }
            return
        }
        guard idsFile != nil else { throw refusal("--ids is required with --by-id") }
        guard minimumMapQ == nil, excludedFlags == nil, readGroups.isEmpty else {
            throw refusal("--min-mapq, --exclude-flags and --read-group apply to --by-region")
        }
        guard recordsWithoutSequence >= 0 else { throw refusal("--records-without-sequence must not be negative") }
        guard !(keepReadPairs && noKeepReadPairs) else {
            throw refusal("--keep-read-pairs and --no-keep-read-pairs are mutually exclusive")
        }
        if sourceFiles.isEmpty, keepReadPairs || noKeepReadPairs {
            throw refusal("--keep-read-pairs and --no-keep-read-pairs apply to reads taken from --source")
        }
        if !sourceFiles.isEmpty, includeSecondaryFlag || excludeDuplicatesFlag {
            throw refusal("--include-secondary and --exclude-duplicates apply to reads taken from --bam, not --source")
        }
    }

    /// The run's choices, as its options give them.
    var evidenceInvocation: AlignmentReadExtractionInvocation {
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let selection: AlignmentReadExtractionInvocation.Selection = byRegion
            ? .regions(regions, minimumMapQ: minimumMapQ, excludedFlags: excludedFlags, readGroups: readGroups)
            : .readNames(.init(
                file: URL(fileURLWithPath: idsFile ?? ""),
                sourceFASTQs: sourceFiles.map { URL(fileURLWithPath: $0) },
                keepReadPairs: keepReadPairs || (!noKeepReadPairs && sourceFiles.count > 1),
                includeSecondary: includeSecondaryFlag,
                excludeDuplicates: excludeDuplicatesFlag,
                recordsWithoutSequence: recordsWithoutSequence
            ))
        return AlignmentReadExtractionInvocation(
            alignmentURL: URL(fileURLWithPath: bamFile ?? ""),
            indexURL: URL(fileURLWithPath: indexFile ?? ""),
            decodingReferenceURL: decodingReferenceFile.map { URL(fileURLWithPath: $0) },
            selection: selection,
            readsName: bundleName ?? outputURL.deletingPathExtension().lastPathComponent,
            outputURL: outputURL
        )
    }

    /// The run on alignment evidence, as `extract()` reports it.
    func extractEvidence() async throws -> ExtractReadsOutcome {
        let invocation = evidenceInvocation
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        say(formatter.header(byRegion ? "Alignment Region Extraction" : "Selected Read Extraction"))
        let result = try await Self.extractEvidence(invocation)
        if !globalOptions.quiet {
            for record in result.executionRecords { say(record.reproducibleCommand) }
        }
        say(formatter.success("Published \(result.finalURL.lastPathComponent) with \(result.readCount) reads"))
        return ExtractReadsOutcome(outputs: [result.finalURL.path], readCount: result.readCount)
    }

    /// Hashes the evidence, stages the reads, checks the evidence again and publishes the bundle with
    /// its record, as the viewer's coordinator did in the app before Phase 2.10. A cancel stops each
    /// hash and each tool and is checked again before the publication. A missing input is refused
    /// before anything runs, and so is a region that is not on the evidence, as `bam consensus` refuses
    /// one: a contig the header does not name, or an end past the contig (review A51, F2).
    static func extractEvidence(
        _ invocation: AlignmentReadExtractionInvocation,
        stages: ExtractReadsEvidenceStages = .init()
    ) async throws -> AlignmentReadExtractionPublicationResult {
        var evidence = [("--bam", invocation.alignmentURL), ("--index", invocation.indexURL)]
        if let reference = invocation.decodingReferenceURL { evidence.append(("--decoding-reference", reference)) }
        var inputs = evidence
        var names: Set<String> = []
        if case .readNames(let selection) = invocation.selection {
            inputs += [("--ids", selection.file)] + selection.sourceFASTQs.map { ("--source", $0) }
        }
        for (option, url) in inputs where !FileManager.default.fileExists(atPath: url.path) {
            throw ExtractReadsRefusal("No file at \(url.path). Pass an existing file as \(option).")
        }
        if case .readNames(let selection) = invocation.selection {
            names = try readNames(in: selection.file)
        }
        // Scientific gate 1: the evidence as the run found it, hashed before staging.
        var snapshots: [AlignmentEvidenceFileSnapshot] = []
        for (_, url) in evidence { snapshots.append(try await snapshot(url)) }
        try Task.checkCancellation()
        // Each region must lie on a contig of the header, before any samtools run reads it.
        if case .regions(let regions, _, _, _) = invocation.selection {
            let header = try await stages.header(invocation)
            for region in regions {
                if case .failure(let refusal) = AlignmentRegionOnEvidence.contigLength(ofRegion: region, inHeader: header) {
                    throw ExtractReadsRefusal(refusal.message)
                }
            }
            try Task.checkCancellation()
        }

        let directory = invocation.outputURL.deletingLastPathComponent()
        let transaction: AlignmentReadExtractionTransaction
        switch invocation.selection {
        case .regions(let regions, let minimumMapQ, let excludedFlags, let readGroups):
            transaction = try await stages.region(BAMRegionExtractionConfig(
                bamURL: invocation.alignmentURL, indexURL: invocation.indexURL,
                decodingReferenceURL: invocation.decodingReferenceURL, regions: regions, fallbackToAll: false,
                minMapQ: minimumMapQ, excludedFlags: excludedFlags, readGroups: readGroups,
                outputDirectory: directory, outputBaseName: invocation.readsName, deduplicateReads: false
            ))
        case .readNames(let selection) where selection.sourceFASTQs.isEmpty:
            transaction = try await stages.alignment(ReadIDBAMExtractionConfig(
                bamURL: invocation.alignmentURL, readIDs: names, includeSecondary: selection.includeSecondary,
                excludeDuplicates: selection.excludeDuplicates, outputDirectory: directory, outputBaseName: invocation.readsName
            ), selection.recordsWithoutSequence, invocation.missingSequenceMessage)
        case .readNames(let selection):
            transaction = try await stages.sources(ReadIDExtractionConfig(
                sourceFASTQs: selection.sourceFASTQs, readIDs: names, keepReadPairs: selection.keepReadPairs,
                outputDirectory: directory, outputBaseName: invocation.readsName
            ), selection.recordsWithoutSequence, invocation.missingSequenceMessage)
        }
        do {
            try await stages.beforeSecondCheck()
            // Scientific gate 2: the evidence must still be the bytes the run hashed.
            for ((_, url), expected) in zip(evidence, snapshots) {
                let current = try? await snapshot(url)
                guard current == expected else {
                    throw AlignmentReadExtractionFailure(
                        kind: .staleInput,
                        message: "Alignment evidence changed before publication (alignment=\(invocation.alignmentURL.path)): \(url.path) is no longer the file the run hashed.",
                        executionRecords: transaction.executionRecords
                    )
                }
            }
            try Task.checkCancellation()
            let result = try AlignmentReadExtractionPublisher().publish(.init(
                transaction: transaction,
                destination: .bundle(invocation.outputURL),
                provenance: invocation.provenance
            ))
            // A cancelled run's record beside the bundle no longer describes it.
            let cancelledRecord = ProvenanceRecorder.fileSidecarURL(for: invocation.outputURL)
            if AlignmentReadExtractionInvocation.isCancelledRecord(at: cancelledRecord) {
                // The signature and public key of a signed cancelled record go with it.
                try? ProvenancePublicationArtifacts.removeSidecarArtifacts(for: cancelledRecord)
            }
            return result
        } catch {
            transaction.cleanup()
            throw error
        }
    }

    /// The names a read name file holds, one a line, trimmed, each once.
    static func readNames(in url: URL) throws -> Set<String> {
        let names = Set(
            try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        guard !names.isEmpty else {
            throw ExtractReadsRefusal("The read name file \(url.path) names no read.")
        }
        return names
    }

    /// The size and digest of `url`, hashed once a run through the shared digest cache. The hash
    /// checks for a cancel between its reads.
    private static func snapshot(_ url: URL) async throws -> AlignmentEvidenceFileSnapshot {
        let identity = try AlignmentEvidenceFileIdentity.current(of: url)
        let sha256 = try await AlignmentEvidenceDigestCache.shared.digest(for: identity) {
            try ProvenanceFileHasher.sha256(of: url) { try Task.checkCancellation() }
        }
        return AlignmentEvidenceFileSnapshot(url: url, byteCount: identity.byteCount, sha256: sha256)
    }
}
