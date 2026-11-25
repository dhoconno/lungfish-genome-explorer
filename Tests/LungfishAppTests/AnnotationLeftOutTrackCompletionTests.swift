// AnnotationLeftOutTrackCompletionTests.swift - The app's completions name the annotation tracks and notes a run reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-2 (BIO-EXPORT-MISSING-TRACK-17 rows 2, 3 and 5). The app's GenBank export runs `lungfish-cli convert`
// and read only the count of sequences in its JSON, so a track the command left out was not named in the row or the
// alert. The in-process extraction pipeline returned only the bundle's URL. The Call Variants row ended on the track's
// name alone, though the run's notes say codon merging was off. Each completion now carries the words the CLI's route
// says, from `AnnotationDatabase.LeftOutWords` and the run's notes.

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
                + "Reopen the bundle, and if this repeats, import those annotations again."
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

    // MARK: - Row 3, the in-process extraction pipeline

    func testExtractionPipelineCompletionWordsNameTheLeftOutTracks() {
        let url = URL(fileURLWithPath: "/tmp/Whole.lungfishref", isDirectory: true)

        let outcome = SequenceExtractionPipeline.BuildOutcome(bundleURL: url, leftOutTracks: missing)

        XCTAssertEqual(
            outcome.completionMessage,
            "Bundle ready. 1 annotation track is not in this bundle, because its annotation database is missing or "
                + "cannot be read: two-parent c. Reopen the bundle, and if this repeats, import those annotations again."
        )
        XCTAssertEqual(SequenceExtractionPipeline.BuildOutcome(bundleURL: url, leftOutTracks: []).completionMessage, "Bundle ready")
    }

    // MARK: - Row 5, the Call Variants row

    private let note = "Codon merging was off for this run, so its calls carry no codon or amino-acid change, because the "
        + "annotation database of Genes, the bundle's first annotation track, is missing or cannot be read. "
        + "Reopen the bundle, and if this repeats, import those annotations again."

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
