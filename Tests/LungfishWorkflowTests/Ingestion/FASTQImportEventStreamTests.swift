// FASTQImportEventStreamTests.swift - The version 2 events that each log event of a batch import becomes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Lane Q4 of Phase 2.7. Each text and level is the one the app's import runner gave the S1 event
/// before, so the Operations row reads as it did, and the bar of a batch only moves forward.
final class FASTQImportEventStreamTests: XCTestCase {
    func testEachLogEventKeepsTheRowTextAndLevelOfItsS1Event() {
        var stream = FASTQImportEventStream(projectDirectory: URL(fileURLWithPath: "/work/Project.lungfish"))
        let events: [ImportLogEvent] = [
            .importStart(sampleCount: 1, recipeName: "VSP2 Target Enrichment"),
            .platformResolved(sample: "S", platform: "illumina", source: "given", confidence: "high",
                              readClass: nil, evidence: [], message: "Platform: Illumina."),
            .sampleStart(sample: "S", index: 0, total: 1, r1: "S_R1.fastq", r2: "S_R2.fastq"),
            .stepStart(sample: "S", step: "Remove human reads", stepIndex: 2, totalSteps: 4),
            .stepComplete(sample: "S", step: "Remove human reads", durationSeconds: 5.79),
            .notice(sample: "S", message: "Trim Galore --clumpify also performs adapter/quality filtering."),
            .recipeReadDelta(sample: "S", label: "Human scrub", inputReads: 1_000, outputReads: 900,
                             readsRemoved: 100, percentRemoved: 10),
            .sampleComplete(sample: "S", bundle: "S.lungfishfastq", durationSeconds: 7, originalBytes: 1, finalBytes: 1),
            .sampleSkip(sample: "T", reason: "Bundle already exists"),
            .sampleFailed(sample: "U", error: "No reads"),
            .importComplete(completed: 1, skipped: 1, failed: 1, totalDurationSeconds: 7.67),
        ]

        XCTAssertEqual(events.flatMap { stream.events(for: $0) }, [
            .log(level: .info, message: "S: Platform: Illumina."),
            .progress(fraction: 0, message: "Importing S (1/1)"),
            .progress(fraction: 0.4, message: "S: Remove human reads"),
            .log(level: .info, message: "S — step 2/4: Remove human reads"),
            .log(level: .info, message: "S — Remove human reads completed (5.8s)"),
            .log(level: .warning, message: "S — Trim Galore --clumpify also performs adapter/quality filtering."),
            .log(level: .info, message: "S — Human scrub removed 10.0% of reads (1,000 -> 900)"),
            .log(level: .info, message: "S — bundle created"),
            .log(level: .warning, message: "T skipped: Bundle already exists"),
            .log(level: .error, message: "U failed: No reads"),
            .log(level: .info, message: "Import complete — 1 done, 1 skipped, 1 failed (7.7s)"),
        ])
        XCTAssertEqual(stream.bundles, ["/work/Project.lungfish/Imports/S.lungfishfastq"])
        XCTAssertEqual(stream.failures, ["U: No reads"])
        XCTAssertEqual(stream.bundleArtifacts(), [CLIEventArtifact(
            kind: "fastq", path: "/work/Project.lungfish/Imports/S.lungfishfastq", role: "bundle", provenancePath: nil
        )])
    }

    /// UX objection 4 of the 2.7 panel. The runner drew each sample's steps from 0 to 0.8 again, and a
    /// sample's start fell to at most 0.05. One fraction for the whole import now only moves forward.
    func testTheBarOfABatchOnlyMovesForward() {
        var stream = FASTQImportEventStream(projectDirectory: URL(fileURLWithPath: "/work/Project.lungfish"))
        var fractions: [Double] = []
        for index in 0..<2 {
            let sample = "S\(index + 1)"
            let events: [ImportLogEvent] = [
                .sampleStart(sample: sample, index: index, total: 2, r1: "\(sample).fastq", r2: nil),
                .stepStart(sample: sample, step: "Optimize storage + Compress", stepIndex: 1, totalSteps: 2),
                .stepStart(sample: sample, step: "Compute statistics", stepIndex: 2, totalSteps: 2),
            ]
            for event in events {
                for case let .progress(fraction, _) in stream.events(for: event) {
                    fractions.append(fraction)
                }
            }
        }

        XCTAssertEqual(fractions.map { ($0 * 1_000).rounded() / 1_000 }, [0, 0.2, 0.4, 0.5, 0.7, 0.9])
    }

    func testANoticeReadsTheSameFromTheCLIAndFromTheImportSheet() {
        XCTAssertEqual(FASTQImportEventStream.noticeLine(sample: "SRR1", message: "Was not joined."), "SRR1 — Was not joined.")
    }
}
