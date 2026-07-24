import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Merge an annotation patch JSON into a bundle's existing annotation sidecar.
///
/// The patch JSON has the same schema as `annotations.json`
/// (`GenotypeAnnotationSidecar`) but typically contains only the entries the
/// caller wants to merge. Existing entries in the bundle are preserved; new
/// entries are appended after de-duplication on
/// `sample+locus+slot+author+timestamp` (or the relevant subset for entries
/// without a locus or slot). Matrix comments and semantic reviews instead
/// retain one current value for each exact matrix target.
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
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let patchURL = URL(fileURLWithPath: patch)
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundleURL
        )
        let priorSidecarInput = FileManager.default.fileExists(atPath: sidecarURL.path)
            ? ProvenanceRecorder.fileRecord(url: sidecarURL, format: .json, role: .input)
            : nil

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
        try await recordApplyAnnotationsProvenance(
            bundleURL: bundleURL,
            patchURL: patchURL,
            sidecarURL: sidecarURL,
            priorSidecarInput: priorSidecarInput,
            merge: merge,
            startedAt: startedAt
        )

        let summary = MergeSummary(
            bundlePath: bundleURL.path,
            sidecarPath: sidecarURL.path,
            appended: merge.appendedCounts,
            skippedDuplicate: merge.skippedDuplicateCounts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func recordApplyAnnotationsProvenance(
        bundleURL: URL,
        patchURL: URL,
        sidecarURL: URL,
        priorSidecarInput: FileRecord?,
        merge: MergeResult,
        startedAt: Date
    ) async throws {
        var parameters: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "patch": .file(patchURL),
            "annotationSidecar": .file(sidecarURL),
        ]
        Self.addCounts(merge.appendedCounts, prefix: "appended", to: &parameters)
        Self.addCounts(merge.skippedDuplicateCounts, prefix: "skippedDuplicate", to: &parameters)
        let inputs = [
            ProvenanceRecorder.fileRecord(url: patchURL, format: .json, role: .input),
            priorSidecarInput,
        ].compactMap { $0 }
        let outputs = [
            ProvenanceRecorder.fileRecord(url: sidecarURL, format: .json, role: .output),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish genotype apply-annotations",
            parameters: parameters,
            defaults: [
                "patchSchema": .string(GenotypeAnnotationSidecar.filename),
                "mergeMode": .string("append-deduplicate-with-current-matrix-targets"),
            ],
            resolved: parameters,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                CLICommandIdentity.executableName,
                "genotype",
                "apply-annotations",
                "--bundle", bundleURL.path,
                "--patch", patchURL.path,
            ],
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: max(0, Date().timeIntervalSince(startedAt)),
            stderr: nil,
            status: .completed,
            outputDirectory: bundleURL,
            writeFileSidecars: true
        )
    }

    private static func addCounts(
        _ counts: AnnotationCategoryCounts,
        prefix: String,
        to parameters: inout [String: ParameterValue]
    ) {
        parameters["\(prefix)CallOverrides"] = .integer(counts.callOverrides)
        parameters["\(prefix)CellHighlights"] = .integer(counts.cellHighlights)
        parameters["\(prefix)RowHighlights"] = .integer(counts.rowHighlights)
        parameters["\(prefix)SampleNotes"] = .integer(counts.sampleNotes)
        parameters["\(prefix)CellComments"] = .integer(counts.cellComments)
        parameters["\(prefix)SampleStatusFlags"] = .integer(counts.sampleStatusFlags)
        parameters["\(prefix)CallStatusFlags"] = .integer(counts.callStatusFlags)
        parameters["\(prefix)SmartCohorts"] = .integer(counts.smartCohorts)
        parameters["\(prefix)MatrixStyles"] = .integer(counts.matrixStyles)
        parameters["\(prefix)MatrixComments"] = .integer(counts.matrixComments)
        parameters["\(prefix)MatrixReviews"] = .integer(counts.matrixReviews)
        parameters["\(prefix)ManualHaplotypeAssignments"] = .integer(counts.manualHaplotypeAssignments)
        parameters["\(prefix)AuditLog"] = .integer(counts.auditLog)
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
        merged.schemaVersion = max(
            merged.schemaVersion,
            GenotypeAnnotationSidecar.currentSchemaVersion
        )
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
        Self.mergeMatrixStyles(
            into: &merged.matrixStyles,
            from: patch.matrixStyles,
            changed: &appended.matrixStyles,
            skipped: &skipped.matrixStyles
        )
        Self.mergeCurrentMatrixEntries(
            into: &merged.matrixComments,
            from: patch.matrixComments,
            target: { $0.target },
            changed: &appended.matrixComments,
            skipped: &skipped.matrixComments
        )
        Self.mergeCurrentMatrixEntries(
            into: &merged.matrixReviews,
            from: patch.matrixReviews,
            target: { $0.target },
            changed: &appended.matrixReviews,
            skipped: &skipped.matrixReviews
        )
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

    private static func mergeMatrixStyles(
        into destination: inout [GenotypeAnnotationSidecar.MatrixStyleAnnotation],
        from source: [GenotypeAnnotationSidecar.MatrixStyleAnnotation],
        changed: inout Int,
        skipped: inout Int
    ) {
        for entry in source {
            if let existingIndex = destination.firstIndex(where: { $0.target == entry.target }) {
                if destination[existingIndex] == entry {
                    skipped += 1
                } else {
                    destination[existingIndex] = entry
                    changed += 1
                }
            } else {
                destination.append(entry)
                changed += 1
            }
        }
    }

    private static func mergeCurrentMatrixEntries<Element: Equatable>(
        into destination: inout [Element],
        from source: [Element],
        target: (Element) -> GenotypeAnnotationSidecar.MatrixTarget,
        changed: inout Int,
        skipped: inout Int
    ) {
        for entry in source {
            let targetKey = target(entry)
            let matchingIndices = destination.indices.filter { target(destination[$0]) == targetKey }
            guard let firstIndex = matchingIndices.first else {
                destination.append(entry)
                changed += 1
                continue
            }
            if matchingIndices.count == 1, destination[firstIndex] == entry {
                skipped += 1
                continue
            }
            for index in matchingIndices.reversed() {
                destination.remove(at: index)
            }
            destination.insert(entry, at: firstIndex)
            changed += 1
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
        var matrixStyles: Int = 0
        var matrixComments: Int = 0
        var matrixReviews: Int = 0
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
