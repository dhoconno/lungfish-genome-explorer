// ClassifierReadResolver+TaxTriageLayout.swift - The BAM of a TaxTriage sample in a result that records no path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ClassifierReadResolver {
    // MARK: - The nf-core layout (Phase 3.4 lane EXTRACT, EXTRACT-PREFIX-SCAN-NO-DATABASE)

    /// The end of the BAM name that nf-core TaxTriage writes for a sample, `{S}.{S}.dwnld.references.bam`.
    private static let taxTriageReferencesBAMSuffix = ".dwnld.references.bam"

    /// The BAM candidates of one TaxTriage sample, in the order ``firstContainedBAM(among:within:sample:)`` tries them.
    ///
    /// The paths that the result's database records come first, read only from inside the result root (decision C4).
    /// Then come the two names the pipeline gives a sample's BAM in `minimap2/`, `{S}.bam` and
    /// `{S}.{S}.dwnld.references.bam`. The folder is scanned only when nothing is recorded and neither name exists, and
    /// the scan reads the listing sorted by name for the files whose names fit the sample
    /// (``taxTriageNameFits(_:sampleId:)``). One fit is the candidate, and the extraction says so
    /// (``taxTriageScanNotice(tool:sampleId:resultPath:bam:)``). Two or more cannot be told apart, so the lookup
    /// ends in ``ClassifierExtractionError/moreThanOneBAMFitsSample(sampleId:names:)`` and no file is read.
    static func taxTriageBAMCandidates(sampleId: String, resultDir: URL) throws -> [URL] {
        let recorded = taxTriageRecordedBAMCandidates(sampleId: sampleId, resultDir: resultDir)
        let named = taxTriageNamedBAMs(sampleId: sampleId, resultDir: resultDir)
        guard recorded.isEmpty, named.allSatisfy({ checkedBAMCandidate($0, within: resultDir) == .absent }) else {
            return recorded + named
        }
        return try named + taxTriageScanFits(sampleId: sampleId, resultDir: resultDir)
    }

    /// The two names that the pipeline gives a sample's BAM in `minimap2/`.
    private static func taxTriageNamedBAMs(sampleId: String, resultDir: URL) -> [URL] {
        let minimap2Dir = resultDir.appendingPathComponent("minimap2")
        return [
            minimap2Dir.appendingPathComponent("\(sampleId).bam"),
            minimap2Dir.appendingPathComponent("\(sampleId).\(sampleId)\(taxTriageReferencesBAMSuffix)"),
        ]
    }

    /// The files of `minimap2/` whose names fit the sample and that exist, none or one. Two or more end in
    /// ``ClassifierExtractionError/moreThanOneBAMFitsSample(sampleId:names:)``.
    private static func taxTriageScanFits(sampleId: String, resultDir: URL) throws -> [URL] {
        let fits = listedFiles(in: resultDir.appendingPathComponent("minimap2"), within: resultDir)
            .filter { taxTriageNameFits($0.lastPathComponent, sampleId: sampleId) }
            .filter { checkedBAMCandidate($0, within: resultDir) != .absent }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard fits.count < 2 else {
            throw ClassifierExtractionError.moreThanOneBAMFitsSample(
                sampleId: sampleId, names: fits.map(\.lastPathComponent)
            )
        }
        return fits
    }

    /// The words that say which file a fit of its name gave a sample, or nil when `bam` came from anywhere else, one of
    /// the two names the pipeline gives or a path the database records with no fitted mark (EXTRACT-SCAN-EXTENDED-ID).
    /// The fit is the scan's when nothing is recorded, or the build's when the database records a path and its
    /// metadata marks the sample as fitted (BUILDDB-BAM-FIT, ``TaxTriageDatabase/fittedBAMSamplesMetadataKey``). A file
    /// such as `S1_2.bam` fits sample `S1` and can belong to another sample, so the extraction names the file, prints
    /// the words as a progress line (the CLI line and the Operations Panel Log) and records them with the extraction.
    static func taxTriageScanNotice(tool: ClassifierTool, sampleId: String?, resultPath: URL, bam: URL) -> String? {
        guard tool == .taxtriage, let sampleId else { return nil }
        let resultDir = resultPath.hasDirectoryPath ? resultPath : resultPath.deletingLastPathComponent()
        let recorded = taxTriageRecordedBAMCandidates(sampleId: sampleId, resultDir: resultDir)
        let fitted: [URL]
        if !recorded.isEmpty {
            fitted = taxTriageRecordedBAMIsFitted(sampleId: sampleId, resultDir: resultDir) ? recorded : []
        } else if taxTriageNamedBAMs(sampleId: sampleId, resultDir: resultDir)
            .allSatisfy({ checkedBAMCandidate($0, within: resultDir) == .absent }) {
            fitted = (try? taxTriageScanFits(sampleId: sampleId, resultDir: resultDir)) ?? []
        } else {
            fitted = []
        }
        guard let scanned = fitted.first(where: {
            $0.resolvingSymlinksInPath().path == bam.resolvingSymlinksInPath().path
        }) else { return nil }
        return "Sample \(sampleId)'s own BAM was not found, so Lungfish read \(scanned.lastPathComponent), "
            + "the one file in the minimap2 folder that fits its name. "
            + "If that file belongs to another sample, put \(sampleId)'s own BAM back and try again."
    }

    /// Whether the metadata of the result's `taxtriage.sqlite` marks `sampleId` as a sample whose recorded BAM
    /// `build-db taxtriage` took by a fit of its name. A database of an older build holds no mark, so false.
    private static func taxTriageRecordedBAMIsFitted(sampleId: String, resultDir: URL) -> Bool {
        let databaseURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let metadata = try? TaxTriageDatabase(at: databaseURL).fetchMetadata() else { return false }
        return TaxTriageDatabase.fittedBAMSamples(in: metadata).contains(sampleId)
    }

    /// `destination` and `options` that carry `notes`, the words of ``taxTriageScanNotice(tool:sampleId:resultPath:bam:)``,
    /// into the extraction's record as the Kraken 2 read-change notes are carried
    /// (``recordingReadChangeNotes(_:in:options:)``), a bundle's parameters and a file export's resolved options.
    static func recordingBAMScanNotes(
        _ notes: [String], in destination: ExtractionDestination, options: ExtractionOptions
    ) -> (destination: ExtractionDestination, options: ExtractionOptions) {
        guard !notes.isEmpty else { return (destination, options) }
        let note = notes.joined(separator: " ")
        var recorded = destination
        if case .bundle(let projectRoot, let displayName, let metadata) = destination {
            recorded = .bundle(
                projectRoot: projectRoot, displayName: displayName,
                metadata: metadata.mergingParameters(["classifierExtractionBAMScanNote": note])
            )
        }
        let recordedOptions = options.fileProvenance.map {
            options.recordingFileProvenance($0.mergingResolved(["bamScanNote": .string(note)]))
        } ?? options
        return (recorded, recordedOptions)
    }

    /// Whether the file name `name` fits `sampleId`. It ends in `.bam` and is the sample id followed by `.`, `_` or `-`.
    /// The nf-core name `{X}.{X}.dwnld.references.bam` belongs to sample X alone, so it fits `sampleId` only when X is
    /// `sampleId`. That keeps sample `S1` from taking the BAM of `S10`, whose name has no boundary after `S1`, or of
    /// `S1.1`, whose file names `S1.1` twice.
    package static func taxTriageNameFits(_ name: String, sampleId: String) -> Bool {
        guard name.hasSuffix(".bam"), name.hasPrefix(sampleId),
              let boundary = name.dropFirst(sampleId.count).first, ".-_".contains(boundary) else { return false }
        guard let owner = taxTriageReferencesBAMOwner(of: name) else { return true }
        return owner == sampleId
    }

    /// The sample X that the nf-core name `{X}.{X}.dwnld.references.bam` belongs to, or nil for any other name.
    private static func taxTriageReferencesBAMOwner(of name: String) -> String? {
        guard name.hasSuffix(taxTriageReferencesBAMSuffix) else { return nil }
        let twice = name.dropLast(taxTriageReferencesBAMSuffix.count)
        let half = twice.count / 2
        guard half > 0, twice.count == 2 * half + 1,
              twice[twice.index(twice.startIndex, offsetBy: half)] == ".",
              twice.prefix(half) == twice.suffix(half) else { return nil }
        return String(twice.prefix(half))
    }
}
