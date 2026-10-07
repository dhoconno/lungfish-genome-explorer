// ReadSetResolver+NamedInput.swift - A path the user named, read where it lies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Added in Phase 2.1 round F4 (review A S1). docs/contracts/READ-PAIRING.md
// is the contract the resolver implements.

import Foundation
import LungfishIO

/// What a path the user named stands for, read where it lies.
///
/// A `.lungfishfastq` bundle is the bundle and a file outside every bundle is
/// that file. A file inside a bundle is that file alone, as the FASTQ
/// subcommands and TaxTriage read a named member file. The one exception is
/// the preview of a virtual bundle, which holds a few reads of the sample and
/// not the sample, so it stands for its bundle (the rule of
/// `TaxTriageReadSetPlanner.bundleToPlan`). A folder inside a bundle stands
/// for that bundle, as before.
public enum ReadSetNamedInput: Equatable, Sendable {
    /// A bundle, a folder inside one, or a file outside every bundle, read
    /// as named.
    case asNamed(URL)
    /// A file inside a bundle, read as that file alone. A file that is not
    /// there is still this file and never the whole bundle.
    case fileAlone(URL)
    /// The preview of a virtual bundle, for which its bundle is read.
    case previewOf(bundle: URL, preview: URL)

    public init(_ inputURL: URL) {
        let input = inputURL.standardizedFileURL
        guard !FASTQBundle.isBundleURL(input),
              SequenceInputResolver.enclosingFASTQBundleURL(for: input) != nil else {
            self = .asNamed(input)
            return
        }
        if FASTQBundle.isFASTQFileURL(input),
           let bundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: input) {
            self = .previewOf(bundle: bundleURL, preview: input)
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue {
            self = .asNamed(input)
        } else {
            self = .fileAlone(input)
        }
    }

    /// The line a tool shows when a preview stands for its bundle, in the
    /// words the FASTQ subcommands and TaxTriage use, or nil.
    public var note: String? {
        guard case let .previewOf(bundleURL, preview) = self else { return nil }
        return "\(preview.lastPathComponent) is the preview of the virtual bundle \(bundleURL.lastPathComponent), not its reads. Reading the bundle instead."
    }
}

extension ReadSetResolver {

    /// The plan for a path the user named, read where it lies
    /// (``ReadSetNamedInput``). A bundle, and a file outside every bundle,
    /// are planned as ``plan(for:capability:progress:)`` plans them. A file
    /// inside a bundle is planned as that file alone, the way a copy of it
    /// beside its own sidecar would be planned outside every bundle, so the
    /// bundle's manifest, lineage and platform, which describe the bundle,
    /// play no part. The preview of a virtual bundle is planned as its
    /// bundle, with ``ReadSetNamedInput/note`` sent through `progress`. Every
    /// file this call wrote is removed when it throws.
    public func plan(
        for named: ReadSetNamedInput,
        capability: ReadPairingCapability,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ReadSetPlan {
        switch named {
        case let .asNamed(url):
            return try await plan(for: url, capability: capability, progress: progress)
        case let .previewOf(bundleURL, _):
            if let note = named.note { progress?(note) }
            return try await plan(for: bundleURL, capability: capability, progress: progress)
        case let .fileAlone(fileURL):
            let written = WrittenFiles()
            do {
                try Task.checkCancellation()
                var source = try inspectFile(
                    fileURL,
                    platform: nil,
                    hints: nil,
                    roleEvidence: nil,
                    wasMaterialized: false,
                    alone: true
                )
                if countReads { source = try source.counted() }
                return try deliver(source, inputURL: fileURL, capability: capability, written: written)
            } catch {
                written.removeAll()
                throw error
            }
        }
    }

    // MARK: - A file read alone

    /// The layout of a file read alone. Its records are scanned with the
    /// metadata of its own sidecar as hints, and the bundle it lies in gives
    /// none.
    ///
    /// `FASTQInputLayoutResolver.resolve(inputURLs:)` reads the manifest of
    /// the bundle a file lies in directly, and LungfishIO has no entry that
    /// leaves it out, so this follows that resolver for a file outside every
    /// bundle, whose only metadata is its sidecar. A file that is not FASTQ
    /// is single records, an explicit single-end choice settles the layout,
    /// and the sidecar's counts and recipe are the merge evidence that
    /// `FASTQReadLayoutClassifier.metadataEvidence(for:)` reads.
    /// ReadSetResolverLayoutTests plans member files beside their copies
    /// outside every bundle, so the two rules stay alike.
    static func layoutOfFileAlone(_ file: URL) -> FASTQInputLayoutResolution {
        if let format = SequenceFormat.from(url: file), format != .fastq {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .notFASTQ,
                reason: "The input is \(format.rawValue.uppercased()), not FASTQ reads."
            )
        }
        let evidence = sidecarEvidence(of: file)
        if evidence.hints.recordsExplicitSingleEnd, !evidence.hints.hasMergedOrUnpairedReads {
            return FASTQInputLayoutResolution(
                layout: .singleEnd,
                source: .bundleMetadata,
                reason: "The bundle metadata records single-end reads, chosen at import."
            )
        }
        let scan = (try? FASTQReadLayoutClassifier.readHeaders(from: file)) ?? (headers: [], scannedWholeFile: true)
        let classification = FASTQReadLayoutClassifier.classify(
            headers: scan.headers,
            scannedWholeFile: scan.scannedWholeFile,
            metadata: evidence.hints,
            wholeFileScanOutranksTheMerge: evidence.scanOutranksTheMerge
        )
        return FASTQInputLayoutResolution(
            layout: FASTQInputLayout(readLayout: classification.layout),
            source: .contentScan,
            classification: classification,
            reason: classification.reason
        )
    }

    /// The pairing hints of a file's own sidecar, and whether a scan of the
    /// whole file that finds only pairs outranks their merge evidence. A
    /// count of only pairs in the sidecar outranks a merge recipe, and a
    /// count of merged or unpaired reads, or of R1 and R2 reads that differ,
    /// keeps the evidence standing.
    private static func sidecarEvidence(
        of file: URL
    ) -> (hints: FASTQPairingMetadataHints, scanOutranksTheMerge: Bool) {
        var hints = FASTQPairingMetadataHints()
        // Each piece of merge evidence, with whether a count of only pairs outranks it.
        var evidence: [(text: String, outrankedByACountOfPairs: Bool)] = []
        var countedPairsOnly = false
        if FASTQBundle.isFASTQFileURL(file), let sidecar = FASTQMetadataStore.load(for: file) {
            hints.pairingMode = sidecar.ingestion?.pairingMode
            hints.pairingSource = sidecar.ingestion?.pairingSource
            if let classification = sidecar.readClassification {
                func mates(_ role: ReadClassification.FileRole) -> Int {
                    classification.files.filter { $0.role == role }.reduce(0) { $0 + $1.readCount }
                }
                let r1 = mates(.pairedR1)
                let r2 = mates(.pairedR2)
                let namesThisFile = classification.files.allSatisfy { $0.filename == file.lastPathComponent }
                if classification.mergedReadCount > 0 || classification.unpairedReadCount > 0 {
                    evidence.append(("sidecar: \(classification.compositionLabel)", false))
                } else if r1 > 0, r1 == r2, namesThisFile {
                    countedPairsOnly = true
                } else if r1 != r2, namesThisFile {
                    evidence.append(("sidecar: \(abs(r1 - r2)) reads without a mate by its R1 and R2 counts", false))
                }
            }
            if let recipe = sidecar.ingestion?.recipeApplied,
               recipe.stepResults.contains(where: { $0.stepName.lowercased().contains("merge") }) {
                evidence.append(("recipe \(recipe.recipeName) merges overlapping pairs", true))
            }
        }
        let standing = evidence.filter { !(countedPairsOnly && $0.outrankedByACountOfPairs) }
        if !standing.isEmpty {
            hints.hasMergedOrUnpairedReads = true
            hints.mergeEvidence = standing.map(\.text).joined(separator: "; ")
        }
        return (hints, standing.allSatisfy(\.outrankedByACountOfPairs))
    }
}
