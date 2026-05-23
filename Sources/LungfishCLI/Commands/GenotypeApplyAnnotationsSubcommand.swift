import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Merge an annotation patch JSON into a bundle's existing annotation sidecar.
///
/// The patch JSON has the same schema as `annotations.json`
/// (`GenotypeAnnotationSidecar`) but typically contains only the entries the
/// caller wants to merge. Existing entries in the bundle are preserved; new
/// entries are appended after de-duplication on
/// `sample+locus+slot+author+timestamp` (or the relevant subset for entries
/// without a locus or slot).
///
/// Pipeline output files in the bundle are never touched. Only the sidecar
/// (`annotations.json` peer to `genotype-result.json`) is rewritten.
struct GenotypeApplyAnnotationsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply-annotations",
        abstract: "Merge an annotation patch JSON into a genotype bundle's annotation sidecar"
    )

    @Option(name: .customLong("bundle"), help: "Path to a `.lungfishgenotype` result bundle")
    var bundle: String

    @Option(name: .customLong("patch"), help: "Path to an annotation patch JSON (same schema as annotations.json)")
    var patch: String

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--patch must not be empty.")
        }
    }

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let patchURL = URL(fileURLWithPath: patch)

        let patchData = try Data(contentsOf: patchURL)
        let patchSidecar = try GenotypeAnnotationSidecar.decode(patchData)

        var sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )

        let merge = Self.merge(existing: sidecar, patch: patchSidecar)
        sidecar = merge.sidecar

        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )

        let summary = MergeSummary(
            bundlePath: bundleURL.path,
            sidecarPath: ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundleURL
            ).path,
            appended: merge.appendedCounts,
            skippedDuplicate: merge.skippedDuplicateCounts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - Merge

    struct MergeResult {
        var sidecar: GenotypeAnnotationSidecar
        var appendedCounts: AnnotationCategoryCounts
        var skippedDuplicateCounts: AnnotationCategoryCounts
    }

    static func merge(
        existing: GenotypeAnnotationSidecar,
        patch: GenotypeAnnotationSidecar
    ) -> MergeResult {
        var merged = existing
        var appended = AnnotationCategoryCounts()
        var skipped = AnnotationCategoryCounts()

        Self.mergeArray(into: &merged.callOverrides, from: patch.callOverrides,
                        key: callOverrideKey,
                        appended: &appended.callOverrides,
                        skipped: &skipped.callOverrides)
        Self.mergeArray(into: &merged.cellHighlights, from: patch.cellHighlights,
                        key: cellHighlightKey,
                        appended: &appended.cellHighlights,
                        skipped: &skipped.cellHighlights)
        Self.mergeArray(into: &merged.rowHighlights, from: patch.rowHighlights,
                        key: rowHighlightKey,
                        appended: &appended.rowHighlights,
                        skipped: &skipped.rowHighlights)
        Self.mergeArray(into: &merged.sampleNotes, from: patch.sampleNotes,
                        key: sampleNoteKey,
                        appended: &appended.sampleNotes,
                        skipped: &skipped.sampleNotes)
        Self.mergeArray(into: &merged.cellComments, from: patch.cellComments,
                        key: cellCommentKey,
                        appended: &appended.cellComments,
                        skipped: &skipped.cellComments)
        Self.mergeArray(into: &merged.sampleStatusFlags, from: patch.sampleStatusFlags,
                        key: sampleStatusFlagKey,
                        appended: &appended.sampleStatusFlags,
                        skipped: &skipped.sampleStatusFlags)
        Self.mergeArray(into: &merged.callStatusFlags, from: patch.callStatusFlags,
                        key: callStatusFlagKey,
                        appended: &appended.callStatusFlags,
                        skipped: &skipped.callStatusFlags)
        Self.mergeArray(into: &merged.smartCohorts, from: patch.smartCohorts,
                        key: { $0.name + "|" + $0.scope },
                        appended: &appended.smartCohorts,
                        skipped: &skipped.smartCohorts)
        Self.mergeArray(into: &merged.manualHaplotypeAssignments,
                        from: patch.manualHaplotypeAssignments,
                        key: manualHaplotypeKey,
                        appended: &appended.manualHaplotypeAssignments,
                        skipped: &skipped.manualHaplotypeAssignments)
        Self.mergeArray(into: &merged.auditLog, from: patch.auditLog,
                        key: auditEntryKey,
                        appended: &appended.auditLog,
                        skipped: &skipped.auditLog)

        return MergeResult(
            sidecar: merged,
            appendedCounts: appended,
            skippedDuplicateCounts: skipped
        )
    }

    private static func mergeArray<Element>(
        into destination: inout [Element],
        from source: [Element],
        key: (Element) -> String,
        appended: inout Int,
        skipped: inout Int
    ) {
        var seen = Set(destination.map(key))
        for entry in source {
            let k = key(entry)
            if seen.insert(k).inserted {
                destination.append(entry)
                appended += 1
            } else {
                skipped += 1
            }
        }
    }

    // MARK: - Dedup keys

    static func callOverrideKey(_ entry: GenotypeAnnotationSidecar.CallOverride) -> String {
        [entry.sample, entry.locus, entry.slot.rawValue, entry.author, entry.timestamp]
            .joined(separator: "|")
    }

    static func cellHighlightKey(_ entry: GenotypeAnnotationSidecar.CellHighlight) -> String {
        [entry.sample, entry.locus, entry.slot.rawValue, entry.author, entry.timestamp]
            .joined(separator: "|")
    }

    static func rowHighlightKey(_ entry: GenotypeAnnotationSidecar.RowHighlight) -> String {
        [entry.sample, entry.author, entry.timestamp].joined(separator: "|")
    }

    static func sampleNoteKey(_ entry: GenotypeAnnotationSidecar.SampleNote) -> String {
        [entry.sample, entry.author, entry.timestamp].joined(separator: "|")
    }

    static func cellCommentKey(_ entry: GenotypeAnnotationSidecar.CellComment) -> String {
        [entry.sample, entry.locus, entry.slot.rawValue, entry.author, entry.timestamp]
            .joined(separator: "|")
    }

    static func sampleStatusFlagKey(
        _ entry: GenotypeAnnotationSidecar.SampleStatusFlag
    ) -> String {
        [entry.sample, entry.author, entry.timestamp].joined(separator: "|")
    }

    static func callStatusFlagKey(_ entry: GenotypeAnnotationSidecar.CallStatusFlag) -> String {
        [entry.sample, entry.locus, entry.slot.rawValue, entry.author, entry.timestamp]
            .joined(separator: "|")
    }

    static func manualHaplotypeKey(_ entry: ManualHaplotypeAssignment) -> String {
        [entry.sample, entry.locus, entry.slot.rawValue, entry.label].joined(separator: "|")
    }

    static func auditEntryKey(_ entry: GenotypeAnnotationSidecar.AuditEntry) -> String {
        [
            entry.action,
            entry.sample,
            entry.locus ?? "",
            entry.slot?.rawValue ?? "",
            entry.author,
            entry.timestamp,
        ].joined(separator: "|")
    }

    // MARK: - Output payload

    struct AnnotationCategoryCounts: Codable, Equatable {
        var callOverrides: Int = 0
        var cellHighlights: Int = 0
        var rowHighlights: Int = 0
        var sampleNotes: Int = 0
        var cellComments: Int = 0
        var sampleStatusFlags: Int = 0
        var callStatusFlags: Int = 0
        var smartCohorts: Int = 0
        var manualHaplotypeAssignments: Int = 0
        var auditLog: Int = 0
    }

    private struct MergeSummary: Codable {
        let bundlePath: String
        let sidecarPath: String
        let appended: AnnotationCategoryCounts
        let skippedDuplicate: AnnotationCategoryCounts
    }
}
