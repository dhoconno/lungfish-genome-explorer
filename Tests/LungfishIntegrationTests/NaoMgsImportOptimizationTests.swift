// NaoMgsImportOptimizationTests.swift — Tests for NAO-MGS import optimization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import Testing
import LungfishIO
@testable import LungfishWorkflow

@Suite(.serialized)
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

        #expect(hits.count == 34, "Fixture has 35 data rows, 1 has NA sequence and is filtered")
        #expect(!counter.values.isEmpty, "lineProgress should have been called at least once")
        // Final reported count should be >= 34 (header + 35 data lines = 36 total lines, 1 NA filtered)
        #expect(counter.values.last! >= 34)
    }

    @Test
    func parseVirusHitsWorksWithoutCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Existing signature still works with no callback
        let hits = try await parser.parseVirusHits(at: url)
        #expect(hits.count == 34)
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

        let result = try await importNaoMgsForTesting(
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

        // Verify paired-end reads survive the full import pipeline (BAM materialization)
        let bamsDir = bundle.appendingPathComponent("bams")
        let bamFiles = try FileManager.default.contentsOfDirectory(at: bamsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "bam" }
        #expect(!bamFiles.isEmpty, "Import should produce BAM files")

        // Use samtools to count paired-end records in the BAMs
        if let samtoolsPath = SamtoolsLocator.locate() {
            var totalRecords = 0
            var pairedRecords = 0
            for bam in bamFiles {
                // Count all records
                let allProc = Process()
                allProc.executableURL = URL(fileURLWithPath: samtoolsPath)
                allProc.arguments = ["view", "-c", bam.path]
                let allPipe = Pipe()
                allProc.standardOutput = allPipe
                try allProc.run()
                allProc.waitUntilExit()
                let allStr = String(data: allPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                totalRecords += Int(allStr ?? "0") ?? 0

                // Count paired records (flag 0x1)
                let pairProc = Process()
                pairProc.executableURL = URL(fileURLWithPath: samtoolsPath)
                pairProc.arguments = ["view", "-c", "-f", "1", bam.path]
                let pairPipe = Pipe()
                pairProc.standardOutput = pairPipe
                try pairProc.run()
                pairProc.waitUntilExit()
                let pairStr = String(data: pairPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                pairedRecords += Int(pairStr ?? "0") ?? 0
            }

            // Fixture has 33 paired reads (both R1+R2), 1 R1-only, and 1 R2-only.
            // BAMs: 33×2=66 paired + 1 R1-only + 1 R2-only = 68 total, 66 paired.
            #expect(totalRecords == 68, "Expected 68 BAM records (33 pairs + 2 singles), got \(totalRecords)")
            #expect(pairedRecords == 66, "Expected 66 paired-end BAM records (33 pairs × 2), got \(pairedRecords)")
        }
    }

    @Test
    func createStreamingCountsPairedRowsAsTwoAlignments() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-paired-counts-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = workspace.appendingPathComponent("virus_hits_final.tsv")
        let dbURL = workspace.appendingPathComponent("hits.sqlite")
        let tsv = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_seq_rev\tquery_qual\tquery_qual_rev\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_ref_start_rev\tprim_align_edit_distance\tprim_align_edit_distance_rev\tquery_len\tquery_len_rev\tprim_align_query_rc\tprim_align_query_rc_rev\tprim_align_pair_status\tprim_align_best_alignment_score\tprim_align_best_alignment_score_rev\tprim_align_fragment_length\tprim_align_cigar\tprim_align_subject_title
        paired_sample\tread_001\t82658\tACGTACGT\tTGCATGCA\tIIIIIIII\tJJJJJJJJ\tX86557.1\t100\t240\t1\t2\t8\t8\tFalse\tTrue\tCP\t90\t88\t148\t8M\tLordsdale virus
        """
        try tsv.write(to: input, atomically: true, encoding: .utf8)

        _ = try await NaoMgsDatabase.createStreaming(at: dbURL, from: [input])
        let db = try NaoMgsDatabase(at: dbURL)
        let rows = try db.fetchTaxonSummaryRows()
        #expect(rows.count == 1)
        #expect(rows[0].hitCount == 2, "A paired NAO-MGS row should count as two BAM alignments")
        #expect(rows[0].uniqueReadCount == 2, "A paired NAO-MGS row should contribute two unique alignments")

        let accessions = try db.fetchAccessionSummaries(sample: "paired_sample", taxId: 82658)
        #expect(accessions.count == 1)
        #expect(accessions[0].readCount == 2, "Per-accession counts should match the two BAM alignments")
        #expect(accessions[0].uniqueReadCount == 2, "Per-accession unique counts should match the two BAM alignments")
    }

    @Test
    func importNaoMgsWithIdentityFilterReducesHits() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-filter-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        let result = try await importNaoMgsForTesting(
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
        let result = try await importNaoMgsForTesting(
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

    // MARK: - Accession Summaries and Virus Hits Purge

    @Test
    func importPopulatesAccessionSummariesAndPurgesVirusHits() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-purge-test-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tsvContent = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_seq_rev\tquery_qual\tquery_qual_rev\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_ref_start_rev\tprim_align_edit_distance\tprim_align_edit_distance_rev\tquery_len\tquery_len_rev\tprim_align_query_rc\tprim_align_query_rc_rev\tprim_align_pair_status\tprim_align_best_alignment_score\tprim_align_best_alignment_score_rev\tprim_align_fragment_length\tprim_align_cigar
        SAMPLE_X\tread1\t100\tACGTACGTAC\tTGCATGCATG\tIIIIIIIIII\tJJJJJJJJJJ\tACC_A\t0\t20\t0\t0\t10\t10\tFalse\tTrue\tCP\t100\t99\t200\t10M
        SAMPLE_X\tread2\t100\tACGTACGTAC\tTGCATGCATG\tIIIIIIIIII\tJJJJJJJJJJ\tACC_A\t50\t70\t1\t1\t10\t10\tTrue\tFalse\tCP\t95\t94\t200\t10M
        SAMPLE_X\tread3\t100\tGGCCTTAAGG\tCCTTAAGGCC\tIIIIIIIIII\tJJJJJJJJJJ\tACC_B\t0\t10\t0\t0\t10\t10\tFalse\tTrue\tCP\t110\t109\t200\t10M
        SAMPLE_X\tread4\t200\tTTAAGGCCTT\tAAGGCCTTAA\tIIIIIIIIII\tJJJJJJJJJJ\tACC_C\t10\t30\t2\t2\t10\t10\tFalse\tTrue\tUP\t80\t79\t150\t10M
        """
        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try tsvContent.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("analyses", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "PURGE_TEST",
            fetchReferences: false
        )

        let bundle = result.resultDirectory
        let dbURL = bundle.appendingPathComponent("hits.sqlite")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        let db = try NaoMgsDatabase(at: dbURL)

        // 1. Accession summaries should be pre-computed and remain alignment-based.
        let accSummaries = try db.fetchAccessionSummaries(sample: "SAMPLE_X", taxId: 100)
        #expect(accSummaries.count == 2, "Taxon 100 has 2 accessions: ACC_A (4 alignments), ACC_B (2 alignments)")

        let accA = try #require(accSummaries.first(where: { $0.accession == "ACC_A" }))
        #expect(accA.readCount == 4)
        #expect(accA.coveredBasePairs == 40, "Coverage should include both mate intervals (0-10, 20-30, 50-60, 70-80)")

        let accB = try #require(accSummaries.first(where: { $0.accession == "ACC_B" }))
        #expect(accB.readCount == 2)

        // 2. totalHitCount should remain row-based for the public result summary.
        let totalHits = try db.totalHitCount()
        #expect(totalHits == 4)

        // 3. fetchSamples should stay row-based as well.
        let samples = try db.fetchSamples()
        #expect(samples.count == 1)
        #expect(samples[0].sample == "SAMPLE_X")
        #expect(samples[0].hitCount == 4)

        // 4. If BAMs were created, virus_hits should be purged
        let bamsDir = bundle.appendingPathComponent("bams")
        if FileManager.default.fileExists(atPath: bamsDir.path) {
            #expect(result.createdBAM, "createdBAM flag should be true when BAMs exist")

            // virus_hits should be empty after purge
            let reads = try db.fetchReadsForAccession(
                sample: "SAMPLE_X", taxId: 100, accession: "ACC_A"
            )
            #expect(reads.isEmpty, "virus_hits should be purged after BAM materialization")
        }
    }

    @Test
    func importWithFixtureCreatesAccessionSummaries() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-accsummary-fixture-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let url = TestFixtures.naomgs.virusHitsTsvGz
        let outputDirectory = workspace.appendingPathComponent("analyses", isDirectory: true)

        let result = try await importNaoMgsForTesting(
            inputURL: url,
            outputDirectory: outputDirectory,
            sampleName: "ACC_SUMMARY_TEST",
            fetchReferences: false
        )

        let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))

        // The fixture has 7 samples and 4 taxa — there should be accession summaries
        let samples = try db.fetchSamples()
        #expect(!samples.isEmpty)

        // Pick the first sample and first taxon to verify accession summaries exist
        let taxonRows = try db.fetchTaxonSummaryRows(samples: [samples[0].sample])
        #expect(!taxonRows.isEmpty)

        let summaries = try db.fetchAccessionSummaries(
            sample: taxonRows[0].sample,
            taxId: taxonRows[0].taxId
        )
        #expect(!summaries.isEmpty, "Accession summaries should be populated for fixture data")
        for s in summaries {
            #expect(s.readCount > 0)
            #expect(s.referenceLength > 0)
            #expect(s.coveredBasePairs > 0)
            #expect(s.coverageFraction > 0)
        }
    }

    // MARK: - Multi-File Import (NAO-MGS 3.2 per-lane TSVs)

    @Test
    func importDirectoryOfPerLaneTSVsCreatesValidBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-multifile-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status"

        // Create two per-lane TSV files (simulating NAO-MGS 3.2 output)
        let lane1 = """
        \(header)
        SAMPLE_A_L001\tread1\t111\tACGTACGT\tIIIIIIII\tACC001\t10\t0\t8\tFalse\tCP
        SAMPLE_A_L001\tread2\t111\tACGTACGA\tIIIIIIII\tACC001\t20\t1\t8\tFalse\tCP
        SAMPLE_A_L001\tread3\t222\tACGTACGG\tIIIIIIII\tACC002\t30\t0\t8\tTrue\tCP
        """
        let lane2 = """
        \(header)
        SAMPLE_A_L002\tread4\t111\tACGTACGC\tIIIIIIII\tACC001\t40\t0\t8\tFalse\tUP
        SAMPLE_A_L002\tread5\t333\tACGTACGT\tIIIIIIII\tACC003\t50\t2\t8\tFalse\tUP
        """

        let inputDir = workspace.appendingPathComponent("naomgs-output", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try lane1.write(to: inputDir.appendingPathComponent("run.sample_L001_virus_hits.tsv"), atomically: true, encoding: .utf8)
        try lane2.write(to: inputDir.appendingPathComponent("run.sample_L002_virus_hits.tsv"), atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("analyses", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: inputDir,
            outputDirectory: outputDirectory,
            sampleName: "MULTIFILE_TEST",
            fetchReferences: false
        )

        // All 5 rows from both files should be imported
        #expect(result.totalHitReads == 5)

        // Should have 3 distinct taxa: 111, 222, 333
        #expect(result.taxonCount == 3)

        // Verify SQLite database
        let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))
        #expect(try db.totalHitCount(samples: nil) == 5)

        // Sample names are normalized (lane suffix stripped)
        let samples = try db.fetchSamples()
        #expect(samples.count == 2, "Two lanes should produce two samples (SAMPLE_A_L001 → SAMPLE_A, etc.)")

        let summaryRows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(!summaryRows.isEmpty)
    }

    @Test
    func mergedDatabaseAppendsSampleScopedSummariesAndMergesReferenceLengths() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-merge-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sampleADatabaseURL = workspace.appendingPathComponent("sampleA.sqlite")
        let sampleBDatabaseURL = workspace.appendingPathComponent("sampleB.sqlite")
        let mergedDatabaseURL = workspace.appendingPathComponent("merged.sqlite")

        try await createSyntheticNaoMgsStageDatabase(
            at: sampleADatabaseURL,
            sample: "SAMPLE_A",
            taxId: 111,
            accession: "ACC_SHARED",
            referenceLength: 100
        )
        try await createSyntheticNaoMgsStageDatabase(
            at: sampleBDatabaseURL,
            sample: "SAMPLE_B",
            taxId: 222,
            accession: "ACC_SHARED",
            referenceLength: 150
        )

        try NaoMgsDatabase.createMergedSummaryDatabase(at: mergedDatabaseURL, from: [
            .init(
                sample: "SAMPLE_A",
                databaseURL: sampleADatabaseURL,
                bamRelativePath: "bams/SAMPLE_A.bam",
                bamIndexRelativePath: "bams/SAMPLE_A.bam.bai"
            ),
            .init(
                sample: "SAMPLE_B",
                databaseURL: sampleBDatabaseURL,
                bamRelativePath: "bams/SAMPLE_B.bam",
                bamIndexRelativePath: "bams/SAMPLE_B.bam.bai"
            ),
        ])

        let db = try NaoMgsDatabase(at: mergedDatabaseURL)
        let taxonRows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(taxonRows.count == 2)

        let maybeSampleARow = taxonRows.first { $0.sample == "SAMPLE_A" && $0.taxId == 111 }
        let sampleARow = try #require(maybeSampleARow)
        #expect(sampleARow.bamPath == "bams/SAMPLE_A.bam")
        #expect(sampleARow.bamIndexPath == "bams/SAMPLE_A.bam.bai")

        let maybeSampleBRow = taxonRows.first { $0.sample == "SAMPLE_B" && $0.taxId == 222 }
        let sampleBRow = try #require(maybeSampleBRow)
        #expect(sampleBRow.bamPath == "bams/SAMPLE_B.bam")
        #expect(sampleBRow.bamIndexPath == "bams/SAMPLE_B.bam.bai")

        #expect(try db.referenceLength(forAccession: "ACC_SHARED") == 150)

        let sampleAAccession = try #require(try db.fetchAccessionSummaries(sample: "SAMPLE_A", taxId: 111).first)
        #expect(sampleAAccession.referenceLength == 150)
        #expect(sampleAAccession.coveredBasePairs == 8)
        #expect(sampleAAccession.coverageFraction == 8.0 / 150.0)

        let sampleBAccession = try #require(try db.fetchAccessionSummaries(sample: "SAMPLE_B", taxId: 222).first)
        #expect(sampleBAccession.referenceLength == 150)
        #expect(sampleBAccession.coveredBasePairs == 8)
        #expect(sampleBAccession.coverageFraction == 8.0 / 150.0)
    }

    @Test
    func mergedDatabaseThrowsWhenStageInputSampleHasNoRows() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-merge-missing-sample-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sampleDatabaseURL = workspace.appendingPathComponent("sample.sqlite")
        let mergedDatabaseURL = workspace.appendingPathComponent("merged.sqlite")

        try await createSyntheticNaoMgsStageDatabase(
            at: sampleDatabaseURL,
            sample: "SAMPLE_A",
            taxId: 111,
            accession: "ACC_ONLY",
            referenceLength: 80
        )

        #expect(throws: Error.self) {
            try NaoMgsDatabase.createMergedSummaryDatabase(at: mergedDatabaseURL, from: [
                .init(
                    sample: "WRONG_SAMPLE",
                    databaseURL: sampleDatabaseURL,
                    bamRelativePath: "bams/WRONG_SAMPLE.bam",
                    bamIndexRelativePath: "bams/WRONG_SAMPLE.bam.bai"
                )
            ])
        }
    }

    // MARK: - R2-Only Row Handling

    @Test
    func importR2OnlyRowProducesBamRecord() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-r2only-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Row where R1 is NA (only R2 has data)
        let tsvContent = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_seq_rev\tquery_qual\tquery_qual_rev\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_ref_start_rev\tprim_align_edit_distance\tprim_align_edit_distance_rev\tquery_len\tquery_len_rev\tprim_align_query_rc\tprim_align_query_rc_rev\tprim_align_pair_status\tprim_align_best_alignment_score\tprim_align_best_alignment_score_rev\tprim_align_fragment_length
        SAMPLE_R2\tread_r2only\t999\tNA\tGGCCTTAAGG\tNA\tIIIIIIIIII\tACC_X\tNA\t100\tNA\t1\tNA\t10\tNA\tFalse\tUP\tNA\t95\t0
        SAMPLE_R2\tread_both\t999\tACGTACGT\tTTGGCCTT\tIIIIIIII\tJJJJJJJJ\tACC_X\t50\t80\t0\t0\t8\t8\tFalse\tTrue\tCP\t100\t99\t200
        SAMPLE_R2\tread_r1only\t999\tAAAACCCC\tNA\tFFFFFFFF\tNA\tACC_X\t200\tNA\t0\tNA\t8\tNA\tFalse\tNA\tUP\t90\tNA\t0
        """
        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try tsvContent.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("analyses", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "R2ONLY_TEST",
            fetchReferences: false
        )

        // All 3 rows should be imported (including the R2-only row)
        #expect(result.totalHitReads == 3)

        // Verify taxon summaries count alignments, while public totalHitCount remains row-based.
        let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))
        let summaries = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(summaries.count == 1, "Single taxon (999)")
        #expect(summaries[0].hitCount == 4)
        #expect(try db.totalHitCount(samples: nil) == 3)

        // Verify BAMs: 1 paired read (2 SAM records) + 2 singles = 4 total
        if let samtoolsPath = SamtoolsLocator.locate() {
            let bamsDir = result.resultDirectory.appendingPathComponent("bams")
            let bamFiles = try FileManager.default.contentsOfDirectory(at: bamsDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bam" }
            #expect(!bamFiles.isEmpty)

            var totalRecords = 0
            for bam in bamFiles {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: samtoolsPath)
                proc.arguments = ["view", "-c", bam.path]
                let pipe = Pipe()
                proc.standardOutput = pipe
                try proc.run()
                proc.waitUntilExit()
                let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                totalRecords += Int(str ?? "0") ?? 0
            }

            // 1 paired (2 records) + 1 R1-only (1 record) + 1 R2-only (1 record) = 4
            #expect(totalRecords == 4, "Expected 4 BAM records (1 pair + 2 singles), got \(totalRecords)")
        }
    }

    // MARK: - Streaming Accumulator Correctness

    @Test
    func streamingAccumulatorsMatchExpectedSummaryValues() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-accumulator-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Controlled data: 2 taxa, known duplicates
        let tsvContent = """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status
        SAMPLE_A\tread1\t100\tACGTACGT\tIIIIIIII\tACC_A\t10\t0\t8\tFalse\tUP
        SAMPLE_A\tread2\t100\tACGTACGT\tIIIIIIII\tACC_A\t10\t0\t8\tFalse\tUP
        SAMPLE_A\tread3\t100\tACGTACGA\tIIIIIIII\tACC_B\t30\t1\t8\tTrue\tUP
        SAMPLE_A\tread4\t200\tGGCCTTAA\tIIIIIIII\tACC_C\t50\t2\t8\tFalse\tUP
        """
        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try tsvContent.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("analyses", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "ACCUM_TEST",
            fetchReferences: false
        )

        #expect(result.totalHitReads == 4)
        #expect(result.taxonCount == 2)

        let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))
        let rows = try db.fetchTaxonSummaryRows(samples: nil)

        // Taxon 100: 3 hits, 2 unique (read1 and read2 are duplicates — same accession+position+strand+length)
        let taxon100 = try #require(rows.first(where: { $0.taxId == 100 }))
        #expect(taxon100.hitCount == 3)
        #expect(taxon100.uniqueReadCount == 2, "read1 and read2 are PCR duplicates (same alignment signature)")
        #expect(taxon100.pcrDuplicateCount == 1)
        #expect(taxon100.accessionCount == 2, "Two accessions: ACC_A and ACC_B")

        // Taxon 200: 1 hit, 1 unique
        let taxon200 = try #require(rows.first(where: { $0.taxId == 200 }))
        #expect(taxon200.hitCount == 1)
        #expect(taxon200.uniqueReadCount == 1)
        #expect(taxon200.pcrDuplicateCount == 0)
        #expect(taxon200.accessionCount == 1)

        // Verify accession summaries for taxon 100
        let accSummaries = try db.fetchAccessionSummaries(sample: "SAMPLE_A", taxId: 100)
        #expect(accSummaries.count == 2)
        let accA = try #require(accSummaries.first(where: { $0.accession == "ACC_A" }))
        #expect(accA.readCount == 2, "ACC_A has 2 total reads")
        #expect(accA.uniqueReadCount == 1, "Both reads are duplicates")
        let accB = try #require(accSummaries.first(where: { $0.accession == "ACC_B" }))
        #expect(accB.readCount == 1)
        #expect(accB.uniqueReadCount == 1)
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
            _ = try await importNaoMgsForTesting(
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

    // MARK: - Partitioning

    @Test
    func partitionerSplitsMonolithicTSVByNormalizedSample() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("virus_hits_final.tsv")
        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status"
        let content = """
        \(header)
        SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP
        SAMPLE_A_S1_L002\tread2\t111\tACGT\tIIII\tACC1\t20\t0\t4\tFalse\tCP
        SAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP
        """
        try content.write(to: source, atomically: true, encoding: .utf8)

        let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
        let result = try NaoMgsSamplePartitioner.partition(
            inputURLs: [source],
            outputDirectory: outputDir
        )

        #expect(result.sampleFiles.count == 2)
        #expect(result.sampleFiles.keys.contains("SAMPLE_A"))
        #expect(result.sampleFiles.keys.contains("SAMPLE_B"))
        #expect(result.totalRows == 3)

        let sampleA = try String(contentsOf: result.sampleFiles["SAMPLE_A"]!)
        let sampleALines = sampleA.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(sampleALines.count == 4)
        #expect(String(sampleALines[0]) == header)
        #expect(String(sampleALines[1]).contains("read1"))
        #expect(String(sampleALines[2]).contains("read2"))
        #expect(!sampleA.contains("read3"))

        let sampleB = try String(contentsOf: result.sampleFiles["SAMPLE_B"]!)
        let sampleBLines = sampleB.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(sampleBLines.count == 3)
        #expect(String(sampleBLines[0]) == header)
        #expect(String(sampleBLines[1]) == "SAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP")
    }

    @Test
    func partitionerCoalescesOneSampleAcrossMultipleInputTSVs() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-multi-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputDir = workspace.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status\n"
        try (header + "SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP\n")
            .write(to: inputDir.appendingPathComponent("part1.tsv"), atomically: true, encoding: .utf8)
        try (header + "SAMPLE_A_S1_L002\tread2\t111\tACGT\tIIII\tACC1\t20\t0\t4\tFalse\tCP\nSAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP\n")
            .write(to: inputDir.appendingPathComponent("part2.tsv"), atomically: true, encoding: .utf8)

        let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
        let result = try NaoMgsSamplePartitioner.partition(
            inputURLs: [
                inputDir.appendingPathComponent("part1.tsv"),
                inputDir.appendingPathComponent("part2.tsv"),
            ],
            outputDirectory: outputDir
        )

        let sampleA = try String(contentsOf: result.sampleFiles["SAMPLE_A"]!)
        let sampleALines = sampleA.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(result.totalRows == 3)
        #expect(sampleALines.count == 4)
        #expect(String(sampleALines[0]) == header.trimmingCharacters(in: .newlines))
        #expect(String(sampleALines[1]).contains("read1"))
        #expect(String(sampleALines[2]).contains("read2"))

        let sampleB = try String(contentsOf: result.sampleFiles["SAMPLE_B"]!)
        let sampleBLines = sampleB.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(sampleBLines.count == 3)
        #expect(String(sampleBLines[0]) == header.trimmingCharacters(in: .newlines))
        #expect(String(sampleBLines[1]) == "SAMPLE_B_S2_L001\tread3\t222\tTGCA\tIIII\tACC2\t30\t1\t4\tTrue\tUP")
    }

    @Test
    func partitionerSanitizesFilenamesAndTruncatesExistingOutputsOnRerun() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-rerun-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = workspace.appendingPathComponent("virus_hits_final.tsv")
        let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status"

        try """
        \(header)
        SAMPLE/WEIRD:NAME_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP
        """.write(to: input, atomically: true, encoding: .utf8)

        let first = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input],
            outputDirectory: outputDir
        )

        let logicalSample = "SAMPLE/WEIRD:NAME"
        let firstURL = try #require(first.sampleFiles[logicalSample])
        #expect(firstURL.lastPathComponent != "\(logicalSample).tsv")
        #expect(!firstURL.lastPathComponent.contains("/"))
        #expect(!firstURL.lastPathComponent.contains(":"))

        try """
        \(header)
        SAMPLE/WEIRD:NAME_S1_L001\tread2\t111\tTGCA\tIIII\tACC1\t20\t0\t4\tFalse\tCP
        """.write(to: input, atomically: true, encoding: .utf8)

        let second = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input],
            outputDirectory: outputDir
        )

        let secondURL = try #require(second.sampleFiles[logicalSample])
        #expect(firstURL == secondURL, "Filename should be deterministic across reruns")

        let rerunContent = try String(contentsOf: secondURL)
        #expect(rerunContent.contains("read2"))
        #expect(!rerunContent.contains("read1"), "Rerun should not leave stale tail data in existing partition files")
    }

    @Test
    func partitionerRemovesStaleSampleFilesBeforeRerun() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-stale-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let input = workspace.appendingPathComponent("virus_hits_final.tsv")
        let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)
        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status"

        try """
        \(header)
        SAMPLE_A_S1_L001\tread1\t111\tACGT\tIIII\tACC1\t10\t0\t4\tFalse\tCP
        SAMPLE_B_S2_L001\tread2\t222\tTGCA\tIIII\tACC2\t20\t0\t4\tFalse\tUP
        """.write(to: input, atomically: true, encoding: .utf8)

        let first = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input],
            outputDirectory: outputDir
        )

        let sampleBURL = try #require(first.sampleFiles["SAMPLE_B"])
        #expect(FileManager.default.fileExists(atPath: sampleBURL.path))

        try """
        \(header)
        SAMPLE_A_S1_L001\tread3\t111\tCCCC\tIIII\tACC1\t30\t0\t4\tFalse\tCP
        """.write(to: input, atomically: true, encoding: .utf8)

        let second = try NaoMgsSamplePartitioner.partition(
            inputURLs: [input],
            outputDirectory: outputDir
        )

        #expect(second.sampleFiles["SAMPLE_B"] == nil)
        #expect(!FileManager.default.fileExists(atPath: sampleBURL.path),
            "Partition rerun should remove stale files for samples no longer present")
    }

    @Test
    func partitionerThrowsOnCorruptedGzipInput() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-partition-corrupt-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let source = workspace.appendingPathComponent("virus_hits_final.tsv.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00, 0xff, 0xff, 0x00, 0x00, 0x62, 0x61, 0x64])
            .write(to: source)

        let outputDir = workspace.appendingPathComponent("partitioned", isDirectory: true)

        #expect(throws: Error.self) {
            _ = try NaoMgsSamplePartitioner.partition(
                inputURLs: [source],
                outputDirectory: outputDir
            )
        }
    }

    // MARK: - Staged Import Pipeline (Task 4)

    @Test
    func importNaoMgsDirectoryWithSplitSampleFilesProducesSingleMergedBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-directory-import-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputDir = workspace.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let header = "sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status\n"
        try (header + "SAMPLE_A_S1_L001\tread1\t111\tACGTACGT\tIIIIIIII\tACC1\t10\t0\t8\tFalse\tCP\n")
            .write(to: inputDir.appendingPathComponent("lane1_virus_hits.tsv"), atomically: true, encoding: .utf8)
        try (header + "SAMPLE_A_S1_L002\tread2\t111\tACGTACGA\tIIIIIIII\tACC1\t20\t1\t8\tFalse\tCP\nSAMPLE_B_S2_L001\tread3\t222\tTGCAACGT\tIIIIIIII\tACC2\t30\t1\t8\tTrue\tUP\n")
            .write(to: inputDir.appendingPathComponent("lane2_virus_hits.tsv"), atomically: true, encoding: .utf8)

        let outputDir = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: inputDir,
            outputDirectory: outputDir,
            fetchReferences: false
        )

        let db = try NaoMgsDatabase(at: result.resultDirectory.appendingPathComponent("hits.sqlite"))
        let rows = try db.fetchTaxonSummaryRows(samples: nil)
        #expect(rows.count == 2, "Expected 2 taxon rows (one per sample×taxon), got \(rows.count)")

        let sampleARow = rows.first { $0.sample == "SAMPLE_A" && $0.taxId == 111 }
        #expect(sampleARow != nil, "SAMPLE_A taxon 111 should exist")
        #expect(sampleARow?.hitCount == 2, "SAMPLE_A should have 2 hits coalesced from lane1+lane2")

        let sampleBRow = rows.first { $0.sample == "SAMPLE_B" && $0.taxId == 222 }
        #expect(sampleBRow != nil, "SAMPLE_B taxon 222 should exist")
        #expect(sampleBRow?.hitCount == 1, "SAMPLE_B should have 1 hit")
    }

    // MARK: - Post-Merge Cleanup (Task 5)

    @Test
    func importNaoMgsRemovesStagingDirectoryOnSuccess() async throws {
        let workspace = makeTemporaryDirectory(prefix: "naomgs-cleanup-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputDir = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await importNaoMgsForTesting(
            inputURL: TestFixtures.naomgs.virusHitsTsvGz,
            outputDirectory: outputDir,
            fetchReferences: false
        )

        let staging = result.resultDirectory.appendingPathComponent(".naomgs-import-staging")
        #expect(!FileManager.default.fileExists(atPath: staging.path),
            "Staging directory should be removed after successful import")
    }
}

private func createSyntheticNaoMgsStageDatabase(
    at databaseURL: URL,
    sample: String,
    taxId: Int,
    accession: String,
    referenceLength: Int
) async throws {
    let workspace = databaseURL.deletingLastPathComponent()
    let sourceURL = workspace.appendingPathComponent("\(sample)-stage.tsv")
    let sequence = "ACGTACGT"

    let tsvContent = """
    sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_edit_distance\tquery_len\tprim_align_query_rc\tprim_align_pair_status\tprim_align_subject_title
    \(sample)\t\(sample.lowercased())_read1\t\(taxId)\t\(sequence)\tIIIIIIII\t\(accession)\t5\t0\t8\tFalse\tCP\tSynthetic \(accession)
    """
    try tsvContent.write(to: sourceURL, atomically: true, encoding: .utf8)

    _ = try await NaoMgsDatabase.createStreaming(
        at: databaseURL,
        from: [sourceURL],
        sampleNameOverride: sample
    )

    let db = try NaoMgsDatabase.openReadWrite(at: databaseURL)
    try db.updateReferenceLengths([accession: referenceLength])
    try db.refreshAccessionSummaryReferenceLengths()
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func importNaoMgsForTesting(
    inputURL: URL,
    outputDirectory: URL,
    sampleName: String? = nil,
    minIdentity: Double = 0,
    fetchReferences: Bool = true,
    preferredName: String? = nil,
    progress: (@Sendable (Double, String) -> Void)? = nil
) async throws -> NaoMgsImportResult {
    try await withNaoMgsImportLock {
        try await MetagenomicsImportService.importNaoMgs(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            sampleName: sampleName,
            minIdentity: minIdentity,
            fetchReferences: fetchReferences,
            preferredName: preferredName,
            progress: progress
        )
    }
}

private func withNaoMgsImportLock<T>(_ body: () async throws -> T) async throws -> T {
    let lockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("lungfish-naomgs-import-tests.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    guard flock(descriptor, LOCK_EX) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(descriptor, LOCK_UN) }

    return try await body()
}
