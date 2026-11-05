// SmokeFixtureReadTests.swift - The release smoke's hand written fixtures, read back by the app's own loaders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// SMOKE-UX should-fix 2 of Phase 3.2. The view-switch smoke (ReleaseCandidateSmokeXCUITests) writes a FASTQ bundle with
// cached statistics, an MHC amplicon reference bundle with no haplotype definition and a genotype result by hand, and a
// bundle the app cannot read costs a repackage of the candidate, because `swift build` does not compile the XCUI target.
// That target belongs to Lungfish.xcodeproj and has no SwiftPM target, so this class cannot call its helpers.
// SmokeFixtureBytes below writes the same bytes. A change to a fixture of the smoke goes to this file, and the other way.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// The bytes of the smoke's hand written fixtures, as `ReleaseSmokeFixtures` (Tests/LungfishXCUITests) writes them.
enum SmokeFixtureBytes {
    static let fastqRow = "Smoke FASTQ"
    static let mhcRow = "Smoke MHC Reference"
    static let genotypeRow = "Smoke Genotype"
    static let fastaFile = "clusters.fasta"
    static let scriptFile = "main.nf"

    @discardableResult
    static func fastqBundle(in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(fastqRow).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@read1\nACGTACGT\n+\nIIIIIIII\n@read2\nGGCCGGCC\n+\nIIIIIIII\n"
            .write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let statistics: [String: Any] = ["readCount": 2, "baseCount": 16, "meanReadLength": 8.0, "minReadLength": 8,
                                         "maxReadLength": 8, "medianReadLength": 8, "n50ReadLength": 8, "meanQuality": 40.0,
                                         "q20Percentage": 100.0, "q30Percentage": 100.0, "gcContent": 0.75,
                                         "readLengthHistogram": ["8": 2], "qualityScoreHistogram": [40, 16],
                                         "perPositionQuality": [Any]()]
        try JSONSerialization.data(withJSONObject: ["computedStatistics": statistics], options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("reads.fastq.lungfish-meta.json"))
        return bundle
    }

    @discardableResult
    static func mhcReferenceBundle(in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(mhcRow).lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ">Mamu-A1-001 smoke\nACGTACGTACGTACGTACGT\n>Mamu-A1-002 smoke\nACGTACGTACGAACGTACGT\n"
            .write(to: bundle.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "mhc-reference", "name": mhcRow,
                                       "referenceFastaPath": "reference.fa", "haplotypeDefinitionPaths": [String](),
                                       "metrics": ["referenceCount": 2, "haplotypeDefinitionCount": 0],
                                       "createdAt": "2026-11-04T00:00:00Z"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("mhc-reference.json"))
        return bundle
    }

    @discardableResult
    static func genotypeResult(in project: URL) throws -> URL {
        let name = genotypeRow
        let bundle = project.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("workbook".utf8).write(to: bundle.appendingPathComponent("\(name).xlsx"))
        let files = ["\(name).retained-demux-genotypes.csv": "sample,genotype,passed_alignments,passed_unique_reads\nDW472,01_Mafa_A1_063g,10,8\n",
                     "\(name).retained-demux-samples.csv": "sample,passed_alignments,passed_unique_reads\nDW472,10,8\n",
                     "\(name).retained-demux-stats.json": #"{"totalInputReads":10,"retainedUniqueReads":8}"#,
                     "retained-demux-genotyping-provenance.json": #"{"workflow":"safety-net"}"#]
        for (file, text) in files {
            try text.write(to: bundle.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ont-barcode-genotype", "outputName": name, "analysisName": name,
                                       "primaryWorkbookPath": "\(name).xlsx",
                                       "longSummaryCSVPath": "\(name).retained-demux-genotypes.csv",
                                       "sampleSummaryCSVPath": "\(name).retained-demux-samples.csv",
                                       "statsJSONPath": "\(name).retained-demux-stats.json",
                                       "provenancePath": "retained-demux-genotyping-provenance.json"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("genotype-result.json"))
        return bundle
    }

    @discardableResult
    static func fastaCollection(in project: URL) throws -> URL {
        let file = project.appendingPathComponent(fastaFile)
        try ">cluster_1 first\nACGTACGTACGT\n>cluster_2 second\nGGCCGGCC\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    static func scriptPreview(in project: URL) throws -> URL {
        let file = project.appendingPathComponent(scriptFile)
        try "nextflow.enable.dsl = 2\n\nworkflow {\n    println 'HG002'\n}\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static let assemblyFolder = "spades-2026-01-15T13-00-00"

    /// `ReleaseSmokeFixtures.addAssemblyResult`. It copies the SPAdes result of `Tests/Fixtures/analyses` into Analyses, with
    /// the `analysis-metadata.json` that files the folder under SPAdes, and writes the schema 3 `assembly-result.json` that
    /// `AssemblyResult.save(to:)` writes over the copy's schema 1 sidecar, which `AssemblyResult.load(from:)` cannot decode.
    /// The statistics are those of the copy's `contigs.fasta`, two contigs of 122 and 61 bases with 92 of 183 bases G or C.
    @discardableResult
    static func assemblyResult(in project: URL) throws -> URL {
        let destination = project.appendingPathComponent("Analyses/\(assemblyFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SafetyNetPaths.fixture("analyses/\(assemblyFolder)"), to: destination)
        let metadata: [String: Any] = ["created": ISO8601DateFormatter().string(from: Date()), "isBatch": false, "tool": "spades"]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("analysis-metadata.json"))
        let statistics: [String: Any] = ["contigCount": 2, "totalLengthBP": 183, "largestContigBP": 122, "smallestContigBP": 61,
                                         "n50": 122, "l50": 1, "n90": 61, "gcFraction": 92.0 / 183.0, "meanLengthBP": 91.5]
        let sidecar: [String: Any] = ["schemaVersion": 3, "tool": "spades", "readType": "illuminaShortReads", "outcome": "completed",
                                      "contigsPath": "contigs.fasta", "logPath": "spades.log", "assemblerVersion": "3.15.5",
                                      "commandLine": "spades.py --isolate -1 HG002_R1.fastq.gz -2 HG002_R2.fastq.gz -o spades",
                                      "outputDirectory": destination.path, "statistics": statistics, "wallTimeSeconds": 123.4]
        try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("assembly-result.json"))
        return destination
    }
}

@MainActor
final class SmokeFixtureReadTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        project = try TestTempDirectory.make(prefix: "SmokeFixtureRead")
    }

    override func tearDownWithError() throws {
        if let project { TestTempDirectory.cleanup(project) }
        project = nil
        try super.tearDownWithError()
    }

    /// The dashboard opens from the sidecar when `loadFASTQDatasetInBackground` finds a primary file, a bundle that is not
    /// multi-file and cached statistics that were measured. Any other answer counts the reads with seqkit, a managed tool.
    func testTheFASTQBundleOpensTheDashboardFromItsCachedStatistics() async throws {
        let bundle = try SmokeFixtureBytes.fastqBundle(in: project)
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: bundle)?.id, .fastq, "The registry reads the folder as a FASTQ bundle")
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), "The bundle names its reads file")
        XCTAssertFalse(FASTQBundle.isMultiFileBundle(bundle), "The bundle holds one reads file")
        // loadIfPresent throws on a sidecar that does not decode, where load(for:) would answer nil and hide the reason.
        let metadata = try FASTQMetadataStore.loadIfPresent(for: fastq)
        let cached = try XCTUnwrap(metadata?.computedStatistics, "The sidecar holds computed statistics")
        XCTAssertTrue(cached.isMeasured, "The statistics count as measured, so the dashboard does not count the reads")
        XCTAssertEqual(cached.readCount, 2)
        // The app's own counter, which needs no managed tool, agrees with the numbers written by hand.
        let counted = try await FASTQReader(validateSequence: false).computeStatistics(from: fastq).statistics
        XCTAssertEqual(counted.readCount, cached.readCount)
        XCTAssertEqual(counted.baseCount, cached.baseCount)
        XCTAssertEqual(counted.maxReadLength, cached.maxReadLength)
        XCTAssertEqual(counted.gcContent, cached.gcContent, accuracy: 0.0001)
        XCTAssertEqual(counted.readLengthHistogram, cached.readLengthHistogram)
    }

    /// The viewer shows the bundle from `MHCReferenceBundleViewportModel.load`, which reads the manifest, the FASTA and
    /// the haplotype definitions the manifest names, and here it names none.
    func testTheMHCReferenceBundleLoadsWithNoHaplotypeDefinition() throws {
        let bundle = try SmokeFixtureBytes.mhcReferenceBundle(in: project)
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: bundle)?.id, .mhcReference, "The registry reads the folder as an MHC reference bundle")
        try MHCAmpliconReferenceBundle.validate(at: bundle)
        let model = try MHCReferenceBundleViewportModel.load(bundleURL: bundle)
        XCTAssertEqual(model.title, SmokeFixtureBytes.mhcRow)
        XCTAssertEqual(model.referenceCount, 2)
        XCTAssertTrue(model.definitionSummaries.isEmpty)
        XCTAssertNil(model.embeddedReferenceBundleURL, "The bundle embeds no reference bundle, so the viewer draws the FASTA text")
        XCTAssertTrue(model.fastaText.hasPrefix(">Mamu-A1-001"), "The FASTA text reads from the first record")
    }

    /// The genotype result opens as the native matrix when the result loaded by `loadResultAsync` has matrix content, and
    /// as a preview of its workbook otherwise (`MainSplitViewController.shouldPreviewPrimaryWorkbook`).
    func testTheGenotypeResultLoadsAsTheNativeMatrix() async throws {
        let bundle = try SmokeFixtureBytes.genotypeResult(in: project)
        XCTAssertEqual(BundleKindRegistry.recognizedKind(at: bundle)?.id, .genotypeResult, "The registry reads the folder as a genotype result")
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        XCTAssertEqual(manifest.outputName, SmokeFixtureBytes.genotypeRow)
        let result = try await ONTGenotypeResultBundle.loadResultAsync(from: bundle)
        XCTAssertEqual(result.callCount, 1)
        XCTAssertEqual(result.stats.totalInputReads, 10)
        XCTAssertTrue(result.hasNativeGenotypeMatrixContent, "The result has matrix content")
        XCTAssertFalse(MainSplitViewController.shouldPreviewPrimaryWorkbook(for: result), "The sidebar opens the matrix, not the workbook")
    }

    /// The sidebar scan lists each fixture, and gives the three bundles the kind their viewer needs. The two loose files
    /// at the project root, the script and the FASTA file, are rows too, since the smoke clicks them by their words.
    func testTheSidebarListsEachFixtureWithItsKind() throws {
        try SmokeFixtureBytes.fastqBundle(in: project)
        try SmokeFixtureBytes.mhcReferenceBundle(in: project)
        try SmokeFixtureBytes.genotypeResult(in: project)
        try SmokeFixtureBytes.fastaCollection(in: project)
        try SmokeFixtureBytes.scriptPreview(in: project)
        let nodes = SidebarProjectScanner.scanRootNodes(from: project)
        let listed = nodes.map { "\($0.type) \($0.title)" }.joined(separator: ", ")
        func node(containing words: String) -> SidebarScanNode? { nodes.first { $0.title.contains(words) } }
        XCTAssertEqual(node(containing: SmokeFixtureBytes.fastqRow)?.type, .fastqBundle, "Rows: \(listed)")
        XCTAssertEqual(node(containing: SmokeFixtureBytes.mhcRow)?.type, .mhcReferenceBundle, "Rows: \(listed)")
        XCTAssertEqual(node(containing: SmokeFixtureBytes.genotypeRow)?.type, .genotypeResultBundle, "Rows: \(listed)")
        XCTAssertEqual(node(containing: "clusters")?.type, .sequence, "Rows: \(listed)")
        XCTAssertNotNil(node(containing: SmokeFixtureBytes.scriptFile), "Rows: \(listed)")
    }

    /// The assembly opens from `displayAssemblyAnalysisFromSidebar`, which loads the sidecar with `AssemblyResult.load(from:)`
    /// and hands the result to the viewer, and the viewer reads the contigs the sidecar names. The committed seed's sidecar is
    /// schema 1 and lacks the keys the loader needs, so a plain copy of it logged "Failed to open spades-2026-01-15T13-00-00"
    /// and the smoke's Assembly row found no viewer. The smoke writes the sidecar that `AssemblyResult.save` writes over the copy.
    func testTheAssemblyResultLoadsWithItsContigs() async throws {
        let folder = try SmokeFixtureBytes.assemblyResult(in: project)
        let result = try AssemblyResult.load(from: folder)
        XCTAssertEqual(result.tool, .spades)
        XCTAssertEqual(result.readType, .illuminaShortReads)
        XCTAssertEqual(result.outcome, .completed, "The viewer draws the contigs, not the words for an assembly with none")
        XCTAssertEqual(result.contigsPath.lastPathComponent, "contigs.fasta")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: result.contigsPath.path), "The sidecar names a contigs file in the folder")
        // The numbers written by hand are the app's own count of the contigs file, which needs no managed tool.
        let counted = try AssemblyStatisticsCalculator.compute(from: result.contigsPath)
        XCTAssertEqual(result.statistics.contigCount, 2)
        XCTAssertEqual(result.statistics.contigCount, counted.contigCount)
        XCTAssertEqual(result.statistics.totalLengthBP, counted.totalLengthBP)
        XCTAssertEqual(result.statistics.largestContigBP, counted.largestContigBP)
        XCTAssertEqual(result.statistics.smallestContigBP, counted.smallestContigBP)
        XCTAssertEqual(result.statistics.n50, counted.n50)
        XCTAssertEqual(result.statistics.l50, counted.l50)
        XCTAssertEqual(result.statistics.n90, counted.n90)
        XCTAssertEqual(result.statistics.gcFraction, counted.gcFraction, accuracy: 0.0001)
        XCTAssertEqual(result.statistics.meanLengthBP, counted.meanLengthBP, accuracy: 0.0001)
        // The contig table is the catalog's records, which the viewer reads from the same file.
        let records = try await AssemblyContigCatalog(result: result).records()
        XCTAssertEqual(records.map(\.name), ["NODE_1_length_500_cov_25.4", "NODE_2_length_300_cov_15.1"])
        XCTAssertEqual(records.map(\.lengthBP), [122, 61])
    }
}
