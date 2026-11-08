// ClassifierReadResolver+TaxTriageLayout.swift - The BAM of a TaxTriage sample in a result that records no path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
    /// (``taxTriageNameFits(_:sampleId:)``). One fit is the candidate. Two or more cannot be told apart, so the lookup
    /// ends in ``ClassifierExtractionError/moreThanOneBAMFitsSample(sampleId:names:)`` and no file is read.
    static func taxTriageBAMCandidates(sampleId: String, resultDir: URL) throws -> [URL] {
        let recorded = taxTriageRecordedBAMCandidates(sampleId: sampleId, resultDir: resultDir)
        let minimap2Dir = resultDir.appendingPathComponent("minimap2")
        let named = [
            minimap2Dir.appendingPathComponent("\(sampleId).bam"),
            minimap2Dir.appendingPathComponent("\(sampleId).\(sampleId)\(taxTriageReferencesBAMSuffix)"),
        ]
        guard recorded.isEmpty, named.allSatisfy({ checkedBAMCandidate($0, within: resultDir) == .absent }) else {
            return recorded + named
        }
        let fits = listedFiles(in: minimap2Dir, within: resultDir)
            .filter { taxTriageNameFits($0.lastPathComponent, sampleId: sampleId) }
            .filter { checkedBAMCandidate($0, within: resultDir) != .absent }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard fits.count < 2 else {
            throw ClassifierExtractionError.moreThanOneBAMFitsSample(
                sampleId: sampleId, names: fits.map(\.lastPathComponent)
            )
        }
        return named + fits
    }

    /// Whether the file name `name` fits `sampleId`. It ends in `.bam` and is the sample id followed by `.`, `_` or `-`.
    /// The nf-core name `{X}.{X}.dwnld.references.bam` belongs to sample X alone, so it fits `sampleId` only when X is
    /// `sampleId`. That keeps sample `S1` from taking the BAM of `S10`, whose name has no boundary after `S1`, or of
    /// `S1.1`, whose file names `S1.1` twice.
    static func taxTriageNameFits(_ name: String, sampleId: String) -> Bool {
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
