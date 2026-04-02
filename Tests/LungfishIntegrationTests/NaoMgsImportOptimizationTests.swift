// NaoMgsImportOptimizationTests.swift — Tests for NAO-MGS import optimization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

struct NaoMgsImportOptimizationTests {

    // MARK: - Line Progress Callback

    @Test
    func parseVirusHitsCallsLineProgressCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Use a lock-protected counter to avoid Sendable mutation errors in Swift 6
        final class Counter: @unchecked Sendable {
            var values: [Int] = []
            func append(_ v: Int) { values.append(v) }
        }
        let counter = Counter()

        let hits = try await parser.parseVirusHits(at: url) { lineCount in
            counter.append(lineCount)
        }

        #expect(hits.count == 35, "Fixture has 35 data rows")
        #expect(!counter.values.isEmpty, "lineProgress should have been called at least once")
        // Final reported count should be >= 35 (header + 35 data lines = 36 total lines)
        #expect(counter.values.last! >= 35)
    }

    @Test
    func parseVirusHitsWorksWithoutCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Existing signature still works with no callback
        let hits = try await parser.parseVirusHits(at: url)
        #expect(hits.count == 35)
    }

    // MARK: - Top-5 Accession Filtering

    @Test
    func selectTopAccessionsPerTaxonFiltersCorrectly() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()
        let hits = try await parser.parseVirusHits(at: url)

        let selected = MetagenomicsImportService.selectTopAccessionsPerTaxon(
            hits: hits,
            maxPerTaxon: 5
        )

        // Taxon 28875 has 9 accessions — only top 5 by hit count should be kept
        // Taxon 10941 has 3 — all kept
        // Taxon 2748378 has 2 — all kept
        // Taxon 1187973 has 1 — kept
        // Total unique: 11
        #expect(selected.count == 11, "Expected 11 unique accessions, got \(selected.count): \(selected)")

        // Taxon 28875: KR705168.1 has 4 hits (highest), must be included
        #expect(selected.contains("KR705168.1"))

        // Bottom accessions for taxon 28875 (1 hit each) should NOT be included
        let bottom28875 = ["JN258371.1", "KJ752320.1", "KU356637.1"]
        let bottomIncluded = bottom28875.filter { selected.contains($0) }
        #expect(bottomIncluded.isEmpty, "Bottom-ranked 28875 accessions should be filtered out: \(bottomIncluded)")

        // All accessions for taxa with <=5 accessions should be present
        #expect(selected.contains("MH617353.1"), "2748378 accession should be kept")
        #expect(selected.contains("MH617681.1"), "2748378 accession should be kept")
        #expect(selected.contains("LC105580.1"), "10941 accession should be kept")
        #expect(selected.contains("LC105591.1"), "10941 accession should be kept")
        #expect(selected.contains("KP198630.1"), "10941 accession should be kept")
        #expect(selected.contains("JQ776552.1"), "1187973 accession should be kept")
    }

    // MARK: - FASTA Splitting

    @Test
    func splitMultiRecordFASTAExtractsRecords() {
        let concatenated = """
        >NC_045512.2 Severe acute respiratory syndrome coronavirus 2 isolate Wuhan-Hu-1
        ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAACCAACTTTCGATCTCTTGTAGATCTG
        TTCTCTAAACGAACTTTAAAATCTGTGTGGCTGTCACTCGGCTGCATGCTTAGTGCACTCA
        >MH617353.1 Mammarenavirus juquitibense segment L
        CGCACCGGGGATCCTAGGCTTTTAGAGCACATGGATACATAGATCTACTCTCCAAGG
        >KR705168.1 Pepper mottle virus isolate PepMoV-Yolo
        AAATTAAAACAAATTCAATTCAAACAAAGCAATGGG
        TTGGAACCACTTGTACCACTACCC
        """

        let records = MetagenomicsImportService.splitMultiRecordFASTA(concatenated)

        #expect(records.count == 3, "Should find 3 FASTA records, got \(records.count)")
        #expect(records.keys.contains("NC_045512.2"))
        #expect(records.keys.contains("MH617353.1"))
        #expect(records.keys.contains("KR705168.1"))

        for (accession, fastaText) in records {
            #expect(fastaText.hasPrefix(">"), "Record for \(accession) should start with '>'")
            let lines = fastaText.split(separator: "\n")
            #expect(lines.count >= 2, "Record for \(accession) should have header + sequence")
        }

        // Multi-line sequence should be preserved
        let pepMottle = records["KR705168.1"]!
        let pepLines = pepMottle.split(separator: "\n")
        #expect(pepLines.count == 3, "PepMoV record should have 1 header + 2 sequence lines")
    }

    @Test
    func splitMultiRecordFASTAHandlesEmptyInput() {
        let records = MetagenomicsImportService.splitMultiRecordFASTA("")
        #expect(records.isEmpty)
    }

    // MARK: - Full Pipeline

    @Test
    func importNaoMgsWithFixtureCreatesValidBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-pipeline-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: url,
            outputDirectory: outputDirectory,
            sampleName: "CASPER_TEST",
            fetchReferences: false
        )

        // Verify bundle structure
        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))

        // Verify result metadata
        #expect(result.sampleName == "CASPER_TEST")
        #expect(result.totalHitReads == 35)
        #expect(result.taxonCount == 4)
        #expect(result.fetchedReferenceCount == 0)

        // Verify manifest content
        let manifestData = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let manifestDecoder = JSONDecoder()
        manifestDecoder.dateDecodingStrategy = .iso8601
        let manifest = try manifestDecoder.decode(NaoMgsManifest.self, from: manifestData)
        #expect(manifest.sampleName == "CASPER_TEST")
        #expect(manifest.hitCount == 35)
        #expect(manifest.taxonCount == 4)

        // Verify SQLite database content
        let db = try NaoMgsDatabase(at: bundle.appendingPathComponent("hits.sqlite"))
        #expect(try db.totalHitCount(samples: nil) == 35)
        let samples = try db.fetchSamples()
        #expect(!samples.isEmpty)
        let summaryRows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(!summaryRows.isEmpty)
    }

    @Test
    func importNaoMgsWithIdentityFilterReducesHits() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-filter-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: url,
            outputDirectory: outputDirectory,
            sampleName: "FILTER_TEST",
            minIdentity: 99.5,
            fetchReferences: false
        )

        // With a high identity threshold, some hits should be filtered out
        #expect(result.totalHitReads < 35, "Identity filter should reduce hit count")
        #expect(result.totalHitReads >= 0)
    }

    // MARK: - Error Handling

    @Test
    func importAbortedErrorCarriesResultDirectory() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-abort-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        do {
            _ = try await MetagenomicsImportService.importNaoMgs(
                inputURL: sourceFile,
                outputDirectory: outputDirectory,
                sampleName: "ABORT_TEST",
                fetchReferences: false
            )
            // If it succeeds (samtools available), that's fine
            let importsContents = try FileManager.default.contentsOfDirectory(
                at: outputDirectory, includingPropertiesForKeys: nil
            )
            #expect(!importsContents.isEmpty)
        } catch let error as MetagenomicsImportError {
            if case .importAborted(let dir, _) = error {
                #expect(FileManager.default.fileExists(atPath: dir.path),
                    "importAborted should reference an existing directory")
            }
        }
    }
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
