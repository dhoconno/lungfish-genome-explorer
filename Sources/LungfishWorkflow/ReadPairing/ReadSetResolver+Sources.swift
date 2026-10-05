// ReadSetResolver+Sources.swift - What a sample holds before any split, and the bundle evidence behind it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The reads of one sample as found on disk, before the resolver shapes
/// them for a tool.
struct ReadSetSource: Sendable, Equatable {
    enum Part: Sendable, Equatable {
        case pair(ReadSetMatePair)
        case single(ReadSetSingleReads)
        case mixed(ReadSetMixedStream)

        var urls: [URL] {
            switch self {
            case .pair(let pair): return pair.urls
            case .single(let single): return [single.url]
            case .mixed(let stream): return [stream.url]
            }
        }
    }

    var parts: [Part]
    var layout: ReadSetSourceLayout
    var reason: String
    var platform: SequencingPlatform?
    var wasMaterialized: Bool

    var pairs: [ReadSetMatePair] {
        parts.compactMap { if case .pair(let pair) = $0 { return pair } else { return nil } }
    }

    var singles: [ReadSetSingleReads] {
        parts.compactMap { if case .single(let single) = $0 { return single } else { return nil } }
    }

    var mixedStreams: [ReadSetMixedStream] {
        parts.compactMap { if case .mixed(let stream) = $0 { return stream } else { return nil } }
    }

    /// Whether the sample holds pairs and single reads together.
    var holdsPairsAndSingleReads: Bool {
        !mixedStreams.isEmpty || (!pairs.isEmpty && !singles.isEmpty)
    }

    var holdsPairs: Bool {
        !pairs.isEmpty || !mixedStreams.isEmpty
    }

    /// The fragment counts by kind. A kind that is absent counts zero, and a
    /// kind that is present with no count makes its total nil.
    var composition: ReadSetComposition {
        ReadSetComposition(counting: parts.flatMap { part -> [ReadSetComposition.Contribution] in
            switch part {
            case .pair(let pair): return [.pairs(pair.pairCount)]
            case .single(let single): return [.singleReads(single.readCount, single.role)]
            case .mixed(let stream):
                return [.pairs(stream.pairCount), .singleReads(stream.singleReadCount, stream.singleReadRole)]
            }
        })
    }

    /// The source with every missing count read from its files.
    func counted() throws -> ReadSetSource {
        var copy = self
        copy.parts = try parts.map { part in
            switch part {
            case .pair(let pair) where pair.pairCount == nil:
                let records = try FASTQPairInterleaver.countRecords(in: pair.urls[0])
                let pairs: Int
                if case .interleaved = pair.files { pairs = records / 2 } else { pairs = records }
                return .pair(ReadSetMatePair(files: pair.files, pairCount: pairs))
            case .single(let single) where single.readCount == nil:
                let records = SequenceFormat.from(url: single.url) == .fasta
                    ? nil
                    : try FASTQPairInterleaver.countRecords(in: single.url)
                return .single(ReadSetSingleReads(url: single.url, role: single.role, readCount: records))
            case .mixed(let stream) where stream.pairCount == nil || stream.singleReadCount == nil:
                let counts = try FASTQPairInterleaver.countMixed(interleaved: stream.url)
                return .mixed(ReadSetMixedStream(
                    url: stream.url,
                    pairCount: counts.pairs,
                    singleReadCount: counts.unpaired,
                    singleReadRole: stream.singleReadRole
                ))
            default:
                return part
            }
        }
        return copy.resolvingStreamsByTheirCounts()
    }

    /// The source with each mixed stream whose counts show one kind of
    /// record read as that kind. A file is mixed only when it holds pairs and
    /// single reads, whatever merge or repair its lineage records, so a
    /// stream with no single read is an interleaved pair and a stream with no
    /// pair is single reads of the stream's role (final review A, S4). A
    /// stream whose counts are unknown stays as it is.
    func resolvingStreamsByTheirCounts() -> ReadSetSource {
        var notes: [String] = []
        let resolvedParts = parts.map { part -> Part in
            guard case .mixed(let stream) = part,
                  let pairs = stream.pairCount,
                  let singles = stream.singleReadCount else { return part }
            if singles == 0, pairs > 0 {
                notes.append("The file holds \(pairs) adjacent mate pairs and no read without a mate, so it is read as pairs.")
                return .pair(ReadSetMatePair(files: .interleaved(stream.url), pairCount: pairs))
            }
            if pairs == 0 {
                notes.append("The file holds \(singles) reads and no adjacent mate pair, so it is read as single reads.")
                return .single(ReadSetSingleReads(url: stream.url, role: stream.singleReadRole, readCount: singles))
            }
            return part
        }
        guard !notes.isEmpty else { return self }
        var copy = self
        copy.parts = resolvedParts
        if layout == .mixedFile, resolvedParts.count == 1 {
            switch resolvedParts[0] {
            case .pair: copy.layout = .interleavedFile
            case .single: copy.layout = .singleEndFile
            case .mixed: break
            }
        }
        copy.reason = (notes + [reason]).joined(separator: " ")
        return copy
    }
}

extension ReadSetResolver {

    /// Whether reads from `platform` are long reads, which are never paired.
    static func isLongRead(_ platform: SequencingPlatform?) -> Bool {
        platform == .oxfordNanopore || platform == .pacbio
    }

    /// Every file of a long-read sample as single reads.
    static func longReadSource(_ files: [URL], platform: SequencingPlatform?) -> ReadSetSource {
        ReadSetSource(
            parts: files.map { .single(ReadSetSingleReads(url: $0, role: .singleEnd)) },
            layout: files.count > 1 ? .multiFileRoot : .singleEndFile,
            reason: "The bundle records \(platform?.displayName ?? "long-read") reads, which are never paired.",
            platform: platform,
            wasMaterialized: false
        )
    }

    /// The sequencing platform a bundle records, from its primary file's
    /// sidecar, its own sidecar, or the bundle it derives from.
    static func recordedPlatform(of bundleURL: URL) -> SequencingPlatform? {
        for candidate in [bundleURL] + ancestors(of: bundleURL) {
            if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: candidate),
               let platform = FASTQMetadataStore.load(for: fastqURL)?.sequencingPlatform {
                return platform
            }
            if let platform = FASTQMetadataStore.load(for: candidate)?.sequencingPlatform {
                return platform
            }
        }
        return nil
    }

    /// The bundles a derivative derives from, nearest first, through each
    /// manifest's parent.
    static func ancestors(of bundleURL: URL, limit: Int = 32) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = [bundleURL.standardizedFileURL.path]
        var current = bundleURL.standardizedFileURL
        while result.count < limit, let manifest = FASTQBundle.loadDerivedManifest(in: current) {
            let parent = FASTQBundle.resolveBundle(relativePath: manifest.parentBundleRelativePath, from: current)
                .standardizedFileURL
            guard !seen.contains(parent.path), FASTQBundle.isBundleURL(parent),
                  FileManager.default.fileExists(atPath: parent.path) else { break }
            seen.insert(parent.path)
            result.append(parent)
            current = parent
        }
        return result
    }

    /// Merge or orphan evidence from a virtual derivative's own manifest and
    /// every bundle it derives from, with the first read classification
    /// that records merged or unpaired reads. A virtual child of a repair
    /// derivative carries only `repair` in its lineage, so the parent's
    /// roles are what show its single reads.
    static func lineageEvidence(of bundleURL: URL) -> (evidence: String?, classification: ReadClassification?) {
        var evidence: [String] = []
        var found: ReadClassification?
        func note(_ classification: ReadClassification?, _ label: String) {
            guard let classification,
                  classification.mergedReadCount > 0 || classification.unpairedReadCount > 0 else { return }
            evidence.append("\(label): \(classification.compositionLabel)")
            if found == nil { found = classification }
        }
        for candidate in [bundleURL] + ancestors(of: bundleURL) {
            let name = candidate.lastPathComponent
            if let manifest = FASTQBundle.loadDerivedManifest(in: candidate) {
                if case .fullMixed(let classification) = manifest.payload {
                    note(classification, "\(name) roles")
                }
                note(manifest.readClassification, "\(name) manifest")
                if manifest.operation.kind == .pairedEndMerge {
                    evidence.append("\(name) is a paired-end merge")
                }
            } else {
                note(ReadManifest.load(from: candidate)?.classification, "\(name) read manifest")
                if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: candidate) {
                    note(FASTQMetadataStore.load(for: fastqURL)?.readClassification, "\(name) sidecar")
                }
            }
        }
        return (evidence.isEmpty ? nil : evidence.joined(separator: "; "), found)
    }

    /// The sidecar classification of `fileURL` when every role in it names
    /// that file, the form a merge recipe or a re-imported `fastq merge`
    /// output records.
    static func singleFileClassification(of fileURL: URL) -> ReadClassification? {
        guard let classification = FASTQMetadataStore.load(for: fileURL)?.readClassification,
              !classification.files.isEmpty,
              classification.files.allSatisfy({ $0.filename == fileURL.lastPathComponent }) else {
            return nil
        }
        return classification
    }

    /// What the reads without a mate are, from a classification's counts.
    static func singleReadRole(from classification: ReadClassification?) -> ReadSetReadRole {
        guard let classification else { return .mergedOrOrphan }
        switch (classification.mergedReadCount > 0, classification.unpairedReadCount > 0) {
        case (true, false): return .merged
        case (false, true): return .orphan
        default: return .mergedOrOrphan
        }
    }

    /// Throws when a file a bundle records is missing.
    static func requireFiles(_ files: [URL], in bundleURL: URL) throws {
        for file in files where !FileManager.default.fileExists(atPath: file.path) {
            throw ReadSetResolverError.missingFile(bundlePath: bundleURL.path, filePath: file.path)
        }
    }

    /// Whether `platform` is a known short-read platform, the only kind
    /// whose chunks may be paired by file name.
    static func isKnownShortRead(_ platform: SequencingPlatform?) -> Bool {
        switch platform {
        case .illumina, .element, .ultima, .mgi: return true
        case .oxfordNanopore, .pacbio, .unknown, nil: return false
        }
    }

    /// The FASTQ files directly inside a root bundle, by name. The preview
    /// is never one of them: a root holding only `preview.fastq` has no
    /// payload, and planning its preview would analyse a subset silently.
    static func physicalFASTQFiles(in bundleURL: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = contents
            .filter { FASTQBundle.isFASTQFileURL($0) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map(\.standardizedFileURL)
        return files.filter { $0.lastPathComponent != "preview.fastq" }
    }
}
