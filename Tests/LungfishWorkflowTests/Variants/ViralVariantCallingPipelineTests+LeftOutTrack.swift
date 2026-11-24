// ViralVariantCallingPipelineTests+LeftOutTrack.swift - iVar says when codon merging was off, and why
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ANNOT-EXPORT-MISSING-TRACK (BIO-EXPORT-MISSING-TRACK-17 row 5). iVar merges codons from the GFF of the bundle's
// first annotation track. When that track's database was missing the pipeline logged an error and ran iVar with no
// GFF, so the calls carried no codon or amino-acid change and nothing the person reads said so. The run's result
// now says that codon merging was off and names the track, and its caller settings record `left_out_tracks`.

import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

extension ViralVariantCallingPipelineTests {
    func testIVarRunWhoseFirstTracksDatabaseIsMissingSaysCodonMergingWasOffAndNamesTheTrack() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(
            caller: .ivar,
            annotations: [
                AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.db", databasePath: "annotations/genes.db"),
            ],
            toolRunner: toolRunner
        )

        let result = try await pipeline.run()

        XCTAssertFalse(result.commandLine.contains("ivar-annotations.gff3"), "iVar ran with no GFF. \(result.commandLine)")
        XCTAssertTrue(
            result.callerParametersJSON.contains("\"left_out_tracks\":[\"Genes\"]"),
            "the caller settings name the track left out. \(result.callerParametersJSON)"
        )
        XCTAssertTrue(
            result.callerParametersJSON.contains("\"ivarCodonMerging\":\"off\""),
            "the caller settings say codon merging was off. \(result.callerParametersJSON)"
        )
        let said = String(describing: result)
        XCTAssertTrue(said.contains("Codon merging was off"), "the run's result says codon merging was off. \(said)")
        XCTAssertTrue(said.contains("Genes"), "the run's result names the track. \(said)")
    }

    func testIVarRunOfABundleWithNoAnnotationTrackRecordsNoLeftOutTrack() async throws {
        let toolRunner = try makeFakeVariantToolRunner()
        let pipeline = try makePipeline(caller: .ivar, toolRunner: toolRunner)

        let result = try await pipeline.run()

        XCTAssertFalse(result.callerParametersJSON.contains("left_out_tracks"), result.callerParametersJSON)
        XCTAssertFalse(String(describing: result).contains("Codon merging was off"), "an unannotated bundle is normal")
    }
}
