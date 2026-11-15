// TaxTriageUnmarkedFitRefusalTests.swift - A sample whose recorded BAM an older build may have fitted is refused in words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1/S2 sweep, lane BUILDDB-OLDER-DB-CLI (S2). A `taxtriage.sqlite` that a build before 2026.11.6 made holds no
// `fitted_bam_samples` key, so nothing marks a BAM that build took by a fit of its name. For sample `S1` that file can be
// `minimap2/S1_2.bam`, which belongs to sample `S1_2`, and Extract Reads wrote its reads under S1's name with no words.
// BIO's rule (R1-BIO, rank 2) refuses sample S before any read is written when the database has no key and the BAM it
// records for S is neither `S.bam` nor `S.S.dwnld.references.bam`. The database's other samples extract as before. The
// files hold no reads and the refusal comes before samtools, so no case needs a tool.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageUnmarkedFitRefusalTests: XCTestCase {

    /// The metadata of a database that a build before 2026.11.6 made, which holds no `fitted_bam_samples` key.
    private static let olderBuild = ["tool": "TaxTriage"]

    /// Case 1. No key, S1 records `minimap2/S1_2.bam`, the file is there and `minimap2/S1.bam` is not. S1 is refused in
    /// words, by either form of the result path. Red at the base, which returns `S1_2.bam` with no words.
    func testASampleWhoseRecordedBAMMayBeAnotherSamplesIsRefusedInWords() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageUnmarkedFit")
        defer { TestTempDirectory.cleanup(root) }
        _ = try placeBAM("minimap2/S1_2.bam", in: root)
        let database = try makeResult(recording: ["S1": "minimap2/S1_2.bam"], metadata: Self.olderBuild, in: root)
        for resultPath in [root, database] {
            let label = resultPath.lastPathComponent
            do {
                let found = try await ClassifierReadResolver().testingResolveBAMURL(
                    tool: .taxtriage, sampleId: "S1", resultPath: resultPath
                )
                XCTFail("\(label): no fitted mark and S1 records S1_2.bam, so none is read, but \(found.lastPathComponent) was")
            } catch let error as ClassifierExtractionError {
                XCTAssertEqual(error.errorDescription, Self.words(sample: "S1", file: "S1_2.bam", folder: root.path), label)
                XCTAssertTrue(error.blocksExtraction, "\(label): the Extract sheet shows these words and turns Extract off")
            }
        }
    }

    /// Case 2, a pin. With no key, a sample whose recorded BAM has one of its own two names is not refused.
    func testASampleWhoseRecordedBAMHasItsOwnNameIsNotRefused() async throws {
        let recordedPaths = [
            "minimap2/S1.bam", "minimap2/S1.S1.dwnld.references.bam", "S1/minimap2/S1.S1.dwnld.references.bam",
        ]
        for recorded in recordedPaths {
            let root = try TestTempDirectory.make(prefix: "TaxTriageUnmarkedFit")
            defer { TestTempDirectory.cleanup(root) }
            let bam = try placeBAM(recorded, in: root)
            let database = try makeResult(recording: ["S1": recorded], metadata: Self.olderBuild, in: root)
            for resultPath in [root, database] {
                let found = try await ClassifierReadResolver().testingResolveBAMURL(
                    tool: .taxtriage, sampleId: "S1", resultPath: resultPath
                )
                XCTAssertEqual(
                    found.resolvingSymlinksInPath().path, bam.resolvingSymlinksInPath().path,
                    "\(recorded) by \(resultPath.lastPathComponent)"
                )
            }
        }
    }

    /// Case 3, a pin. A key that marks S1 as fitted keeps today's lookup, which reads `S1_2.bam` and says so (the notice of
    /// `taxTriageScanNotice`). A key that marks nobody is no missing key, so the file is read with no notice.
    func testAMarkedFitIsReadWithItsNoticeAndIsNotRefused() async throws {
        let variants: [(label: String, fitted: [String])] = [("the key marks S1", ["S1"]), ("the key marks nobody", [])]
        for variant in variants {
            let root = try TestTempDirectory.make(prefix: "TaxTriageUnmarkedFit")
            defer { TestTempDirectory.cleanup(root) }
            _ = try placeBAM("minimap2/S1_2.bam", in: root)
            var metadata = Self.olderBuild
            metadata[TaxTriageDatabase.fittedBAMSamplesMetadataKey] =
                TaxTriageDatabase.fittedBAMSamplesMetadataValue(variant.fitted)
            let database = try makeResult(recording: ["S1": "minimap2/S1_2.bam"], metadata: metadata, in: root)
            for resultPath in [root, database] {
                let label = "\(variant.label), by \(resultPath.lastPathComponent)"
                let found = try await ClassifierReadResolver().testingResolveBAMURL(
                    tool: .taxtriage, sampleId: "S1", resultPath: resultPath
                )
                XCTAssertEqual(found.lastPathComponent, "S1_2.bam", label)
                let notice = ClassifierReadResolver.taxTriageScanNotice(
                    tool: .taxtriage, sampleId: "S1", resultPath: resultPath, bam: found
                )
                if variant.fitted.isEmpty {
                    XCTAssertNil(notice, label)
                } else {
                    let opening = "Sample S1's own BAM was not found when Lungfish built this result's database"
                    XCTAssertTrue(notice?.hasPrefix(opening) == true, "\(label): \(notice ?? "no notice")")
                }
            }
        }
    }

    /// Case 4, a pin. With no key, S1 records `S1_2.bam` and S2 records `S2.bam`. S1's refusal is S1's alone, so S2 still
    /// resolves to its own file.
    func testTheOtherSamplesOfTheDatabaseStillResolve() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageUnmarkedFit")
        defer { TestTempDirectory.cleanup(root) }
        _ = try placeBAM("minimap2/S1_2.bam", in: root)
        let s2 = try placeBAM("minimap2/S2.bam", in: root)
        let database = try makeResult(
            recording: ["S1": "minimap2/S1_2.bam", "S2": "minimap2/S2.bam"], metadata: Self.olderBuild, in: root
        )
        for resultPath in [root, database] {
            let found = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "S2", resultPath: resultPath
            )
            XCTAssertEqual(
                found.resolvingSymlinksInPath().path, s2.resolvingSymlinksInPath().path, resultPath.lastPathComponent
            )
        }
    }

    /// A pin of the ruling's last line. A recorded file that is not there stays the missing-BAM refusal, since no file
    /// would be read, and the refusal names the sample.
    func testARecordedFileThatIsNotThereKeepsTheMissingBAMRefusal() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageUnmarkedFit")
        defer { TestTempDirectory.cleanup(root) }
        let database = try makeResult(recording: ["S1": "minimap2/S1_2.bam"], metadata: Self.olderBuild, in: root)
        do {
            let found = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "S1", resultPath: database
            )
            XCTFail("the recorded BAM is not on disk, but \(found.lastPathComponent) was read")
        } catch let error as ClassifierExtractionError {
            XCTAssertEqual(error, .bamNotFound(sampleId: "S1"))
        }
    }

    // MARK: - Helpers

    /// The refusal's words for `file`, the BAM that the database records for `sample`, and the result folder `folder`.
    private static func words(sample: String, file: String, folder: String) -> String {
        "This result's database was built by a version of Lungfish before 2026.11.6, so the BAM it records for sample "
            + "'\(sample)', \(file), may be another sample's. No reads were extracted. "
            + "Run `lungfish-cli build-db taxtriage \"\(folder)\" --force`, then extract again."
    }

    /// Writes a placeholder BAM at `relative` under `root`, with the BGZF magic the other layout tests write.
    private func placeBAM(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1F, 0x8B]).write(to: url)
        return url
    }

    /// Writes `taxtriage.sqlite` in `root` with `metadata` and one row for each sample, with the BAM path that row stores.
    private func makeResult(recording recorded: [String: String], metadata: [String: String], in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rows = recorded.sorted { $0.key < $1.key }.map { Self.row(sample: $0.key, bamPath: $0.value) }
        let url = root.appendingPathComponent("taxtriage.sqlite")
        _ = try TaxTriageDatabase.create(at: url, rows: rows, metadata: metadata)
        return url
    }

    private static func row(sample: String, bamPath: String?) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: bamPath, bamIndexPath: bamPath.map { $0 + ".bai" },
            primaryAccession: "NC_1001", accessionLength: 10_000
        )
    }
}
