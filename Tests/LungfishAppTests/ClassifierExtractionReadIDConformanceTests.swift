// ClassifierExtractionReadIDConformanceTests.swift - Each classifier's extracted read IDs, frozen on today's engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.11 M1, freeze first (QA 1, X12, BIO 1 and 5, REVIEW.md:172). Before the taxa
// collection leaves `TaxonomyExtractionPipeline.extractBatch` and `conda extract` retires, one fixture
// selection of each of the five `ClassifierTool` cases goes through `ClassifierReadResolver`, and the
// Kraken2 collection goes through `extractBatch`, the old engine the freeze was captured on. Since lane
// 12.11 M3 the leaf runs the collection through `ClassifierReadResolver.extractCollection`. What each
// writes is frozen as text: the read names in
// file order, their count, the unique count, how many fragments are pairs or single reads, and how many
// mates sit next to each other. A later engine must give the same text.
//
// The four BAM-backed tools read the sarscov2 fixture BAM laid out as each tool's result folder names it.
// Kraken2 reads the single-end and paired results of `TaxaCollectionFixtures`.
//
// The test process cannot switch `Locale.current` without writing preferences, so the locale case
// names three samples whose English and Swedish collations differ from the order the person selected
// them in, and pins that the app's and the command's grouping and the extracted reads follow the
// selection, never a collation (BIO 5).
//
// It runs the managed samtools and seqkit, so its name holds Conformance and it skips without them
// unless `LUNGFISH_REQUIRE_TOOLS=1`.

import CryptoKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ClassifierExtractionReadIDConformanceTests: XCTestCase {
    private var root: URL!

    /// The one reference of the sarscov2 fixture BAM.
    private static let reference = "MT192765.1"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-read-id-pin")
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    // MARK: - The five tools

    func testEachBAMClassifierExtractsTheFrozenReadsOfItsSelection() async throws {
        try await requireTool(.samtools)
        var lines: [String] = []
        for tool in [ClassifierTool.esviritu, .taxtriage, .naomgs, .nvd] {
            let result = try makeBAMResult(tool: tool, samples: ["s2"])
            let selection = [ClassifierRowSelector(sampleId: "s2", accessions: [Self.reference], taxIds: [])]
            let (url, count) = try await extract(tool, result: result, selection, name: tool.rawValue)
            lines.append("\(tool.rawValue) readCount=\(count) \(try Self.summary(of: url))")
        }
        XCTAssertEqual(lines.joined(separator: "\n"), Self.frozenBAM, "BAM tools\n" + lines.joined(separator: "\n"))
    }

    func testKraken2ExtractsTheFrozenReadsOfItsSelection() async throws {
        try await requireTool(.seqkit)
        let fixtures = try TaxaCollectionFixtures(in: root.appendingPathComponent("kraken2", isDirectory: true))
        let cases: [(String, URL, Int)] = [
            ("single taxon 10", fixtures.singleEnd, TaxaCollectionFixtures.genus),
            ("single taxon 20", fixtures.singleEnd, TaxaCollectionFixtures.speciesB),
            ("paired taxon 10", fixtures.paired, TaxaCollectionFixtures.genus),
            ("paired taxon 20", fixtures.paired, TaxaCollectionFixtures.speciesB),
        ]
        var lines: [String] = []
        for (label, result, taxon) in cases {
            let selection = [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [taxon])]
            let (url, count) = try await extract(.kraken2, result: result, selection, name: label.replacingOccurrences(of: " ", with: "-"))
            lines.append("kraken2 \(label) readCount=\(count) \(try Self.summary(of: url))")
        }
        XCTAssertEqual(lines.joined(separator: "\n"), Self.frozenKraken2, "Kraken2\n" + lines.joined(separator: "\n"))
    }

    func testTheKraken2CollectionThroughTheLeafWritesTheFrozenReads() async throws {
        try await requireTool(.seqkit)
        let fixtures = try TaxaCollectionFixtures(in: root.appendingPathComponent("collection", isDirectory: true))
        var lines: [String] = []
        for (label, resultFolder) in [("single", fixtures.singleEnd), ("paired", fixtures.paired)] {
            let outputs = try await extractCollection(
                TaxaCollectionFixtures.collection, from: resultFolder,
                into: root.appendingPathComponent("batch-\(label)", isDirectory: true)
            )
            for output in outputs {
                lines.append("collection \(label) \(output.lastPathComponent) \(try Self.summary(of: output))")
            }
        }
        XCTAssertEqual(lines.joined(separator: "\n"), Self.frozenCollection, "collection\n" + lines.joined(separator: "\n"))
    }

    /// BIO's ruling on lane 12.11, Q2. A target marked exact takes only the reads classified to the taxon
    /// itself, and one with children the whole clade. Genus A exact has no reads of its own in the
    /// single-end and paired results, so it is skipped there, and the third result's own read g1 is all
    /// it gives. The fourth result is paired, and its exact line holds only the genus's own pair, mates
    /// together (the review's fix 6). Frozen on `extractBatch` before the collection moves onto the resolver.
    func testTheKraken2CollectionWithExactTargetsWritesTheFrozenReads() async throws {
        try await requireTool(.seqkit)
        let fixtures = try TaxaCollectionFixtures(in: root.appendingPathComponent("exact", isDirectory: true))
        let own = try fixtures.writeGenusWithOwnRead()
        let ownPaired = try fixtures.writePairedGenusWithOwnPair()
        let runs: [(String, URL, TaxaCollection)] = [
            ("single", fixtures.singleEnd, TaxaCollectionFixtures.skippingCollection),
            ("paired", fixtures.paired, TaxaCollectionFixtures.skippingCollection),
            ("own exact", own, TaxaCollectionFixtures.genusOnly(includeChildren: false)),
            ("own children", own, TaxaCollectionFixtures.genusOnly(includeChildren: true)),
            ("paired own exact", ownPaired, TaxaCollectionFixtures.genusOnly(includeChildren: false)),
            ("paired own children", ownPaired, TaxaCollectionFixtures.genusOnly(includeChildren: true)),
        ]
        var lines: [String] = []
        for (label, folder, collection) in runs {
            let output = root.appendingPathComponent("exact-\(label.replacingOccurrences(of: " ", with: "-"))", isDirectory: true)
            for file in try await extractCollection(collection, from: folder, into: output) {
                lines.append("collection \(label) \(file.lastPathComponent) \(try Self.summary(of: file))")
            }
        }
        XCTAssertEqual(lines.joined(separator: "\n"), Self.frozenExactCollection, "exact collection\n" + lines.joined(separator: "\n"))
    }

    /// The collection engine both collection tests run. It was `extractBatch` when the text was frozen.
    /// Since lane 12.11 M3 it is `extract taxa-collection`, in process on the argv the viewer's Extract
    /// button hands it, which runs each taxon through the resolver, and the frozen text stays (X12).
    private func extractCollection(_ collection: TaxaCollection, from folder: URL, into output: URL) async throws -> [URL] {
        let arguments = await ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection, resultDirectory: folder, outputDirectory: output
        )
        let command = try ExtractTaxaCollectionSubcommand.parse(Array(arguments.dropFirst(2)))
        let outcome = try await command.extract(events: CLIEventEmitter(enabled: false, emit: { _ in }))
        return outcome.outputs.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Sample grouping under a collation that is not English (BIO 5)

    func testSampleGroupingFollowsTheSelectionAndNoCollation() async throws {
        try await requireTool(.samtools)
        let samples = ["zeta", "\u{00D6}rebro", "\u{0130}zmir"]
        let regions = ["\(Self.reference):1-10000", "\(Self.reference):10001-20000", "\(Self.reference):20001-29829"]
        for identifier in ["en_US", "sv_SE", "tr_TR"] {
            let collated = samples.sorted { $0.compare($1, locale: Locale(identifier: identifier)) == .orderedAscending }
            XCTAssertNotEqual(collated, samples, "the selection order is not the \(identifier) collation, so a collation would show")
        }
        let selection = zip(samples, regions).map { ClassifierRowSelector(sampleId: $0, accessions: [$1], taxIds: []) }

        let grouped = await ClassifierReadResolver().groupBySample(selection)
        XCTAssertEqual(grouped.map(\.0), samples, "the resolver groups in selection order")
        let argv = ["--by-classifier", "--tool", "nvd", "--result", "/tmp/r.sqlite"]
            + zip(samples, regions).flatMap { ["--sample", $0, "--accession", $1] } + ["-o", "/tmp/o.fastq"]
        let command = try ExtractReadsSubcommand.parse(argv)
        XCTAssertEqual(command.buildClassifierSelectors(rawArgs: argv).map(\.sampleId), samples, "the command groups in argv order")

        let result = try makeBAMResult(tool: .nvd, samples: samples)
        let (whole, count) = try await extract(.nvd, result: result, selection, name: "whole")
        var joined: [String] = []
        for (index, selector) in selection.enumerated() {
            joined += try Self.recordNames(in: try await extract(.nvd, result: result, [selector], name: "sample-\(index)").url)
        }
        XCTAssertEqual(try Self.recordNames(in: whole), joined, "the whole selection is each sample's reads in selection order")
        let line = "nvd three samples readCount=\(count) \(try Self.summary(of: whole))"
        XCTAssertEqual(line, Self.frozenLocale, "locale\n" + line)
    }

    // MARK: - Frozen text

    /// The fixture BAM holds 197 mapped records of 100 fragments. Both mates keep one name, so the
    /// unique names are the fragments, and the file is in BAM order, mates apart.
    static let frozenBAM = """
        esviritu readCount=197 records=197 unique=100 fragments=100 pairs=97 singles=3 adjacentMates=5 suffixed=0 first=ERR5069949.114870 last=ERR5069949.3338256 order=c0afbdab62dfa421 sorted=d7d82c7b130732f2
        taxtriage readCount=197 records=197 unique=100 fragments=100 pairs=97 singles=3 adjacentMates=5 suffixed=0 first=ERR5069949.114870 last=ERR5069949.3338256 order=c0afbdab62dfa421 sorted=d7d82c7b130732f2
        naomgs readCount=197 records=197 unique=100 fragments=100 pairs=97 singles=3 adjacentMates=5 suffixed=0 first=ERR5069949.114870 last=ERR5069949.3338256 order=c0afbdab62dfa421 sorted=d7d82c7b130732f2
        nvd readCount=197 records=197 unique=100 fragments=100 pairs=97 singles=3 adjacentMates=5 suffixed=0 first=ERR5069949.114870 last=ERR5069949.3338256 order=c0afbdab62dfa421 sorted=d7d82c7b130732f2
        """

    static let frozenKraken2 = """
        kraken2 single taxon 10 readCount=3 records=3 unique=3 fragments=3 pairs=0 singles=3 adjacentMates=0 suffixed=0 names=a1,a2,a3
        kraken2 single taxon 20 readCount=2 records=2 unique=2 fragments=2 pairs=0 singles=2 adjacentMates=0 suffixed=0 names=b1,b2
        kraken2 paired taxon 10 readCount=4 records=4 unique=4 fragments=2 pairs=2 singles=0 adjacentMates=2 suffixed=4 names=p1/1,p1/2,p3/1,p3/2
        kraken2 paired taxon 20 readCount=2 records=2 unique=2 fragments=1 pairs=1 singles=0 adjacentMates=1 suffixed=2 names=p2/1,p2/2
        """

    static let frozenCollection = """
        collection single Genus_A_taxid10.fastq.gz records=3 unique=3 fragments=3 pairs=0 singles=3 adjacentMates=0 suffixed=0 names=a1,a2,a3
        collection single Species_B_taxid20.fastq.gz records=2 unique=2 fragments=2 pairs=0 singles=2 adjacentMates=0 suffixed=0 names=b1,b2
        collection paired Genus_A_taxid10.fastq.gz records=4 unique=4 fragments=2 pairs=2 singles=0 adjacentMates=2 suffixed=4 names=p1/1,p1/2,p3/1,p3/2
        collection paired Species_B_taxid20.fastq.gz records=2 unique=2 fragments=1 pairs=1 singles=0 adjacentMates=1 suffixed=2 names=p2/1,p2/2
        """

    /// Captured on `extractBatch` at fd7d8ee06 (lane 12.11 M3, BIO's ruling Q2), the two paired own
    /// lines at 2d5f630c9 (the review's fix 6).
    static let frozenExactCollection = """
        collection single Species_B_taxid20.fastq.gz records=2 unique=2 fragments=2 pairs=0 singles=2 adjacentMates=0 suffixed=0 names=b1,b2
        collection paired Species_B_taxid20.fastq.gz records=2 unique=2 fragments=1 pairs=1 singles=0 adjacentMates=1 suffixed=2 names=p2/1,p2/2
        collection own exact Genus_A_taxid10.fastq.gz records=1 unique=1 fragments=1 pairs=0 singles=1 adjacentMates=0 suffixed=0 names=g1
        collection own children Genus_A_taxid10.fastq.gz records=4 unique=4 fragments=4 pairs=0 singles=4 adjacentMates=0 suffixed=0 names=a1,a2,a3,g1
        collection paired own exact Genus_A_taxid10.fastq.gz records=2 unique=2 fragments=1 pairs=1 singles=0 adjacentMates=1 suffixed=2 names=g1/1,g1/2
        collection paired own children Genus_A_taxid10.fastq.gz records=6 unique=6 fragments=3 pairs=3 singles=0 adjacentMates=3 suffixed=6 names=p1/1,p1/2,g1/1,g1/2,p3/1,p3/2
        """

    /// The same reads as one sample, in another order, the three samples' regions one after another.
    static let frozenLocale = """
        nvd three samples readCount=197 records=197 unique=100 fragments=100 pairs=97 singles=3 adjacentMates=5 suffixed=0 first=ERR5069949.114870 last=ERR5069949.3338256 order=af98dea2ca8f58d7 sorted=d7d82c7b130732f2
        """

    // MARK: - Helpers

    private func requireTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.findTool(tool)
        } catch {
            try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is required: \(error)", file: file, line: line)
        }
    }

    private func extract(
        _ tool: ClassifierTool, result: URL, _ selection: [ClassifierRowSelector], name: String
    ) async throws -> (url: URL, count: Int) {
        let output = root.appendingPathComponent("out/\(tool.rawValue)-\(name).fastq")
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: tool,
            resultPath: result,
            selections: selection,
            options: ExtractionOptions(format: .fastq),
            destination: .file(output)
        )
        guard case .file(let url, let count) = outcome else {
            XCTFail("a file destination gave \(outcome)")
            throw CancellationError()
        }
        return (url, count)
    }

    /// A result folder of `tool` in `root` whose BAM for each of `samples` is the sarscov2 fixture BAM,
    /// laid out where the resolver looks for that tool's BAM, and the result path the views pass.
    /// The NAO-MGS BAM also has the header line of a fresh import, since Extract refuses one without it.
    private func makeBAMResult(tool: ClassifierTool, samples: [String]) throws -> URL {
        let fileManager = FileManager.default
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bam = repository.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let index = [URL(fileURLWithPath: bam.path + ".bai"), bam.deletingPathExtension().appendingPathExtension("bam.bai")]
            .first { fileManager.fileExists(atPath: $0.path) }
        guard fileManager.fileExists(atPath: bam.path), let index else {
            throw XCTSkip("the sarscov2 fixture BAM or its index is missing at \(bam.path)")
        }
        let folder = root.appendingPathComponent("Project.lungfish/Analyses/\(tool.rawValue)-\(samples.count)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for sample in samples {
            let relative: String
            switch tool {
            case .nvd: relative = "bam/\(sample).filtered.bam"
            case .esviritu: relative = "\(sample).sorted.bam"
            case .taxtriage: relative = "minimap2/\(sample).bam"
            case .naomgs: relative = "bams/\(sample).sorted.bam"
            case .kraken2: throw XCTSkip("Kraken2 reads no BAM")
            }
            let destination = folder.appendingPathComponent(relative)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: bam, to: destination)
            try fileManager.copyItem(at: index, to: URL(fileURLWithPath: destination.path + ".bai"))
            if tool == .naomgs { try ClassifierExtractionFixtures.markAsMadeAfterTheStrandFix(bam: destination) }
        }
        return folder.appendingPathComponent("fake-result.sqlite")
    }

    /// The record names of a FASTQ file, plain or gzip, in file order, each up to its first space.
    static func recordNames(in url: URL) throws -> [String] {
        try TaxaCollectionFixtures.recordNames(in: url).map { String($0.split(separator: " ").first ?? "") }
    }

    /// One line for the reads of `url`. Small sets list their names, large ones give the first and
    /// last name and digests of the names in file order and sorted.
    static func summary(of url: URL) throws -> String {
        let names = try recordNames(in: url)
        let fragments = names.map { name -> String in
            name.hasSuffix("/1") || name.hasSuffix("/2") ? String(name.dropLast(2)) : name
        }
        var perFragment: [String: Int] = [:]
        for fragment in fragments { perFragment[fragment, default: 0] += 1 }
        let pairs = perFragment.values.filter { $0 == 2 }.count
        let singles = perFragment.values.filter { $0 == 1 }.count
        let adjacent = zip(fragments, fragments.dropFirst()).filter { $0 == $1 }.count
        let suffixed = names.filter { $0.hasSuffix("/1") || $0.hasSuffix("/2") }.count
        var line = "records=\(names.count) unique=\(Set(names).count) fragments=\(perFragment.count)"
            + " pairs=\(pairs) singles=\(singles) adjacentMates=\(adjacent) suffixed=\(suffixed)"
        if names.count <= 12 {
            line += " names=\(names.joined(separator: ","))"
        } else {
            line += " first=\(names.first ?? "") last=\(names.last ?? "")"
                + " order=\(digest(names)) sorted=\(digest(names.sorted()))"
        }
        return line
    }

    private static func digest(_ names: [String]) -> String {
        SHA256.hash(data: Data(names.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
