// AffectedResults+AnnotationRoutes.swift - The affected rows of the annotation S1 fixes before Preview 2026.11.17
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension AffectedResults.RecordName {
    /// `lungfish extract sequence`, the record of the command and of the region bundle the app asks it for
    /// (`ExtractSequenceSubcommand+Bundle.swift:123`, `SequenceExtractionPipeline.cliArguments`).
    public static let extractSequence = "lungfish extract sequence"
    /// The window's own extraction route (`SequenceExtractionPipeline.swift:47`).
    public static let guiSequenceExtraction = "lungfish gui sequence extraction"
    /// `lungfish annotation track import` (`ReferenceBundleAnnotationImportService.swift:485`, `:611`). An import writes its
    /// canonical record to the bundle's root last (`:660`), so it is also the record of the bundle the import ended in.
    public static let annotationTrackImport = "lungfish annotation track import"
    /// The root a bundle's record takes when the caller of `NativeBundleBuilder` names none, which is `bundle create`
    /// (`NativeBundleBuilder.swift:310-311`, `BundleCreateSubcommand.swift` passes no name).
    public static let nativeBundleBuild = "NativeBundleBuilder.build"
}

extension AffectedResults {
    /// The rows of the annotation S1 fixes before Preview 2026.11.17 (lane ANNOT-EXPORT and its folds, AFFECTED-WORDS-17).
    /// Preview 2026.11.16 (14223) lacks each fix, so each row ends there. Stable 2026.11.14, a patch build stamped 13927, lacks
    /// each fix too. A row names the count of the commit that brought its defect in when a ruling measured it, and nil otherwise.
    static let annotationRouteRows: [AffectedResultRow] = [
        // ANNOT-EXPORT names each left-out track on five routes. Of them only an extraction bundle and iVar calls are results
        // with a record. The other three write plain files (AFFECTED-WORDS-17 item 1).
        AffectedResultRow(
            backlogID: "ANNOT-EXPORT-MISSING-TRACK",
            kinds: [.sequenceExtractionBundle, .variantCallsWithoutCodonMerging], firstBuild: nil, lastBuild: 14223,
            sentence: "If an annotation track of the reference had a missing or unreadable file, the old version left "
                + "that track out with no warning, so this result can lack its annotations or, for iVar calls, "
                + "every codon and amino-acid change.",
            whatToDo: "Open the reference, import any annotations that are missing, then make this result again with "
                + "this version, which names any track it leaves out.",
            fixCommit: "6b31ac82f"
        ),
        // fa1506511 (2026-02-17) keyed copied rows on name, type, chromosome, start, end and strand (BIO-EXTRACT-DROPS-17).
        AffectedResultRow(
            backlogID: "EXTRACT-SAME-SITE-DEDUP", kinds: [.sequenceExtractionBundle], firstBuild: 256, lastBuild: 14223,
            sentence: "The version that made this bundle could leave out an annotation that shared its name, type and "
                + "exact position with another, such as two modification sites on one codon.",
            whatToDo: "Extract the region again with this version, which keeps every annotation.",
            fixCommit: "9048ba543"
        ),
        // 4b37d5d59 (2026-02-07) keyed GFF3 and GTF rows on name, type, seqid, start and end (BIO-GFF3-IMPORT-DEDUP-17,
        // BIO-GTF-ROWS-USE-17).
        AffectedResultRow(
            backlogID: "ANNOT-IMPORT-SAME-SITE-DEDUP", kinds: [.annotationTrackImport], firstBuild: 54, lastBuild: 14223,
            sentence: "If this track came from a GFF3 or GTF file, the old version could leave out a feature that shared "
                + "its name, type and position with another, such as an exon two transcripts share, and its count "
                + "left them out too.",
            whatToDo: "Import the GFF3 or GTF file again with this version, which keeps every feature, then remove the "
                + "old track.",
            fixCommit: "476f8fa47"
        ),
        // A GTF transcript had no blocks and each GTF CDS line was its own row (BIO-GTF-SPLICE-17). The stored rows keep every
        // line, so the row names only the bundles an extraction wrote. Old tracks get words at the point of use.
        AffectedResultRow(
            backlogID: "GTF-SPLICE", kinds: [.sequenceExtractionJoinedExons], firstBuild: nil, lastBuild: 14223,
            sentence: "If this bundle holds a transcript or CDS taken from a GTF track with exons joined, the old "
                + "version read it as one part, so the sequence keeps its introns or holds only one exon's piece of "
                + "the CDS.",
            whatToDo: "Attach the GTF file again with this version, which joins each transcript's exons, then extract "
                + "the feature again.",
            fixCommit: "0c7f35452"
        ),
    ]

    // MARK: - The kinds the records of these routes name

    /// A record's option, from the explicit options first and then the resolved ones, since both extraction routes write both
    /// (`SequenceExtractionPipeline.extractionExplicitOptions` and `extractionResolvedOptions`).
    private static func extractionOption(_ key: String, in envelope: ProvenanceEnvelope) -> ParameterValue? {
        envelope.options.explicit[key] ?? envelope.options.resolvedDefaults[key]
    }

    /// Whether `envelope`, a record of an extraction, names a source bundle. The region bundle of a FASTA input records
    /// `source_bundle` as null and keeps no track (`ExtractSequenceSubcommand+Bundle.swift:204-210`), so it is no kind. A record
    /// whose options hold no such key names the bundle in its command (`--source-bundle` of the window's route, `--bundle` of
    /// the command's).
    static func extractedFromASourceBundle(_ envelope: ProvenanceEnvelope) -> Bool {
        if let named = extractionOption("source_bundle", in: envelope) {
            switch named {
            case .file: return true
            case .string(let path): return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
        return envelope.argv.contains("--source-bundle") || envelope.argv.contains("--bundle")
    }

    /// Whether the extraction `envelope` records asked for the exons of a feature to be joined (`concatenate_exons`).
    static func askedForJoinedExons(_ envelope: ProvenanceEnvelope) -> Bool {
        if case .boolean(let asked)? = extractionOption("concatenate_exons", in: envelope) { return asked }
        return envelope.argv.contains("--concatenate-exons")
    }

    /// Whether a word of the command lists more than one interval of a sequence, `chr1:3-6,11-14`, as the app's command lists
    /// the parts of a feature (`SequenceExtractionPipeline.regionAndFeatureArguments`). The window's own route names a span
    /// only, so its record cannot tell the number of parts.
    static func namesSeveralParts(_ envelope: ProvenanceEnvelope) -> Bool {
        envelope.argv.contains { word in
            guard let colon = word.lastIndex(of: ":") else { return false }
            let intervals = word[word.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
            guard intervals.count > 1 else { return false }
            return intervals.allSatisfy { interval in
                let ends = interval.split(separator: "-", omittingEmptySubsequences: false)
                return ends.count == 2 && ends.allSatisfy { end in !end.isEmpty && end.allSatisfy { $0.isASCII && $0.isNumber } }
            }
        }
    }

    /// Whether `envelope` is the record of an extraction that asked for exons joined and names no second part, which is how
    /// the old build read a GTF transcript or CDS (GTF-SPLICE). A record that cannot tell the parts keeps the kind, and the
    /// words of the row start with "If".
    static func askedForJoinedExonsOfOnePart(_ envelope: ProvenanceEnvelope) -> Bool {
        let root = envelope.workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [RecordName.extractSequence, RecordName.guiSequenceExtraction].contains(root)
            && askedForJoinedExons(envelope) && !namesSeveralParts(envelope)
    }

    /// Whether `envelope`, a record of `lungfish variants call`, holds an iVar step that was given no annotation file, so codon
    /// merging was off (`ViralVariantCallingPipeline.ivarVariantArguments` adds `-g` only when the GFF export returned a file).
    /// A reference with no annotations runs the same way, so the row says "If".
    static func ranIVarWithoutAnAnnotationFile(_ envelope: ProvenanceEnvelope) -> Bool {
        let ivarSteps = envelope.steps.filter { ranTool("ivar", $0) }
        return !ivarSteps.isEmpty && !ivarSteps.contains { $0.argv.contains("-g") }
    }

    /// Whether `step` ran `tool`, by the tool name a caller records or the executable of its argv.
    private static func ranTool(_ tool: String, _ step: ProvenanceStep) -> Bool {
        step.toolName.lowercased() == tool
            || step.argv.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == tool } == true
    }

    /// Whether `envelope`, the record of an annotation import or of a bundle build, lists a GFF3 or GTF file among its inputs,
    /// or names the format. A BED track holds no feature that shares a place with another (ANNOT-IMPORT-SAME-SITE-DEDUP).
    static func importedAGFF3OrGTFFile(_ envelope: ProvenanceEnvelope) -> Bool {
        let inputs = envelope.files.filter { $0.role == .input } + envelope.steps.flatMap(\.inputs)
        if inputs.contains(where: { isAGFF3OrGTFPath($0.path) }) { return true }
        if case .string(let format)? = envelope.options.explicit["format"] {
            return ["gff3", "gff", "gtf"].contains(format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    private static func isAGFF3OrGTFPath(_ path: String) -> Bool {
        var name = path.lowercased()
        if name.hasSuffix(".gz") { name.removeLast(3) }
        return [".gff3", ".gff", ".gtf"].contains { name.hasSuffix($0) }
    }
}
