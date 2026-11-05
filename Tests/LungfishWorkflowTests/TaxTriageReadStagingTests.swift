// TaxTriageReadStagingTests.swift - The file names LGE hands the TaxTriage samplesheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane W1FIX, walk row W-1. A sample named `Water (blank)` failed at COUNT_READS and the same reads named
// `Water` ran to the end. LGE staged the reads as `Water_(blank).fastq.gz`, Nextflow writes that name into the task
// script as `Water_\(blank\).fastq.gz`, and the pipeline's step puts it in double quotes, so `[[ -s "$f" ]]` looks for a
// file whose name holds backslashes and exits 1. LGE now stages every read file whose name is not plain under a name of
// letters, digits, `_`, `-` and `.`, and the sample keeps the name the person gave it.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageReadStagingTests: XCTestCase {
    private var root: URL!

    /// The only characters a staged read file name may hold.
    private let safeScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-."
    )

    /// Sample names that a person types and a shell reads as more than a name.
    private static let awkwardNames = [
        "Water (blank)", "Run [1]", "it's", "A&B", "50% pure", "x;y", "a$b", "back`tick", "#1 sample",
        "tab\there", "\u{DC}n\u{EF} c\u{F6}d\u{E9}", "semi:colon", "star*", "q?", "pipe|bar", "<angle>",
        "back\\slash", "double\"quote", "{braces}", "tilde~", "bang!", "plus+at@",
    ]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-read-staging").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { safeScalars.contains($0) }
    }

    @discardableResult
    private func makeReads(_ fileName: String, folder: String = "reads", content: String = "ACGT") throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// Runs the staging step the pipeline runs before it writes the samplesheet, and removes the staging folder it
    /// made in the system temporary folder when the test ends.
    private func prepare(_ samples: [TaxTriageSample]) throws -> TaxTriagePipeline.PreparedExecutionConfig {
        let config = TaxTriageConfig(
            samples: samples,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true)
        )
        let prepared = try TaxTriagePipeline().prepareExecutionConfig(for: config)
        for staged in prepared.effectiveConfig.samples.flatMap(\.allFiles) {
            let parent = staged.deletingLastPathComponent()
            guard !parent.path.hasPrefix(root.path) else { continue }
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        }
        return prepared
    }

    private func content(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testASampleNamedWaterBlankStagesItsReadsUnderASafeFileName() throws {
        let reads = try makeReads("Water (blank).fastq.gz", content: "water-blank-reads")

        let prepared = try prepare([
            TaxTriageSample(sampleId: "Water (blank)", fastq1: reads, platform: .illumina, isNegativeControl: true)
        ])

        let staged = prepared.effectiveConfig.samples[0]
        XCTAssertTrue(
            isSafe(staged.fastq1.lastPathComponent),
            "The reads were staged as \(staged.fastq1.lastPathComponent), which Nextflow escapes in the task script"
        )
        XCTAssertTrue(staged.fastq1.lastPathComponent.hasSuffix(".fastq.gz"), "The file keeps its extension")
        XCTAssertEqual(try content(of: staged.fastq1), "water-blank-reads", "The staged name reads the same file")
        XCTAssertEqual(staged.sampleId, "Water (blank)", "The sample keeps the name the person gave it")
        XCTAssertTrue(staged.isNegativeControl, "A control stays a control after its reads are staged")
        XCTAssertTrue(staged.isAnyNegativeControl)
    }

    func testTheSamplesheetKeepsTheSampleNameAndNamesASafeFile() throws {
        let reads = try makeReads("Water (blank).fastq.gz")
        let prepared = try prepare([TaxTriageSample(sampleId: "Water (blank)", fastq1: reads, platform: .illumina)])

        let sheet = root.appendingPathComponent("samplesheet.csv")
        try TaxTriageSamplesheetBuilder().write(prepared.effectiveConfig.samples, to: sheet)
        let rows = try content(of: sheet).split(separator: "\n").map(String.init)

        XCTAssertEqual(rows.count, 2, "A header and one sample")
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"")), "Water (blank)")
        XCTAssertTrue(
            isSafe(URL(fileURLWithPath: fields[1]).lastPathComponent),
            "The sheet names \(fields[1])"
        )
        XCTAssertFalse(fields[1].contains(" "), "The pipeline's schema rejects a space in a read path")
    }

    func testNamesWithShellCharactersStageUnderSafeFileNamesAndKeepTheirSampleNames() throws {
        for (index, name) in Self.awkwardNames.enumerated() {
            let reads = try makeReads("\(name).fastq.gz", folder: "reads-\(index)", content: "reads of \(name)")

            let prepared = try prepare([TaxTriageSample(sampleId: name, fastq1: reads, platform: .illumina)])

            let staged = prepared.effectiveConfig.samples[0]
            XCTAssertTrue(
                isSafe(staged.fastq1.lastPathComponent),
                "\(name) was staged as \(staged.fastq1.lastPathComponent)"
            )
            XCTAssertEqual(try content(of: staged.fastq1), "reads of \(name)", name)
            XCTAssertEqual(staged.sampleId, name)
        }
    }

    func testBothMatesOfAPairStageUnderSafeFileNames() throws {
        let first = try makeReads("Water (blank)_R1.fastq.gz", content: "mate one")
        let second = try makeReads("Water (blank)_R2.fastq.gz", content: "mate two")

        let prepared = try prepare([
            TaxTriageSample(sampleId: "Water (blank)", fastq1: first, fastq2: second, platform: .illumina)
        ])

        let staged = prepared.effectiveConfig.samples[0]
        let stagedSecond = try XCTUnwrap(staged.fastq2)
        XCTAssertTrue(isSafe(staged.fastq1.lastPathComponent), staged.fastq1.lastPathComponent)
        XCTAssertTrue(isSafe(stagedSecond.lastPathComponent), stagedSecond.lastPathComponent)
        XCTAssertEqual(try content(of: staged.fastq1), "mate one")
        XCTAssertEqual(try content(of: stagedSecond), "mate two")
    }

    func testFilesWithTheSameNameInDifferentFoldersStageAsDifferentFiles() throws {
        let first = try makeReads("reads.fastq.gz", folder: "Run 1", content: "run one")
        let second = try makeReads("reads.fastq.gz", folder: "Run 2", content: "run two")

        let prepared = try prepare([
            TaxTriageSample(sampleId: "A", fastq1: first, platform: .illumina),
            TaxTriageSample(sampleId: "B", fastq1: second, platform: .illumina),
        ])

        let staged = prepared.effectiveConfig.samples
        XCTAssertNotEqual(staged[0].fastq1, staged[1].fastq1, "Two samples must not read through one staged name")
        XCTAssertEqual(try content(of: staged[0].fastq1), "run one", "Sample A reads its own file")
        XCTAssertEqual(try content(of: staged[1].fastq1), "run two", "Sample B reads its own file")
    }

    func testNamesThatBecomeTheSameSafeNameStageAsDifferentFiles() throws {
        // The first two become A_1_.fastq.gz, and the third becomes a_1_.fastq.gz, the same name on a volume that
        // ignores case.
        let names = ["A (1).fastq.gz", "A [1].fastq.gz", "a (1].fastq.gz"]
        var samples: [TaxTriageSample] = []
        for name in names {
            let reads = try makeReads(name, content: "reads of \(name)")
            samples.append(TaxTriageSample(sampleId: name, fastq1: reads, platform: .illumina))
        }

        let prepared = try prepare(samples)

        let staged = prepared.effectiveConfig.samples
        let lowercased = Set(staged.map { $0.fastq1.lastPathComponent.lowercased() })
        XCTAssertEqual(lowercased.count, 3, "The staged names differ even where the volume ignores case")
        for (index, name) in names.enumerated() {
            XCTAssertTrue(isSafe(staged[index].fastq1.lastPathComponent), staged[index].fastq1.lastPathComponent)
            XCTAssertEqual(try content(of: staged[index].fastq1), "reads of \(name)", name)
        }
    }

    func testANameThatStartsWithADashOrADotStagesWithoutIt() throws {
        for name in ["-reads.fastq.gz", ".hidden.fastq.gz"] {
            let reads = try makeReads(name, content: "reads of \(name)")

            let prepared = try prepare([TaxTriageSample(sampleId: "S", fastq1: reads, platform: .illumina)])

            let staged = prepared.effectiveConfig.samples[0].fastq1
            XCTAssertTrue(isSafe(staged.lastPathComponent), "\(name) was staged as \(staged.lastPathComponent)")
            XCTAssertEqual(try content(of: staged), "reads of \(name)")
        }
    }

    func testAPlainNameInAPlainFolderStaysWhereItIs() throws {
        let reads = try makeReads("water_blank-1.fastq.gz")

        let prepared = try prepare([TaxTriageSample(sampleId: "Water (blank)", fastq1: reads, platform: .illumina)])

        XCTAssertNil(prepared.redirectDirectory)
        XCTAssertEqual(prepared.effectiveConfig.samples[0].fastq1, reads, "A plain name needs no staging")
    }

    func testOnlyTheReadNamesMoveWhenTheOutputFolderIsPlain() throws {
        let reads = try makeReads("Water(blank).fastq.gz")
        let output = root.appendingPathComponent("out", isDirectory: true)

        let prepared = try prepare([TaxTriageSample(sampleId: "Water (blank)", fastq1: reads, platform: .illumina)])

        XCTAssertEqual(
            prepared.effectiveConfig.outputDirectory, output,
            "Results are written where the person asked, never in a temporary folder"
        )
        XCTAssertNil(prepared.redirectDirectory)
        let staged = prepared.effectiveConfig.samples[0].fastq1
        XCTAssertTrue(isSafe(staged.lastPathComponent))
        XCTAssertEqual(
            prepared.stagingDirectory, staged.deletingLastPathComponent(),
            "The run removes the folder of links when it ends"
        )
    }

    func testSafeFileNameTurnsEachRunOfOtherCharactersIntoOneUnderscore() {
        XCTAssertEqual(TaxTriageReadStaging.safeFileName(for: "Water (blank).fastq.gz"), "Water_blank_.fastq.gz")
        XCTAssertEqual(TaxTriageReadStaging.safeFileName(for: "plain-1_R1.fastq.gz"), "plain-1_R1.fastq.gz")
        XCTAssertEqual(TaxTriageReadStaging.safeFileName(for: "-reads.fq.gz"), "_reads.fq.gz")
        XCTAssertEqual(TaxTriageReadStaging.safeFileName(for: ".hidden.fq"), "_hidden.fq")
        XCTAssertEqual(TaxTriageReadStaging.safeFileName(for: "()"), "_")
    }

    func testUniqueFileNameAddsACounterBeforeTheExtensionAndIgnoresCase() {
        var taken = Set<String>()
        XCTAssertEqual(TaxTriageReadStaging.uniqueFileName("A.fastq.gz", taken: &taken), "A.fastq.gz")
        XCTAssertEqual(TaxTriageReadStaging.uniqueFileName("a.fastq.gz", taken: &taken), "a_2.fastq.gz")
        XCTAssertEqual(TaxTriageReadStaging.uniqueFileName("A.fastq.gz", taken: &taken), "A_3.fastq.gz")
        XCTAssertEqual(TaxTriageReadStaging.uniqueFileName("noextension", taken: &taken), "noextension")
        XCTAssertEqual(TaxTriageReadStaging.uniqueFileName("noextension", taken: &taken), "noextension_2")
    }
}
