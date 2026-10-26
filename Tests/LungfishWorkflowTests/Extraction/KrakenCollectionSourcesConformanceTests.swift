// KrakenCollectionSourcesConformanceTests.swift - A taxa collection resolves its result's read files once
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.11, fix 5 of the c4 review. `extractBatch` resolved the read files of a result once
// before its taxa, so a trimmed or oriented subset was materialized once for a whole collection. The
// resolver's collection loop resolved them again for each taxon, which took a collection of 10 taxa
// about seven times as long, until the loop took every taxon's reads from one resolve before it. The
// pins run the managed seqkit, hence the name.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class KrakenCollectionSourcesConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-collection-sources")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The oriented subset of ``Kraken2ResultShapes`` (s2 of the target, s1 and s3 of the other taxon)
    /// and the root file its reads come from.
    private func orientedSubset() throws -> (result: URL, rootReads: URL) {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let result = try shapes.orientedSubsetResult()
        let rootReads = shapes.fixtures.importsURL.appendingPathComponent("orient-root.lungfishfastq/reads.fastq")
        return (result, rootReads)
    }

    /// Given the files resolved before, an extraction reads them and does not resolve the files its
    /// result records again, so it still extracts after the root file is gone. Without them it resolves
    /// the recorded files and skips the sample.
    func testAnExtractionGivenResolvedSourcesExtractsAfterTheRecordedReadFileIsGone() async throws {
        let subset = try orientedSubset()
        let sources = try await KrakenResultReadSources.resolve(
            result: try ClassificationResult.load(from: subset.result),
            materializationDirectory: root.appendingPathComponent("materialized", isDirectory: true)
        )
        try FileManager.default.removeItem(at: subset.rootReads)
        let resolver = ClassifierReadResolver()
        let selections = [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [Kraken2ResultShapes.target])]

        do {
            _ = try await resolver.extractViaKraken2(
                selections: selections, resultPath: subset.result, options: ExtractionOptions(),
                destination: .file(root.appendingPathComponent("recorded.fastq")), runClock: ProvenanceRunClock(),
                progress: nil
            )
            XCTFail("the recorded root file is gone, so a resolve of the recorded files finds no reads")
        } catch {
            // The skip says what to try (`reviews/EXT-UX.md`, ruling 2), and the test runs on to the resolved extraction.
            if case ClassifierExtractionError.allSamplesSkipped = error {
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "Put their files or bundle back in the same place in this project, or where the run recorded them, "
                            + "and try again. Or run the classification again in this project."
                    ),
                    error.localizedDescription
                )
            } else {
                XCTFail("a gone root file ends in allSamplesSkipped, not \(error)")
            }
        }

        let extraction = try await resolver.extractViaKraken2(
            selections: selections, resultPath: subset.result, options: ExtractionOptions(),
            destination: .file(root.appendingPathComponent("resolved.fastq")), runClock: ProvenanceRunClock(),
            resolvedSources: sources, progress: nil
        )
        guard case .file(let output, _) = extraction.outcome else {
            return XCTFail("expected a file outcome, got \(extraction.outcome)")
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "@s2\nCCGGGGTTTT\n+\nJIHGFEDCBA\n")
        XCTAssertEqual(extraction.sourceFiles, sources.urls, "the files read are the ones resolved before")
    }

    /// The root file goes when the second taxon starts. A collection that resolved its files before its
    /// taxa still reads the second taxon from its materialized subset, where a resolve for each taxon
    /// failed it with the words of the missing source.
    func testACollectionResolvesItsReadFilesOnceForAllItsTaxa() async throws {
        let subset = try orientedSubset()
        let collection = TaxaCollection(
            id: "sources-once", name: "Sources once", description: "", sfSymbol: "circle",
            taxa: [
                TaxonTarget(name: "Target virus", taxId: Kraken2ResultShapes.target, includeChildren: true),
                TaxonTarget(name: "Other virus", taxId: Kraken2ResultShapes.other, includeChildren: true),
            ]
        )
        let rootReads = subset.rootReads
        let outputs = try await ClassifierReadResolver().extractCollection(
            collection,
            resultPath: subset.result,
            classification: try ClassificationResult.load(from: subset.result),
            outputDirectory: root.appendingPathComponent("extracted", isDirectory: true),
            progress: { _, message in
                if message.hasPrefix("Extracting Other virus") { try? FileManager.default.removeItem(at: rootReads) }
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootReads.path), "the root file went before the second taxon")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Target_virus_taxid100.fastq.gz", "Other_virus_taxid200.fastq.gz"])
        XCTAssertEqual(try outputs.map { try Kraken2ResultSourcesExtractionTests.recordNames(in: $0) }, [["s2"], ["s1", "s3"]])
    }
}
