// TaxTriageWizardInputSamplesTests.swift - The TaxTriage dialog makes one sample of each FASTQ bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TT-PAIR, S1 row TAXTRIAGE-BUNDLE-NAMES-PAIRED (BIO verdict PRODUCT-4, items 3, 4 and 7). The dialog
// stripped `_1`, `_2`, `_R1` or `_R2` from each input's name and joined two bundles that then shared a name
// as the mates of one sample, so `Swab_1` and `Swab_2` from two specimens ran as one sample `Swab`.

import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class TaxTriageWizardInputSamplesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageWizardInputSamplesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bundle(_ name: String, role: SampleRole? = nil) throws -> URL {
        let bundle = root.appendingPathComponent("Imports/\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
        if let role {
            try FASTQBundleCSVMetadata.save(
                FASTQBundleCSVMetadata(keyValuePairs: ["sample_name": name, "sample_role": role.rawValue]),
                to: bundle
            )
        }
        return bundle
    }

    private func looseFile(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent("Loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// The coordinator's Swab test: two bundles of two specimens are two samples, each its own bundle as R1.
    func testTwoSwabBundlesAreTwoSamplesOfOneBundleEach() throws {
        let bundles = try ["Swab_1", "Swab_2"].map { try bundle($0) }
        let samples = TaxTriageWizardSheet.inputSamples(from: bundles)
        XCTAssertEqual(samples.map(\.sampleId), ["Swab_1", "Swab_2"])
        XCTAssertEqual(samples.map(\.fastq1), bundles)
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil])
    }

    func testBundlesInReverseOrderGiveTheSameTwoSamples() throws {
        let s1 = try bundle("S_1")
        let s2 = try bundle("S_2")
        let samples = TaxTriageWizardSheet.inputSamples(from: [s2, s1])
        XCTAssertEqual(samples, TaxTriageWizardSheet.inputSamples(from: [s1, s2]))
        XCTAssertEqual(samples.map(\.sampleId), ["S_1", "S_2"])
        XCTAssertEqual(samples.map(\.fastq1), [s1, s2])
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil])
    }

    /// Verdict case (c): with whole-stem names the dialog names each sample as `taxtriage run` names it, so the
    /// route's `refuseRenamedSamples` passes and the words of that refusal stay as they are.
    func testBundlesSAndTPassTheRoutesRenameCheck() throws {
        let bundles = try ["S_1", "T_1"].map { try bundle($0) }
        let samples = TaxTriageParityCase.wizardSamples(for: bundles)
        XCTAssertEqual(samples.map(\.sampleId), ["S_1", "T_1"])
        let config = TaxTriageConfig(
            samples: samples,
            platform: .illumina,
            outputDirectory: root.appendingPathComponent("Unused/taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2
        )
        let launch = try XCTUnwrap(try ClassifierCLIRouteLaunch.taxTriage(config: config, projectURL: root))
        XCTAssertEqual(launch.sampleIDs, ["S_1", "T_1"])
        XCTAssertEqual(launch.title, "TaxTriage (2 samples)")
    }

    /// The coordinator's three-bundle test: the third bundle of a stem no longer leaves the launch.
    func testThreeBundlesOfOneStemAreThreeSamples() throws {
        let bundles = try ["X", "X_1", "X_2"].map { try bundle($0) }
        let samples = TaxTriageWizardSheet.inputSamples(from: bundles)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.map(\.sampleId), ["X", "X_1", "X_2"])
        XCTAssertEqual(samples.map(\.fastq1), bundles)
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil, nil])
    }

    /// BIO 5: a dot in a bundle's name stays in its Sample ID.
    func testBundleNameWithADotKeepsItsWholeStem() throws {
        let samples = TaxTriageWizardSheet.inputSamples(from: [try bundle("Pt.7"), try bundle("2024.11.05_swab1")])
        XCTAssertEqual(samples.map(\.sampleId), ["2024.11.05_swab1", "Pt.7"])
    }

    /// Guard, green before the fix too: two loose files named as mates stay one paired sample.
    func testLooseMateFilesMakeOnePairedSample() throws {
        let r1 = try looseFile("X_R1.fastq.gz")
        let r2 = try looseFile("X_R2.fastq.gz")
        let samples = TaxTriageWizardSheet.inputSamples(from: [r1, r2])
        XCTAssertEqual(samples.map(\.sampleId), ["X"])
        XCTAssertEqual(samples.map(\.fastq1), [r1])
        XCTAssertEqual(samples.map(\.fastq2), [r2])
    }

    /// Mates come from their names through `MatePairFileNaming`, not from the order of the inputs.
    func testLooseMateFilesInReverseOrderKeepR1First() throws {
        let r1 = try looseFile("X_R1.fastq.gz")
        let r2 = try looseFile("X_R2.fastq.gz")
        let samples = TaxTriageWizardSheet.inputSamples(from: [r2, r1])
        XCTAssertEqual(samples.map(\.fastq1), [r1])
        XCTAssertEqual(samples.map(\.fastq2), [r2])
    }

    /// Rule 3 for loose files: a third file of one stem leaves all three unpaired, and none is left out.
    func testThreeLooseFilesOfOneStemAreThreeSamples() throws {
        let r1 = try looseFile("X_R1.fastq.gz")
        let r2 = try looseFile("X_R2.fastq.gz")
        let one = try looseFile("X_1.fastq.gz")
        let samples = TaxTriageWizardSheet.inputSamples(from: [r1, r2, one])
        XCTAssertEqual(samples.map(\.sampleId), ["X_1", "X_R1", "X_R2"])
        XCTAssertEqual(samples.map(\.fastq1), [one, r1, r2])
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil, nil])
    }

    /// Bundles and loose mates in one list: the bundles stay two samples, the loose pair is one, R1 first.
    func testBundlesAndLooseMatesTogetherAreThreeSamples() throws {
        let a = try bundle("A_1")
        let b = try bundle("A_2")
        let r1 = try looseFile("L_R1.fastq.gz")
        let r2 = try looseFile("L_R2.fastq.gz")
        let samples = TaxTriageWizardSheet.inputSamples(from: [r2, a, r1, b])
        XCTAssertEqual(samples.map(\.sampleId), ["A_1", "A_2", "L"])
        XCTAssertEqual(samples.map(\.fastq1), [a, b, r1])
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil, r2])
    }

    /// Verdict item 4: each sample's role comes from its own bundle, read from the bundle URL itself.
    func testNegativeControlBundleKeepsItsRoleAsTheSecondOfAWouldBePair() throws {
        let test = try bundle("C_1")
        let control = try bundle("C_2", role: .negativeControl)
        let samples = TaxTriageWizardSheet.inputSamples(from: [test, control])
        XCTAssertEqual(samples.map(\.sampleId), ["C_1", "C_2"])
        XCTAssertEqual(samples.map(\.sampleRole), [.testSample, .negativeControl])
        XCTAssertEqual(TaxTriageParityCase.wizardSamples(for: [test, control]).map(\.isNegativeControl), [false, true])
    }

    /// BIO-TT-PAIR question 1, second CORRECT line: the role is read from the bundle the URL names, so a lone
    /// negative-control bundle stays a negative control.
    func testLoneNegativeControlBundleKeepsItsRole() throws {
        let control = try bundle("NC", role: .negativeControl)
        let samples = TaxTriageWizardSheet.inputSamples(from: [control])
        XCTAssertEqual(samples.map(\.sampleId), ["NC"])
        XCTAssertEqual(samples.map(\.sampleRole), [.negativeControl])
    }

    /// BIO-TT-PAIR question 1, third CORRECT line: one line under a paired row says how the two files were paired.
    func testPairedRowSaysTheTwoFilesWerePairedByTheirNames() throws {
        XCTAssertEqual(
            TaxTriageWizardSheet.pairedByNamesLine(fastq2: try looseFile("X_R2.fastq.gz")),
            "Paired by filename as two reads of one sample. To run them as two samples, import each file separately."
        )
        XCTAssertNil(TaxTriageWizardSheet.pairedByNamesLine(fastq2: nil))
    }

    /// BIO-TT-PAIR question 1, fourth CORRECT line: bundles named like the two reads of one sample get one line
    /// with both names, R1 first, and the way on. Other names get none.
    func testBundlesNamedLikeMatesGetOneLineWithTheWayOn() throws {
        let swab1 = try bundle("Swab_1")
        let swab2 = try bundle("Swab_2")
        XCTAssertEqual(
            TaxTriageWizardSheet.bundleMateNotices([swab2, swab1]),
            ["Swab_1 and Swab_2 run as two samples because each FASTQ bundle is one sample. To run them as two reads of one sample, import both read files together as a pair."]
        )
        let triple = try ["X", "X_1", "X_2"].map { try bundle($0) }
        XCTAssertEqual(TaxTriageWizardSheet.bundleMateNotices(triple).count, 1)
        XCTAssertEqual(TaxTriageWizardSheet.bundleMateNotices(try ["S_1", "T_1"].map { try bundle($0) }), [])
        XCTAssertEqual(TaxTriageWizardSheet.bundleMateNotices([try looseFile("L_R1.fastq.gz"), try looseFile("L_R2.fastq.gz")]), [])
    }

    /// The parity replay builds its samples through the dialog's own grouping, so it sees what the dialog makes.
    func testParityReplayDrivesTheDialogsGrouping() throws {
        let bundles = try ["S_1", "S_2"].map { try bundle($0) }
        let samples = TaxTriageParityCase.wizardSamples(for: bundles)
        XCTAssertEqual(samples.map(\.sampleId), ["S_1", "S_2"])
        XCTAssertEqual(samples.map(\.fastq1), bundles)
        XCTAssertEqual(samples.map(\.fastq2), [nil, nil])
    }

    /// The words: a paired row labels each of its two files R1 or R2 (`TT-PAIR-words.md`).
    func testPairedRowLabelsEachFileAsR1OrR2() throws {
        let r1 = try looseFile("X_R1.fastq.gz")
        let r2 = try looseFile("X_R2.fastq.gz")
        XCTAssertEqual(TaxTriageWizardSheet.sampleFileLines(fastq1: r1, fastq2: r2), ["R1 · X_R1.fastq.gz", "R2 · X_R2.fastq.gz"])
        XCTAssertEqual(TaxTriageWizardSheet.sampleFileLines(fastq1: try bundle("Swab_1"), fastq2: nil), ["Swab_1.lungfishfastq"])
        XCTAssertEqual(TaxTriageWizardSheet.sampleFileLines(fastq1: nil, fastq2: nil), ["No R1 file"])
    }
}
