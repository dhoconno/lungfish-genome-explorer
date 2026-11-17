// TaxTriageRecordedBAMNoticeTests.swift - The words that the TaxTriage view, the Inspector and BLAST Verify show for a fitted BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row BIO-WALK-T2-VIEW (S1 in kind, rare), fixes 1 and 2 of session rnaseq-5-1-e. When a sample has no BAM of its own,
// `build-db taxtriage` records a file of `minimap2/` whose name fits the sample, and `minimap2/S1_2.bam` can hold sample
// `S1_2`'s reads. Extract Reads already says so, in the words of `taxTriageBAMBeforeFitMark` for a database with no
// `fitted_bam_samples` key and in the words of `taxTriageScanNotice` for a marked fit. The TaxTriage view read the same
// file with no words, so the alignment, the depth, "% covered", the Inspector's BAM line and the reads that BLAST Verify
// sends came from it unmarked. The layer under test feeds those three places and reads the two sources of words. It reads
// the database and the folder, never a BAM, so the files hold no reads.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageRecordedBAMNoticeTests: XCTestCase {

    /// The metadata of a database that a build before 2026.11.6 made, which holds no `fitted_bam_samples` key.
    private static let olderBuild = ["tool": "TaxTriage"]

    /// The first sentence of the refusal for a database with no key, which the view, the Inspector and BLAST Verify repeat.
    private static func olderBuildSentence(sample: String, file: String) -> String {
        "This result's database was built by a version of Lungfish before 2026.11.6, so the BAM it records for sample "
            + "'\(sample)', \(file), may be another sample's."
    }

    /// The notice for a database with no key. The refusal's tail says that no reads were extracted, which is false where
    /// nothing is extracted, so the view keeps the sentence and ends with the command that builds the database anew.
    private static func olderBuildNotice(sample: String, file: String, folder: String) -> String {
        olderBuildSentence(sample: sample, file: file)
            + " Run `lungfish-cli build-db taxtriage \"\(folder)\" --force`, then open the result again."
    }

    /// The words of `taxTriageScanNotice` for sample S1 and the file `S1_2.bam` of a marked fit.
    private static let markedNotice = "Sample S1's own BAM was not found when Lungfish built this result's database, so "
        + "Lungfish read S1_2.bam, a file in the minimap2 folder whose name fits it. "
        + "If that file belongs to another sample, put S1's own BAM back, delete taxtriage.sqlite in "
        + "the result folder and select the result again so that Lungfish builds the database anew."

    // MARK: - Fix 1

    /// A foreign fit under the test's folder. S1 has no BAM of its own, `minimap2/S1_2.bam` is sample S1_2's file, and the
    /// database, which holds no key, records it for S1. The layer names the file, by either form of the result path, and
    /// says nothing for S1_2, whose own file is the one it records. Red at the base, which has no such layer.
    func testAForeignFitOfADatabaseWithNoKeyIsNamedInWords() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
        defer { TestTempDirectory.cleanup(root) }
        let foreign = try placeBAM("minimap2/S1_2.bam", in: root)
        let own = try placeBAM("minimap2/S1_2.S1_2.dwnld.references.bam", in: root)
        let database = try makeResult(
            recording: ["S1": "minimap2/S1_2.bam", "S1_2": "minimap2/S1_2.S1_2.dwnld.references.bam"],
            metadata: Self.olderBuild, in: root
        )
        for resultPath in [root, database] {
            let label = resultPath.lastPathComponent
            XCTAssertEqual(
                ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: resultPath, bam: foreign),
                Self.olderBuildNotice(sample: "S1", file: "S1_2.bam", folder: root.path), label
            )
            XCTAssertNil(
                ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1_2", resultPath: resultPath, bam: own),
                "\(label): S1_2 reads the file of its own name"
            )
        }
    }

    /// The view and Extract Reads read one sentence. The refusal's words open with it, and the view's words do not carry
    /// the refusal's sentence about extracted reads.
    func testTheViewAndTheExtractRefusalOpenWithOneSentence() {
        let folder = URL(fileURLWithPath: "/Users/someone/result")
        let refusal = ClassifierExtractionError.taxTriageBAMBeforeFitMark(
            sampleId: "S1", fileName: "S1_2.bam", resultFolder: folder
        )
        let notice = ClassifierExtractionError.taxTriageBAMBeforeFitMarkNotice(
            sampleId: "S1", fileName: "S1_2.bam", resultFolder: folder
        )
        let sentence = Self.olderBuildSentence(sample: "S1", file: "S1_2.bam")
        XCTAssertTrue(refusal.errorDescription?.hasPrefix(sentence) == true, refusal.errorDescription ?? "no words")
        XCTAssertEqual(notice, Self.olderBuildNotice(sample: "S1", file: "S1_2.bam", folder: folder.path))
        XCTAssertFalse(notice.contains("No reads were extracted"), "the view extracts nothing")
    }

    /// A sample whose recorded BAM has one of its own two names has no notice, with no key and with a key that marks another
    /// sample. A dotted id keeps its own file, and the sample before the dot is told that the same file is not its own.
    func testASampleWithItsOwnBAMHasNoNotice() throws {
        let recordedPaths = [
            "minimap2/S1.bam", "minimap2/S1.S1.dwnld.references.bam", "S1/minimap2/S1.S1.dwnld.references.bam",
        ]
        var markingS2 = Self.olderBuild
        markingS2[TaxTriageDatabase.fittedBAMSamplesMetadataKey] = TaxTriageDatabase.fittedBAMSamplesMetadataValue(["S2"])
        for metadata in [Self.olderBuild, markingS2] {
            for recorded in recordedPaths {
                let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
                defer { TestTempDirectory.cleanup(root) }
                let bam = try placeBAM(recorded, in: root)
                let database = try makeResult(recording: ["S1": recorded], metadata: metadata, in: root)
                for resultPath in [root, database] {
                    XCTAssertNil(
                        ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: resultPath, bam: bam),
                        "\(recorded) by \(resultPath.lastPathComponent), keys \(metadata.keys.sorted())"
                    )
                }
            }
        }

        let dotted = "minimap2/S1.1.S1.1.dwnld.references.bam"
        let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
        defer { TestTempDirectory.cleanup(root) }
        let bam = try placeBAM(dotted, in: root)
        let own = try makeResult(recording: ["S1.1": dotted], metadata: Self.olderBuild, in: root)
        XCTAssertNil(ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1.1", resultPath: own, bam: bam))
        let sibling = try makeResult(recording: ["S1": dotted], metadata: Self.olderBuild, in: root)
        XCTAssertEqual(
            ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: sibling, bam: bam),
            Self.olderBuildNotice(sample: "S1", file: "S1.1.S1.1.dwnld.references.bam", folder: root.path)
        )
    }

    /// A BAM that the database does not record for the sample, or that is not there to be read, is no fit that this
    /// result's database made, so no words are shown for a file the view would not show.
    func testAFileThatTheDatabaseDoesNotRecordForTheSampleHasNoNotice() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
        defer { TestTempDirectory.cleanup(root) }
        _ = try placeBAM("minimap2/S1_2.bam", in: root)
        let other = try placeBAM("minimap2/S1_3.bam", in: root)
        let database = try makeResult(recording: ["S1": "minimap2/S1_2.bam"], metadata: Self.olderBuild, in: root)
        XCTAssertNil(ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: database, bam: other))
        let missing = root.appendingPathComponent("minimap2/S1_9.bam")
        XCTAssertNil(ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: database, bam: missing))
    }

    /// The notices of the samples a page holds name the sample whose BAM is a fit and no other. S2 keeps its own file.
    func testTheNoticesOfASetOfSamplesNameOnlyTheFittedOnes() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
        defer { TestTempDirectory.cleanup(root) }
        let fitted = try placeBAM("minimap2/S1_2.bam", in: root)
        let own = try placeBAM("minimap2/S2.bam", in: root)
        _ = try makeResult(
            recording: ["S1": "minimap2/S1_2.bam", "S2": "minimap2/S2.bam"], metadata: Self.olderBuild, in: root
        )
        let notices = ClassifierReadResolver.taxTriageRecordedBAMNotices(
            bamsBySample: ["S1": fitted, "S2": own], resultPath: root
        )
        XCTAssertEqual(Set(notices.keys), ["S1"])
        XCTAssertEqual(notices["S1"], Self.olderBuildNotice(sample: "S1", file: "S1_2.bam", folder: root.path))
    }

    // MARK: - Fix 2

    /// A marked fit is named in the words of `taxTriageScanNotice`, the words Extract Reads says, by either form of the
    /// result path. A key that marks nobody is a key, so a file the build did not fit has no notice. This is the database
    /// that a rebuild with the own BAM still missing makes (PREP.md:36, :47).
    func testAMarkedFitIsNamedInTheWordsOfTheScanNotice() throws {
        let variants: [(label: String, fitted: [String])] = [("the key marks S1", ["S1"]), ("the key marks nobody", [])]
        for variant in variants {
            let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
            defer { TestTempDirectory.cleanup(root) }
            let bam = try placeBAM("minimap2/S1_2.bam", in: root)
            var metadata = Self.olderBuild
            metadata[TaxTriageDatabase.fittedBAMSamplesMetadataKey] =
                TaxTriageDatabase.fittedBAMSamplesMetadataValue(variant.fitted)
            let database = try makeResult(recording: ["S1": "minimap2/S1_2.bam"], metadata: metadata, in: root)
            for resultPath in [root, database] {
                let label = "\(variant.label), by \(resultPath.lastPathComponent)"
                let notice = ClassifierReadResolver.taxTriageRecordedBAMNotice(
                    sampleId: "S1", resultPath: resultPath, bam: bam
                )
                if variant.fitted.isEmpty {
                    XCTAssertNil(notice, label)
                } else {
                    XCTAssertEqual(notice, Self.markedNotice, label)
                    XCTAssertEqual(
                        notice,
                        ClassifierReadResolver.taxTriageScanNotice(
                            tool: .taxtriage, sampleId: "S1", resultPath: resultPath, bam: bam
                        ),
                        "\(label): one source of words"
                    )
                }
            }
        }
    }

    // MARK: - Fix 3.2 of FIX-T2-VIEW-BIO

    /// The TaxTriage view and BLAST Verify pass the result FOLDER, where Extract passes the database, and a folder URL that
    /// carries no trailing slash is still the folder. The layer tells the folder from the database by the disk and not by the
    /// slash in the URL's text, so no form of the URL switches the words off. Red at the head of the first round, where a
    /// folder with no slash is taken for a database file, its PARENT folder is searched for `taxtriage.sqlite` and no
    /// notice comes back.
    func testAFolderUrlWithNoTrailingSlashIsStillTheFolder() throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageBAMNotice")
        defer { TestTempDirectory.cleanup(root) }
        let foreign = try placeBAM("minimap2/S1_2.bam", in: root)
        _ = try placeBAM("minimap2/S1_2.S1_2.dwnld.references.bam", in: root)
        let bare = URL(fileURLWithPath: root.path, isDirectory: false)
        XCTAssertFalse(bare.hasDirectoryPath, "the test needs a folder URL that ends with no slash")

        let recorded = ["S1": "minimap2/S1_2.bam", "S1_2": "minimap2/S1_2.S1_2.dwnld.references.bam"]
        _ = try makeResult(recording: recorded, metadata: Self.olderBuild, in: root)
        XCTAssertEqual(
            ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: bare, bam: foreign),
            Self.olderBuildNotice(sample: "S1", file: "S1_2.bam", folder: root.path), "a database with no key"
        )

        var marked = Self.olderBuild
        marked[TaxTriageDatabase.fittedBAMSamplesMetadataKey] = TaxTriageDatabase.fittedBAMSamplesMetadataValue(["S1"])
        _ = try makeResult(recording: recorded, metadata: marked, in: root)
        XCTAssertEqual(
            ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: bare, bam: foreign),
            Self.markedNotice, "a marked fit"
        )
    }

    // MARK: - Helpers

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
        try? FileManager.default.removeItem(at: url)
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
