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

    // MARK: - Multi-Sample Database Tests

    @Test
    func importNaoMgsWithMultipleSamplesCreatesSQLite() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-multisample-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tsvContent = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status
        SAMPLE_A\treadA1\t111\tACGTACGT\tIIIIIIII\tACC001\t10\t0\t8\tFalse\tCP
        SAMPLE_A\treadA2\t111\tACGTACGA\tIIIIIIII\tACC001\t10\t1\t8\tFalse\tCP
        SAMPLE_A\treadA3\t222\tACGTACGG\tIIIIIIII\tACC002\t30\t0\t8\tTrue\tCP
        SAMPLE_B\treadB1\t111\tACGTACGT\tIIIIIIII\tACC001\t50\t0\t8\tFalse\tCP
        SAMPLE_B\treadB2\t333\tACGTACGC\tIIIIIIII\tACC003\t70\t2\t8\tFalse\tUP
        """
        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try tsvContent.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "MULTI_TEST",
            fetchReferences: false
        )

        // Verify SQLite exists, no JSON or BAM
        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("virus_hits.json").path))

        // Open and query
        let db = try NaoMgsDatabase(at: bundle.appendingPathComponent("hits.sqlite"))

        // 2 samples
        let samples = try db.fetchSamples()
        #expect(samples.count == 2)

        // Sample A: taxon 111 (2 hits), taxon 222 (1 hit) = 2 rows
        let sampleARows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_A"])
        #expect(sampleARows.count == 2)

        // Sample B: taxon 111 (1 hit), taxon 333 (1 hit) = 2 rows
        let sampleBRows = try db.fetchTaxonSummaryRows(samples: ["SAMPLE_B"])
        #expect(sampleBRows.count == 2)

        // All samples: 2 (from A) + 2 (from B) = 4 rows
        let allRows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(allRows.count == 4)

        // Unique reads: SAMPLE_A taxon 111 has 2 hits at same position (ref_start=10) → 1 unique
        let taxA111 = sampleARows.first(where: { $0.taxId == 111 })
        #expect(taxA111 != nil)
        #expect(taxA111?.hitCount == 2)
        #expect(taxA111?.uniqueReadCount == 1, "Two reads at same position should be 1 unique")
    }

    // MARK: - FASTA Blank-Line Normalization

    @Test
    func splitMultiRecordFASTAStripsBlankLinesWithinSequences() {
        // Simulates NCBI efetch returning blank lines within a sequence record.
        // This is the root cause of wrong reference lengths: samtools faidx treats
        // blank lines as record separators, so a 935bp genome reads as 186bp if
        // there's a blank line after the first 186 bases of sequence.
        let fasta = """
        >AB283001.1 Human polyomavirus 6, complete genome
        ATGGCCCTCAAAATTACAGAACTAAAAGAAACTTTAGCTAGAATCAAAGAACCAGATTATG
        ATGATATTCAAGCAGTCTTACTTTTTAAGAAAGGCACCCCATTTTTTGCATTCAGATTTCA

        GCAGCAGACAGCACCATTTCACCTGCCTCAGAACTGTTGCCTCAAACCTTCAATGAGAATA
        ACAGAGGTCTAGCAGCAGGTTTCAAAGGAGAGAAGGGCCGGTCACAGGAT
        """

        let records = MetagenomicsImportService.splitMultiRecordFASTA(fasta)
        #expect(records.count == 1, "Should find 1 record, blank line within sequence should not split")
        guard let record = records["AB283001.1"] else {
            Issue.record("Missing AB283001.1 record")
            return
        }

        // The blank line should be stripped, leaving header + 4 sequence lines
        let lines = record.split(separator: "\n")
        #expect(lines.count == 5, "Expected 1 header + 4 sequence lines, got \(lines.count)")

        // No blank lines should remain
        for (i, line) in lines.enumerated() {
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty,
                "Line \(i) should not be blank: '\(line)'")
        }
    }

    @Test
    func splitMultiRecordFASTAStripsWindowsLineEndings() {
        // NCBI efetch may return \r\n line endings
        let fasta = ">ACC001.1 Some virus\r\nACGTACGT\r\nGGCCTTAA\r\n\r\n>ACC002.1 Another virus\r\nTTAAGGCC\r\n"

        let records = MetagenomicsImportService.splitMultiRecordFASTA(fasta)
        #expect(records.count == 2)

        // Verify no \r characters remain
        for (acc, text) in records {
            #expect(!text.contains("\r"), "Record \(acc) should not contain \\r")
        }
    }

    @Test
    func normalizeSingleFASTARecordStripsBlankLines() {
        // Test the helper that normalizes a single FASTA record (used by the fallback path)
        let rawFasta = ">AB283001.1 Human polyomavirus 6\r\nACGTACGT\r\n\r\nGGCCTTAA\r\nTTAAGGCC\r\n"

        let normalized = MetagenomicsImportService.normalizeFASTARecord(rawFasta)

        // Should strip \r, remove blank lines, end with \n
        #expect(!normalized.contains("\r"), "Should not contain \\r")
        #expect(normalized.hasSuffix("\n"), "Should end with newline")

        let lines = normalized.split(separator: "\n")
        #expect(lines.count == 4, "Expected 1 header + 3 sequence lines, got \(lines.count)")
        for line in lines {
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty, "No blank lines")
        }
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
