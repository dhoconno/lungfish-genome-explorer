// AnnotationLeftOutTrackCompletionTests.swift - The app's completions name the annotation tracks and notes a run reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-2 (BIO-EXPORT-MISSING-TRACK-17 rows 2, 3 and 5). The app's GenBank export runs `lungfish-cli convert`
// and read only the count of sequences in its JSON, so a track the command left out was not named in the row or the
// alert. The in-process extraction pipeline returned only the bundle's URL. The Call Variants row ended on the track's
// name alone, though the run's notes say codon merging was off. Each completion now carries the words the CLI's route
// says, from `AnnotationDatabase.LeftOutWords` and the run's notes.
//
// ANNOT-EXPORT-3. The batch GenBank export names each left-out track with its file (BIO and UX review B1), each
// completion ends on the step to repeat (SF-3), and the sidebar GFF3 export's alert is pinned (SWIFT and ARCH SF-2 a).

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class AnnotationLeftOutTrackCompletionTests: XCTestCase {
    private let missing = [AnnotationDatabase.LeftOutTrack(id: "track-c", name: "two-parent c")]

    // MARK: - Row 2, the app's GenBank export

    func testSequenceExportReadsTheLeftOutTracksTheConvertJSONNamesAndSaysSoInItsCompletion() throws {
        let json = #"{"sequenceCount":1,"annotationCount":3,"leftOutTracks":[{"id":"track-c","name":"two-parent c"}]}"#

        let outcome = try SequenceExportRoute.outcome(in: json)

        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.leftOutTracks, missing)
        XCTAssertEqual(
            AppDelegate.sequenceExportCompletionWords(count: outcome.count, fileName: "NG-4tracks.gb", leftOut: outcome.leftOutTracks),
            "Exported 1 sequence(s) to NG-4tracks.gb. 1 annotation track is not in this file, because its annotation "
                + "database is missing or cannot be read: two-parent c. "
                + "Reopen the bundle, and if this repeats, import those annotations again. Then export again."
        )
    }

    /// A healthy export keeps the words of the base.
    func testSequenceExportOfAHealthyBundleKeepsItsWords() throws {
        let outcome = try SequenceExportRoute.outcome(in: #"{"sequenceCount":2,"annotationCount":4}"#)

        XCTAssertEqual(outcome.count, 2)
        XCTAssertEqual(outcome.leftOutTracks, [])
        XCTAssertEqual(
            AppDelegate.sequenceExportCompletionWords(count: 2, fileName: "a.gb", leftOut: outcome.leftOutTracks),
            "Exported 2 sequence(s) to a.gb"
        )
    }

    // MARK: - Row 2, the batch GenBank export (BIO and UX review B1)

    /// Each file of a batch can lack a track, so the words name each left-out track with its file.
    func testBatchExportWordsNameEachLeftOutTrackWithItsFile() throws {
        let two: [(file: String, tracks: [AnnotationDatabase.LeftOutTrack])] = [
            ("a.gb", [AnnotationDatabase.LeftOutTrack(id: "track-c", name: "two-parent c")]),
            ("b.gb", [AnnotationDatabase.LeftOutTrack(id: "g", name: "Genes")]),
        ]

        let words = try XCTUnwrap(AppDelegate.batchSequenceExportLeftOutWords(two))

        XCTAssertTrue(words.contains("2 annotation tracks are not in their files"), words)
        XCTAssertTrue(words.contains("two-parent c (a.gb)"), words)
        XCTAssertTrue(words.contains("Genes (b.gb)"), words)
        XCTAssertTrue(
            words.hasSuffix("Reopen the bundle, and if this repeats, import those annotations again. Then export again."), words
        )
        let one: [(file: String, tracks: [AnnotationDatabase.LeftOutTrack])] = [("NG-4tracks.gb", missing)]
        XCTAssertEqual(
            AppDelegate.batchSequenceExportLeftOutWords(one),
            "1 annotation track is not in its file, because its annotation database is missing or cannot be read: "
                + "two-parent c (NG-4tracks.gb). Reopen the bundle, and if this repeats, import those annotations again. "
                + "Then export again."
        )
        XCTAssertNil(AppDelegate.batchSequenceExportLeftOutWords([]))
        XCTAssertNil(AppDelegate.batchSequenceExportLeftOutWords([("a.gb", [])]))
    }

    /// The row's detail and the alert of the batch: a healthy batch keeps its words byte for byte.
    func testBatchExportCompletionKeepsTheHealthyWordsAndAddsTheLeftOutWordsAfterThem() {
        let healthy = AppDelegate.batchSequenceExportCompletionWords(
            fileCount: 2, sequenceCount: 5, folderName: "Exports", leftOut: [("a.gb", []), ("b.gb", [])]
        )
        XCTAssertEqual(healthy.detail, "Exported 2 file(s) with 5 sequence(s)")
        XCTAssertEqual(healthy.alert, "Exported 2 file(s) with 5 sequence(s) to Exports.")

        let damaged = AppDelegate.batchSequenceExportCompletionWords(
            fileCount: 2, sequenceCount: 3, folderName: "Exports", leftOut: [("NG-4tracks.gb", missing), ("b.gb", [])]
        )
        let words = "1 annotation track is not in its file, because its annotation database is missing or cannot be read: "
            + "two-parent c (NG-4tracks.gb). Reopen the bundle, and if this repeats, import those annotations again. "
            + "Then export again."
        XCTAssertEqual(damaged.detail, "Exported 2 file(s) with 3 sequence(s). " + words)
        XCTAssertEqual(damaged.alert, "Exported 2 file(s) with 3 sequence(s) to Exports. " + words)
    }

    // MARK: - Row 1, the sidebar GFF3 export's alert (SWIFT and ARCH review SF-2 a)

    func testSidebarGFF3ExportCompletionWordsNameTheLeftOutTracksAndKeepTheHealthyWords() {
        XCTAssertEqual(
            AppDelegate.annotationGFF3ExportCompletionWords(
                count: 110, sourceName: "NG-4tracks", fileName: "NG-4tracks.gff3", leftOut: missing
            ),
            "Exported 110 annotations from NG-4tracks to NG-4tracks.gff3. 1 annotation track is not in this file, because "
                + "its annotation database is missing or cannot be read: two-parent c. "
                + "Reopen the bundle, and if this repeats, import those annotations again. Then export again."
        )
        XCTAssertEqual(
            AppDelegate.annotationGFF3ExportCompletionWords(
                count: 114, sourceName: "NG-4tracks", fileName: "NG-4tracks.gff3", leftOut: []
            ),
            "Exported 114 annotations from NG-4tracks to NG-4tracks.gff3."
        )
    }

    // MARK: - Row 3, the in-process extraction pipeline

    func testExtractionPipelineCompletionWordsNameTheLeftOutTracks() {
        let url = URL(fileURLWithPath: "/tmp/Whole.lungfishref", isDirectory: true)

        let outcome = SequenceExtractionPipeline.BuildOutcome(bundleURL: url, leftOutTracks: missing)

        XCTAssertEqual(
            outcome.completionMessage,
            "Bundle ready. 1 annotation track is not in this bundle, because its annotation database is missing or "
                + "cannot be read: two-parent c. Reopen the bundle, and if this repeats, import those annotations again. "
                + "Then extract again."
        )
        XCTAssertEqual(SequenceExtractionPipeline.BuildOutcome(bundleURL: url, leftOutTracks: []).completionMessage, "Bundle ready")
    }

    // MARK: - Row 5, the Call Variants row

    private let note = "Codon merging was off for this run, because the annotation database of Genes, the bundle's first "
        + "annotation track, is missing or cannot be read. So its calls carry no codon or amino-acid change. "
        + "Reopen the bundle, and if this repeats, import those annotations again. Then call variants again."

    func testCallVariantsCompletionCarriesTheNotesTheCLIReports() throws {
        let encoded = String(decoding: try JSONEncoder().encode([note]), as: UTF8.self)
        let message = "trackID=vc-1 trackName=Sample • iVar notes=" + encoded

        let result = CLIVariantCallingRunner.parseCompletion(outputs: ["/db", "/vcf", "/tbi"], message: message, artifacts: [])

        XCTAssertEqual(result.trackID, "vc-1")
        XCTAssertEqual(result.trackName, "Sample • iVar", "the notes do not run into the track's name")
        XCTAssertEqual(result.notes, [note])
        XCTAssertEqual(
            InspectorViewController.variantCallingCompletionDetail(for: result),
            "Created variant track Sample • iVar. " + note
        )
    }

    /// A run with no notes keeps the row's words.
    func testCallVariantsCompletionWithNoNotesKeepsItsWords() {
        let result = CLIVariantCallingRunner.parseCompletion(
            outputs: ["/db", "/vcf", "/tbi"], message: "trackID=vc-1 trackName=Sample • LoFreq", artifacts: []
        )

        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(InspectorViewController.variantCallingCompletionDetail(for: result), "Created variant track Sample • LoFreq")
    }
}
