// TaxTriageRecordedBAMTests.swift - Extract Reads finds the BAM that a TaxTriage database records for a sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTEXTRACT (finding F1 of lane TTACCESSIONS, S2). The TaxTriage viewer sends the result's database as
// the result path, and the resolver looked for `minimap2/` beside it. A batch the app makes keeps each sample's BAM in
// `<sample>/minimap2/`, so Extract Reads said it found no BAM file for every row of every batch. The database records
// each row's BAM path relative to the folder that holds it, so the resolver reads that record first, as the EsViritu,
// NVD and NAO-MGS cases do, and keeps the `minimap2/` lookup for a result that records nothing.

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

final class TaxTriageRecordedBAMTests: XCTestCase {

    private static let ntcPath = "NTC_1/minimap2/NTC_1.NTC_1.dwnld.references.bam"
    private static let patientPath = "patient/minimap2/patient.patient.dwnld.references.bam"

    /// What the viewer does: the database goes in as the result path. Red at the base, which looks for `minimap2/`
    /// beside the database and throws `bamNotFound` for both samples of the batch.
    func testABatchResolvesEachSamplesRecordedBAMFromTheDatabasePath() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let ntc = try placeBAM(Self.ntcPath, in: root)
        let patient = try placeBAM(Self.patientPath, in: root)
        let database = try makeResult(recording: ["NTC_1": Self.ntcPath, "patient": Self.patientPath], in: root)
        for (sample, expected) in [("NTC_1", ntc), ("patient", patient)] {
            let found = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: sample, resultPath: database
            )
            XCTAssertEqual(found.resolvingSymlinksInPath().path, expected.resolvingSymlinksInPath().path, sample)
        }
    }

    /// The result folder goes in as the result path (the command line's form, and the viewer's when it has no
    /// database). Red at the base for the same reason.
    func testABatchGivenAsItsFolderResolvesTheRecordedBAMToo() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let ntc = try placeBAM(Self.ntcPath, in: root)
        _ = try placeBAM(Self.patientPath, in: root)
        _ = try makeResult(recording: ["NTC_1": Self.ntcPath, "patient": Self.patientPath], in: root)
        let found = try await ClassifierReadResolver().testingResolveBAMURL(
            tool: .taxtriage, sampleId: "NTC_1", resultPath: root
        )
        XCTAssertEqual(found.resolvingSymlinksInPath().path, ntc.resolvingSymlinksInPath().path)
    }

    /// The old layout, a one-sample result with `minimap2/` beside its database. It passes at the base and after.
    func testASingleSampleResultKeepsItsMinimap2LayoutBesideTheDatabase() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let recorded = "minimap2/S1.S1.dwnld.references.bam"
        let bam = try placeBAM(recorded, in: root)
        let database = try makeResult(recording: ["S1": recorded], in: root)
        let found = try await ClassifierReadResolver().testingResolveBAMURL(
            tool: .taxtriage, sampleId: "S1", resultPath: database
        )
        XCTAssertEqual(found.resolvingSymlinksInPath().path, bam.resolvingSymlinksInPath().path)
    }

    /// A database that records no BAM for the sample, as an older build left it, falls back to the `minimap2/` lookup.
    func testADatabaseThatRecordsNoBAMFallsBackToTheMinimap2Lookup() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let bam = try placeBAM("minimap2/S1.bam", in: root)
        let database = try makeResult(recording: ["S1": nil], in: root)
        for resultPath in [database, root] {
            let found = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "S1", resultPath: resultPath
            )
            XCTAssertEqual(found.resolvingSymlinksInPath().path, bam.resolvingSymlinksInPath().path, resultPath.lastPathComponent)
        }
    }

    /// A recorded path that leaves the result is never read (decision C4), whichever way it leaves. Red at the base,
    /// which never reads the record and says `bamNotFound`.
    func testARecordedPathThatLeavesTheResultIsRefused() async throws {
        let base = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(base) }
        let root = base.appendingPathComponent("result", isDirectory: true)
        let elsewhere = try placeBAM("outside/elsewhere.bam", in: base)
        let database = try makeResult(
            recording: ["ABSOLUTE": elsewhere.path, "DOTS": "../outside/elsewhere.bam"], in: root
        )
        for sample in ["ABSOLUTE", "DOTS"] {
            do {
                _ = try await ClassifierReadResolver().testingResolveBAMURL(
                    tool: .taxtriage, sampleId: sample, resultPath: database
                )
                XCTFail("\(sample): a BAM outside the result is not read")
            } catch let error as ClassifierExtractionError {
                guard case .bamOutsideResult(let named) = error else { return XCTFail("\(sample): \(error)") }
                XCTAssertEqual(named, sample)
            }
        }
    }

    /// A recorded BAM that is not on disk stays the missing-BAM refusal, with the sample's name.
    func testARecordedBAMThatIsNotOnDiskIsTheMissingBAMRefusal() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let database = try makeResult(recording: ["GONE": "GONE/minimap2/GONE.GONE.dwnld.references.bam"], in: root)
        do {
            _ = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "GONE", resultPath: database
            )
            XCTFail("a recorded BAM that is not on disk is not found")
        } catch let error as ClassifierExtractionError {
            guard case .bamNotFound(let named) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(named, "GONE")
        }
    }

    /// A recorded BAM that is gone is the missing-BAM refusal, even when another sample's BAM, whose name starts with
    /// this sample's id, sits in the same `minimap2/`. Red at the head, whose prefix scan returns NTC_10's file.
    func testARecordedBAMThatIsGoneIsNotReplacedByASiblingSamplesBAM() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriageRecordedBAM")
        defer { TestTempDirectory.cleanup(root) }
        let ntc10 = "minimap2/NTC_10.NTC_10.dwnld.references.bam"
        let bam10 = try placeBAM(ntc10, in: root)
        let database = try makeResult(
            recording: ["NTC_1": "minimap2/NTC_1.NTC_1.dwnld.references.bam", "NTC_10": ntc10], in: root
        )
        let own = try await ClassifierReadResolver().testingResolveBAMURL(
            tool: .taxtriage, sampleId: "NTC_10", resultPath: database
        )
        XCTAssertEqual(own.resolvingSymlinksInPath().path, bam10.resolvingSymlinksInPath().path, "NTC_10 keeps its own BAM")
        do {
            _ = try await ClassifierReadResolver().testingResolveBAMURL(
                tool: .taxtriage, sampleId: "NTC_1", resultPath: database
            )
            XCTFail("NTC_1's BAM is gone, so NTC_10's BAM is not read for it")
        } catch let error as ClassifierExtractionError {
            guard case .bamNotFound(let named) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(named, "NTC_1")
        }
    }

    // MARK: - The scan of minimap2/ when nothing is recorded (Phase 3.4 lane EXTRACT, EXTRACT-PREFIX-SCAN-NO-DATABASE)

    /// On a raw nf-core folder a sample takes its own file and no other sample's. Red at the base, whose scan takes
    /// the first file, in listing order, whose name starts with `S1`. APFS lists by name hash, so the underscore
    /// folder lists S10's file first, and the last folder, which holds only S10's file, gives S1 that file.
    func testTaxTriagePrefixScanTakesOnlyTheSamplesOwnBAM() async throws {
        let folders: [(files: [String], s1: String?)] = [
            (["S1.dedup.bam", "S10.dedup.bam"], "S1.dedup.bam"),
            (["S1_dedup.bam", "S10_dedup.bam"], "S1_dedup.bam"),
            (["S1-dedup.bam", "S10-dedup.bam"], "S1-dedup.bam"),
            (["S10.dedup.bam"], nil),
        ]
        for folder in folders {
            let root = try TestTempDirectory.make(prefix: "TaxTriagePrefixScan")
            defer { TestTempDirectory.cleanup(root) }
            for file in folder.files { _ = try placeBAM("minimap2/\(file)", in: root) }
            let label = folder.files.joined(separator: " + ")
            if let own = folder.s1 {
                let found = try await resolveTaxTriageBAM("S1", in: root)
                XCTAssertEqual(found.lastPathComponent, own, label)
            } else {
                await assertMissingBAMRefusal("S1", in: root, label)
            }
            let s10 = try await resolveTaxTriageBAM("S10", in: root)
            XCTAssertEqual(s10.lastPathComponent, folder.files.first { $0.hasPrefix("S10") }, label)
        }
    }

    /// Two files that fit one sample are a refusal in words that name both, and no file is read. Red at the base,
    /// which returns the first of them. S10's file beside them is not named and S10 still gets it.
    func testTaxTriagePrefixScanRefusesTwoFilesThatFitOneSample() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriagePrefixScan")
        defer { TestTempDirectory.cleanup(root) }
        for file in ["S1.raw.bam", "S1.dedup.bam", "S10.dedup.bam"] { _ = try placeBAM("minimap2/\(file)", in: root) }
        do {
            let found = try await resolveTaxTriageBAM("S1", in: root)
            XCTFail("two BAM files fit S1, so none is read, but \(found.lastPathComponent) was")
        } catch let error as ClassifierExtractionError {
            let words = error.errorDescription ?? ""
            XCTAssertTrue(
                words.hasPrefix("More than one BAM file fits sample 'S1' in minimap2: S1.dedup.bam, S1.raw.bam."), words
            )
            XCTAssertTrue(
                words.hasSuffix("LGE takes a sample's reads from one BAM. Keep only that sample's file in minimap2 and try again."),
                words
            )
            XCTAssertFalse(words.contains("S10"), "S10's file does not fit S1")
            XCTAssertTrue(error.blocksExtraction, "the Extract sheet shows these words and turns Extract off")
        }
        let s10 = try await resolveTaxTriageBAM("S10", in: root)
        XCTAssertEqual(s10.lastPathComponent, "S10.dedup.bam")
    }

    /// The nf-core name `{X}.{X}.dwnld.references.bam` belongs to sample X alone. With only `S1.1`'s file in
    /// `minimap2/`, S1 gets the missing-BAM refusal and S1.1 gets the file. Red at the base, which gives S1 that file.
    func testTaxTriagePrefixScanLeavesADottedSiblingsBAMAlone() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriagePrefixScan")
        defer { TestTempDirectory.cleanup(root) }
        _ = try placeBAM("minimap2/S1.1.S1.1.dwnld.references.bam", in: root)
        await assertMissingBAMRefusal("S1", in: root, "S1 beside S1.1")
        let dotted = try await resolveTaxTriageBAM("S1.1", in: root)
        XCTAssertEqual(dotted.lastPathComponent, "S1.1.S1.1.dwnld.references.bam")
    }

    /// When the sample's nf-core file is there, no scan runs, so a sibling whose name shares the boundary neither
    /// replaces it nor makes two fits. Red at the base, which never tries that name and takes the first listed file
    /// (APFS lists `S1.x.bam` before it).
    func testTaxTriageCurrentLayoutNameWinsOverASiblingThatSharesTheBoundary() async throws {
        let root = try TestTempDirectory.make(prefix: "TaxTriagePrefixScan")
        defer { TestTempDirectory.cleanup(root) }
        for file in ["S1.S1.dwnld.references.bam", "S1.x.bam", "S1.final.bam"] { _ = try placeBAM("minimap2/\(file)", in: root) }
        let found = try await resolveTaxTriageBAM("S1", in: root)
        XCTAssertEqual(found.lastPathComponent, "S1.S1.dwnld.references.bam")
    }

    // MARK: - Helpers

    /// What the command line does: the result folder goes in as the result path, with no database in it.
    private func resolveTaxTriageBAM(_ sample: String, in root: URL) async throws -> URL {
        try await ClassifierReadResolver().testingResolveBAMURL(tool: .taxtriage, sampleId: sample, resultPath: root)
    }

    /// Asserts that `sample` gets the missing-BAM refusal with its own name, and that no file is read.
    private func assertMissingBAMRefusal(_ sample: String, in root: URL, _ label: String) async {
        do {
            let found = try await resolveTaxTriageBAM(sample, in: root)
            XCTFail("\(label): \(sample) has no BAM of its own, so none is read, but \(found.lastPathComponent) was")
        } catch let error as ClassifierExtractionError {
            guard case .bamNotFound(let named) = error else { return XCTFail("\(label): \(error)") }
            XCTAssertEqual(named, sample, label)
        } catch {
            XCTFail("\(label): \(error)")
        }
    }

    /// Writes a placeholder BAM at `relative` under `root`, with the BGZF magic the other layout tests write.
    private func placeBAM(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1F, 0x8B]).write(to: url)
        return url
    }

    /// Writes `taxtriage.sqlite` in `root`, with one row for each sample and the BAM path that row stores.
    private func makeResult(recording recorded: [String: String?], in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rows = recorded.sorted { $0.key < $1.key }.map { Self.row(sample: $0.key, bamPath: $0.value) }
        let url = root.appendingPathComponent("taxtriage.sqlite")
        try TaxTriageDatabase.create(at: url, rows: rows, metadata: ["tool": "TaxTriage"])
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
