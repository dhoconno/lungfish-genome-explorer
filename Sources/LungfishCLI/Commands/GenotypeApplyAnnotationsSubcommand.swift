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
/// Smart cohorts (plan decisions O2 and G2) are the same cohort when both
/// store an id and the ids are equal, so a cohort renamed in the patch is not
/// added a second time. When either stores none they are the same cohort when
/// the name and scope match, as before. The bundle's cohorts store their
/// derived ids before the patch applies, and the rewritten sidecar stores the
/// derived id of every cohort that still has none.
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
        let runClock = ProvenanceRunClock()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let patchURL = URL(fileURLWithPath: patch)
        let merge = try await Self.apply(
            bundleURL: bundleURL,
            patchURL: patchURL,
            runClock: runClock
        )
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundleURL
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

    static func apply(
        bundleURL: URL,
        patchURL: URL,
        runClock: ProvenanceRunClock = ProvenanceRunClock(),
        beforePublication: () throws -> Void = {}
    ) async throws -> MergeResult {
        let patchData = try Data(contentsOf: patchURL)
        let patchSidecar = try GenotypeAnnotationSidecar.decode(patchData)
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundleURL
        )
        defer { publicationLock.release() }

        try GenotypeAnnotationPairPublication.restoreInterruptedSwap(inBundleAt: bundleURL)
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
        let sidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(
            forBundleAt: bundleURL
        )
        let merge = try Self.merge(
            existing: snapshot.sidecar,
            patch: patchSidecar
        )
        try beforePublication()
        var published = merge.sidecar
        try published.promoteToCurrentSchema()
        let annotationData = try published.encoded()
        let output = GenotypeAnnotationPairPublication.descriptor(
            data: annotationData,
            url: sidecarURL,
            role: .output
        )
        let envelope = try applyAnnotationsEnvelope(
            bundleURL: bundleURL,
            patchURL: patchURL,
            sidecarURL: sidecarURL,
            priorData: snapshot.data,
            output: output,
            merge: merge,
            runClock: runClock
        )
        // The sidecar and its record go out as one pair, and the bundle's own records follow.
        let recordURL = ProvenanceRecorder.fileSidecarURL(for: sidecarURL)
        try GenotypeAnnotationPairPublication.publish(
            annotationData: annotationData,
            recordURL: recordURL,
            recordMustBeNew: false,
            bundleURL: bundleURL,
            assuming: publicationLock,
            check: {
                try GenotypeAnnotationPairPublication.checkRevision($0, expected: snapshot.revision)
            },
            publishRecord: {
                try ProvenanceWriter().write(envelope.focusedOnOutput(output), toSidecar: recordURL)
            }
        )
        try ProvenanceWriter().write(envelope, to: bundleURL)
        return merge
    }

    /// The run record, built from the bytes the command read and wrote, never from paths that
    /// change while it runs.
    private static func applyAnnotationsEnvelope(
        bundleURL: URL,
        patchURL: URL,
        sidecarURL: URL,
        priorData: Data?,
        output: ProvenanceFileDescriptor,
        merge: MergeResult,
        runClock: ProvenanceRunClock
    ) throws -> ProvenanceEnvelope {
        var parameters: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "patch": .file(patchURL),
            "annotationSidecar": .file(sidecarURL),
        ]
        Self.addCounts(merge.appendedCounts, prefix: "appended", to: &parameters)
        Self.addCounts(merge.skippedDuplicateCounts, prefix: "skippedDuplicate", to: &parameters)
        let defaults: [String: ParameterValue] = [
            "patchSchema": .string(GenotypeAnnotationSidecar.filename),
            "mergeMode": .string("append-deduplicate-with-current-matrix-targets"),
        ]
        let command = [
            CLICommandIdentity.executableName,
            "genotype",
            "apply-annotations",
            "--bundle", bundleURL.path,
            "--patch", patchURL.path,
        ]
        let patchInput = try ProvenanceFileDescriptor.file(url: patchURL, format: .json, role: .input)
        let priorInput = priorData.map {
            GenotypeAnnotationPairPublication.descriptor(data: $0, url: sidecarURL, role: .input)
        }
        let completedAt = Date()
        let wallTime = runClock.elapsed
        let startedAt = completedAt.addingTimeInterval(-wallTime)
        var builder = ProvenanceRunBuilder(
            workflowName: "lungfish genotype apply-annotations",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: CLICommandIdentity.executableName,
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(command)
        .durableReplayArgv(command)
        .options(
            explicit: parameters,
            defaults: defaults,
            resolved: CLIProvenanceSupport.resolvedOptions(
                explicit: parameters,
                defaults: defaults,
                resolved: parameters
            )
        )
        .runtime(ProvenanceRuntimeIdentity())
        builder = try builder.input(patchURL, format: .json, role: .input)
        if let priorInput {
            builder = try builder.consumedInputSnapshot(priorInput)
        }
        return try builder
            .step(ProvenanceStep(
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion,
                argv: command,
                inputs: [patchInput] + [priorInput].compactMap { $0 },
                outputs: [output],
                exitStatus: 0,
                wallTimeSeconds: wallTime,
                startedAt: startedAt,
                completedAt: completedAt
            ))
            .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
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
    ) throws -> MergeResult {
        var merged = existing
        try merged.promoteToCurrentSchema()
        // The bundle's cohorts store their derived ids before the patch applies,
        // so a patch that renames one of them still names the same cohort.
        merged.storeSmartCohortIDs()
        var validatedPatch = patch
        try validatedPatch.promoteToCurrentSchema()
        var appended = AnnotationCategoryCounts()
        var skipped = AnnotationCategoryCounts()

        Self.mergeArray(into: &merged.callOverrides, from: validatedPatch.callOverrides,
                        key: callOverrideKey,
                        appended: &appended.callOverrides,
                        skipped: &skipped.callOverrides)
        Self.mergeArray(into: &merged.cellHighlights, from: validatedPatch.cellHighlights,
                        key: cellHighlightKey,
                        appended: &appended.cellHighlights,
                        skipped: &skipped.cellHighlights)
        Self.mergeArray(into: &merged.rowHighlights, from: validatedPatch.rowHighlights,
                        key: rowHighlightKey,
                        appended: &appended.rowHighlights,
                        skipped: &skipped.rowHighlights)
        Self.mergeArray(into: &merged.sampleNotes, from: validatedPatch.sampleNotes,
                        key: sampleNoteKey,
                        appended: &appended.sampleNotes,
                        skipped: &skipped.sampleNotes)
        Self.mergeArray(into: &merged.cellComments, from: validatedPatch.cellComments,
                        key: cellCommentKey,
                        appended: &appended.cellComments,
                        skipped: &skipped.cellComments)
        Self.mergeArray(into: &merged.sampleStatusFlags, from: validatedPatch.sampleStatusFlags,
                        key: sampleStatusFlagKey,
                        appended: &appended.sampleStatusFlags,
                        skipped: &skipped.sampleStatusFlags)
        Self.mergeArray(into: &merged.callStatusFlags, from: validatedPatch.callStatusFlags,
                        key: callStatusFlagKey,
                        appended: &appended.callStatusFlags,
                        skipped: &skipped.callStatusFlags)
        Self.mergeSmartCohorts(into: &merged.smartCohorts, from: validatedPatch.smartCohorts,
                               appended: &appended.smartCohorts,
                               skipped: &skipped.smartCohorts)
        merged.storeSmartCohortIDs()
        Self.mergeMatrixStyles(
            into: &merged.matrixStyles,
            from: validatedPatch.matrixStyles,
            changed: &appended.matrixStyles,
            skipped: &skipped.matrixStyles
        )
        Self.mergeCurrentMatrixEntries(
            into: &merged.matrixComments,
            from: validatedPatch.matrixComments,
            target: { $0.target },
            changed: &appended.matrixComments,
            skipped: &skipped.matrixComments
        )
        Self.mergeCurrentMatrixEntries(
            into: &merged.matrixReviews,
            from: validatedPatch.matrixReviews,
            target: { $0.target },
            changed: &appended.matrixReviews,
            skipped: &skipped.matrixReviews
        )
        Self.mergeArray(into: &merged.manualHaplotypeAssignments,
                        from: validatedPatch.manualHaplotypeAssignments,
                        key: manualHaplotypeKey,
                        appended: &appended.manualHaplotypeAssignments,
                        skipped: &skipped.manualHaplotypeAssignments)
        Self.mergeArray(into: &merged.auditLog, from: validatedPatch.auditLog,
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

    /// Appends the patch cohorts the bundle does not hold. Two cohorts are the
    /// same when both store an id and the ids are equal, and otherwise when
    /// their name and scope match, as before the cohorts had ids.
    private static func mergeSmartCohorts(
        into destination: inout [GenotypeCohortSmartFilter],
        from source: [GenotypeCohortSmartFilter],
        appended: inout Int,
        skipped: inout Int
    ) {
        for cohort in source {
            if destination.contains(where: { isSameSmartCohort($0, cohort) }) {
                skipped += 1
            } else {
                destination.append(cohort)
                appended += 1
            }
        }
    }

    static func isSameSmartCohort(_ existing: GenotypeCohortSmartFilter, _ incoming: GenotypeCohortSmartFilter) -> Bool {
        if let existingID = existing.id, let incomingID = incoming.id {
            return existingID == incomingID
        }
        return smartCohortKey(existing) == smartCohortKey(incoming)
    }

    static func smartCohortKey(_ cohort: GenotypeCohortSmartFilter) -> String {
        cohort.name + "|" + cohort.scope
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
