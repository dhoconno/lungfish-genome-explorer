// BundlePipelineTests.swift - Integration tests for NCBI genome pipeline and bundle loading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Integration tests for the NCBI genome download pipeline and reference bundle
/// construction logic.
///
/// These tests exercise the local/model-level logic involved in:
/// - Constructing GFF3 annotation URLs from assembly summaries
/// - Building `NCBIAssemblySummary` instances with various field combinations
/// - Creating `BuildConfiguration` instances from assembly metadata
/// - Verifying `AnnotationInput`, `VariantInput`, `SignalInput`, and `SourceInfo` models
///
/// **No network calls are made.** The NCBI URL-construction logic is tested by
/// decoding synthetic JSON into `NCBIAssemblySummary` and verifying the URLs
/// that `getAnnotationFileInfo` / `getGenomeFileInfo` would derive.
@MainActor
final class BundlePipelineTests: XCTestCase {

    // MARK: - Test Lifecycle

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishBundlePipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Decodes an `NCBIAssemblySummary` from a dictionary of field values.
    ///
    /// `NCBIAssemblySummary` only exposes `init(from:)`, so we construct
    /// instances by round-tripping through JSON serialization.
    private func makeAssemblySummary(
        uid: String = "12345",
        assemblyAccession: String? = "GCF_000001405.40",
        assemblyName: String? = "GRCh38.p14",
        organism: String? = "Homo sapiens",
        taxid: Int? = 9606,
        speciesName: String? = "Homo sapiens",
        ftpPathRefSeq: String? = nil,
        ftpPathGenBank: String? = nil,
        submitter: String? = "Genome Reference Consortium",
        coverage: String? = "56.0",
        contigN50: Int? = 57_879_411,
        scaffoldN50: Int? = 67_794_873
    ) throws -> NCBIAssemblySummary {
        var dict: [String: Any] = ["uid": uid]
        if let v = assemblyAccession { dict["assemblyaccession"] = v }
        if let v = assemblyName { dict["assemblyname"] = v }
        if let v = organism { dict["organism"] = v }
        if let v = taxid { dict["taxid"] = v }
        if let v = speciesName { dict["speciesname"] = v }
        if let v = ftpPathRefSeq { dict["ftppath_refseq"] = v }
        if let v = ftpPathGenBank { dict["ftppath_genbank"] = v }
        if let v = submitter { dict["submitter"] = v }
        if let v = coverage { dict["coverage"] = v }
        if let v = contigN50 { dict["contig_n50"] = v }
        if let v = scaffoldN50 { dict["scaffold_n50"] = v }

        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(NCBIAssemblySummary.self, from: jsonData)
    }

    /// Replicates the GFF3 URL construction logic from `NCBIService.getAnnotationFileInfo`
    /// without making any network calls.
    ///
    /// - Parameter summary: The assembly summary to derive URLs from.
    /// - Returns: The constructed GFF3 URL, or `nil` if FTP paths are missing.
    private func deriveGFF3URL(from summary: NCBIAssemblySummary) -> URL? {
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank else {
            return nil
        }

        let pathComponents = ftpPath.components(separatedBy: "/")
        guard let assemblyDirName = pathComponents.last, !assemblyDirName.isEmpty else {
            return nil
        }

        let gffFilename = "\(assemblyDirName)_genomic.gff.gz"

        var httpPath = ftpPath
        if httpPath.hasPrefix("ftp://") {
            httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
        } else if !httpPath.hasPrefix("https://") && !httpPath.hasPrefix("http://") {
            httpPath = "https://\(httpPath)"
        }

        let fileURLString = "\(httpPath)/\(gffFilename)"
        return URL(string: fileURLString)
    }

    /// Replicates the FASTA URL construction logic from `NCBIService.getGenomeFileInfo`
    /// without making any network calls.
    ///
    /// - Parameter summary: The assembly summary to derive URLs from.
    /// - Returns: The constructed FASTA URL, or `nil` if FTP paths are missing.
    private func deriveFASTAURL(from summary: NCBIAssemblySummary) -> URL? {
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank else {
            return nil
        }

        let pathComponents = ftpPath.components(separatedBy: "/")
        guard let assemblyDirName = pathComponents.last, !assemblyDirName.isEmpty else {
            return nil
        }

        let fastaFilename = "\(assemblyDirName)_genomic.fna.gz"

        var httpPath = ftpPath
        if httpPath.hasPrefix("ftp://") {
            httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
        } else if !httpPath.hasPrefix("https://") && !httpPath.hasPrefix("http://") {
            httpPath = "https://\(httpPath)"
        }

        let fileURLString = "\(httpPath)/\(fastaFilename)"
        return URL(string: fileURLString)
    }

    // MARK: - 1. NCBIAssemblySummary Construction Tests

    /// Verifies that an assembly summary can be decoded with all fields populated.
    func testAssemblySummaryWithAllFields() throws {
        let summary = try makeAssemblySummary(
            uid: "99999",
            assemblyAccession: "GCF_000002985.6",
            assemblyName: "WBcel235",
            organism: "Caenorhabditis elegans",
            taxid: 6239,
            speciesName: "Caenorhabditis elegans",
            ftpPathRefSeq: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235",
            ftpPathGenBank: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/002/985/GCA_000002985.3_WBcel235",
            submitter: "WormBase",
            coverage: "9.0",
            contigN50: 17_493_829,
            scaffoldN50: 17_493_829
        )

        XCTAssertEqual(summary.uid, "99999")
        XCTAssertEqual(summary.assemblyAccession, "GCF_000002985.6")
        XCTAssertEqual(summary.assemblyName, "WBcel235")
        XCTAssertEqual(summary.organism, "Caenorhabditis elegans")
        XCTAssertEqual(summary.taxid, 6239)
        XCTAssertEqual(summary.speciesName, "Caenorhabditis elegans")
        XCTAssertEqual(summary.ftpPathRefSeq,
                       "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235")
        XCTAssertEqual(summary.ftpPathGenBank,
                       "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/002/985/GCA_000002985.3_WBcel235")
        XCTAssertEqual(summary.submitter, "WormBase")
        XCTAssertEqual(summary.coverage, "9.0")
        XCTAssertEqual(summary.contigN50, 17_493_829)
        XCTAssertEqual(summary.scaffoldN50, 17_493_829)
    }

    /// Verifies that an assembly summary handles missing optional fields gracefully.
    func testAssemblySummaryWithMinimalFields() throws {
        let summary = try makeAssemblySummary(
            uid: "11111",
            assemblyAccession: nil,
            assemblyName: nil,
            organism: nil,
            taxid: nil,
            speciesName: nil,
            ftpPathRefSeq: nil,
            ftpPathGenBank: nil,
            submitter: nil,
            coverage: nil,
            contigN50: nil,
            scaffoldN50: nil
        )

        XCTAssertEqual(summary.uid, "11111")
        XCTAssertNil(summary.assemblyAccession)
        XCTAssertNil(summary.assemblyName)
        XCTAssertNil(summary.organism)
        XCTAssertNil(summary.taxid)
        XCTAssertNil(summary.speciesName)
        XCTAssertNil(summary.ftpPathRefSeq)
        XCTAssertNil(summary.ftpPathGenBank)
        XCTAssertNil(summary.submitter)
        XCTAssertNil(summary.coverage)
        XCTAssertNil(summary.contigN50)
        XCTAssertNil(summary.scaffoldN50)
    }

    /// Verifies that taxid encoded as a String (common in NCBI JSON responses)
    /// is correctly decoded to an Int.
    func testAssemblySummaryTaxidAsString() throws {
        let json: [String: Any] = [
            "uid": "55555",
            "taxid": "9606"  // String instead of Int
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let summary = try JSONDecoder().decode(NCBIAssemblySummary.self, from: data)

        XCTAssertEqual(summary.taxid, 9606,
                       "taxid should be decoded from String representation")
    }

    /// Verifies that contig_n50 encoded as a String is correctly decoded to Int.
    func testAssemblySummaryContigN50AsString() throws {
        let json: [String: Any] = [
            "uid": "77777",
            "contig_n50": "12345678",
            "scaffold_n50": "87654321"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let summary = try JSONDecoder().decode(NCBIAssemblySummary.self, from: data)

        XCTAssertEqual(summary.contigN50, 12_345_678)
        XCTAssertEqual(summary.scaffoldN50, 87_654_321)
    }

    /// Verifies that a summary with only a GenBank FTP path (no RefSeq) can
    /// still be created successfully.
    func testAssemblySummaryGenBankOnlyPath() throws {
        let summary = try makeAssemblySummary(
            ftpPathRefSeq: nil,
            ftpPathGenBank: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.29_GRCh38.p14"
        )

        XCTAssertNil(summary.ftpPathRefSeq)
        XCTAssertNotNil(summary.ftpPathGenBank)
    }

    // MARK: - 2. Annotation URL Construction Tests

    /// Verifies that `getAnnotationFileInfo` constructs the correct GFF3 filename
    /// from a RefSeq FTP path.
    ///
    /// The expected pattern is `{ftpPath}/{assemblyDirName}_genomic.gff.gz`.
    /// This test exercises the URL construction logic only -- it does not make
    /// network calls. We replicate the same algorithm used by `NCBIService` and
    /// verify the derived URL components against known values.
    func testAnnotationGFF3URLConstructionFromRefSeqPath() throws {
        let summary = try makeAssemblySummary(
            assemblyAccession: "GCF_000002985.6",
            ftpPathRefSeq: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235"
        )

        let gff3URL = deriveGFF3URL(from: summary)

        XCTAssertNotNil(gff3URL, "GFF3 URL should be constructable from RefSeq path")
        XCTAssertEqual(
            gff3URL?.absoluteString,
            "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235/GCF_000002985.6_WBcel235_genomic.gff.gz"
        )
        XCTAssertEqual(gff3URL?.pathExtension, "gz")
        XCTAssertTrue(gff3URL?.lastPathComponent.hasSuffix("_genomic.gff.gz") == true)
    }

    /// Verifies that the GenBank path is used as a fallback when RefSeq path is nil.
    func testAnnotationURLFallsBackToGenBankPath() throws {
        let summary = try makeAssemblySummary(
            ftpPathRefSeq: nil,
            ftpPathGenBank: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.29_GRCh38.p14"
        )

        let gff3URL = deriveGFF3URL(from: summary)
        XCTAssertNotNil(gff3URL, "Should fall back to GenBank path when RefSeq is nil")
        XCTAssertTrue(gff3URL!.lastPathComponent.hasPrefix("GCA_"),
                       "URL should be derived from GenBank path (GCA prefix)")
        XCTAssertEqual(gff3URL!.lastPathComponent, "GCA_000001405.29_GRCh38.p14_genomic.gff.gz")
    }

    /// Verifies that when both FTP paths are nil, no URL can be constructed.
    func testAnnotationURLReturnsNilWithNoFTPPaths() throws {
        let summary = try makeAssemblySummary(
            ftpPathRefSeq: nil,
            ftpPathGenBank: nil
        )

        let gff3URL = deriveGFF3URL(from: summary)
        XCTAssertNil(gff3URL,
                     "Should return nil when both FTP paths are missing")
    }

    /// Verifies the FTP-to-HTTPS conversion for various URL formats.
    func testFTPToHTTPSConversion() {
        // Standard ftp:// prefix
        let ftpURL = "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        var httpPath = ftpURL
        if httpPath.hasPrefix("ftp://") {
            httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
        }
        XCTAssertTrue(httpPath.hasPrefix("https://"))
        XCTAssertFalse(httpPath.contains("ftp://"))
        XCTAssertEqual(
            httpPath,
            "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        )

        // Already https://
        let httpsURL = "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        var httpPath2 = httpsURL
        if httpPath2.hasPrefix("ftp://") {
            httpPath2 = httpPath2.replacingOccurrences(of: "ftp://", with: "https://")
        }
        XCTAssertEqual(httpPath2, httpsURL, "Already-HTTPS URLs should not be modified")

        // Bare hostname (no scheme)
        let barePath = "ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        var httpPath3 = barePath
        if httpPath3.hasPrefix("ftp://") {
            httpPath3 = httpPath3.replacingOccurrences(of: "ftp://", with: "https://")
        } else if !httpPath3.hasPrefix("https://") && !httpPath3.hasPrefix("http://") {
            httpPath3 = "https://\(httpPath3)"
        }
        XCTAssertTrue(httpPath3.hasPrefix("https://"),
                       "Bare paths should get https:// prepended")
    }

    /// Verifies that the FASTA and GFF3 URL construction produces files in the
    /// same directory, following the NCBI convention.
    func testGenomeFASTAAndGFF3URLShareDirectory() throws {
        let summary = try makeAssemblySummary(
            assemblyAccession: "GCF_000001405.40",
            ftpPathRefSeq: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        )

        let fastaURL = deriveFASTAURL(from: summary)
        let gff3URL = deriveGFF3URL(from: summary)

        XCTAssertNotNil(fastaURL)
        XCTAssertNotNil(gff3URL)

        XCTAssertEqual(fastaURL!.lastPathComponent, "GCF_000001405.40_GRCh38.p14_genomic.fna.gz")
        XCTAssertEqual(gff3URL!.lastPathComponent, "GCF_000001405.40_GRCh38.p14_genomic.gff.gz")

        // Both files should be in the same directory
        XCTAssertEqual(fastaURL?.deletingLastPathComponent(), gff3URL?.deletingLastPathComponent())
    }

    /// Verifies RefSeq path takes priority over GenBank path.
    func testRefSeqPathPreference() throws {
        let refseqPath = "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14"
        let genbankPath = "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.29_GRCh38.p14"

        let summary = try makeAssemblySummary(
            ftpPathRefSeq: refseqPath,
            ftpPathGenBank: genbankPath
        )

        let selectedPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank
        XCTAssertEqual(selectedPath, refseqPath,
                       "RefSeq path should be preferred over GenBank path")

        // The derived URL should use the RefSeq path (GCF prefix)
        let gff3URL = deriveGFF3URL(from: summary)
        XCTAssertNotNil(gff3URL)
        XCTAssertTrue(gff3URL!.lastPathComponent.hasPrefix("GCF_"),
                       "Derived URL should use RefSeq (GCF) path")
    }

    // MARK: - 3. BuildConfiguration Construction Tests

    /// Verifies creating a minimal BuildConfiguration with only required fields.
    func testBuildConfigurationMinimal() {
        let fastaURL = tempDirectory.appendingPathComponent("genome.fa")
        let outputDir = tempDirectory.appendingPathComponent("output")
        let source = SourceInfo(organism: "Test organism", assembly: "TestAssembly1.0")

        let config = BuildConfiguration(
            name: "Test Genome",
            identifier: "org.lungfish.test.genome",
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: source
        )

        XCTAssertEqual(config.name, "Test Genome")
        XCTAssertEqual(config.identifier, "org.lungfish.test.genome")
        XCTAssertEqual(config.fastaURL, fastaURL)
        XCTAssertEqual(config.outputDirectory, outputDir)
        XCTAssertTrue(config.annotationFiles.isEmpty)
        XCTAssertTrue(config.variantFiles.isEmpty)
        XCTAssertTrue(config.signalFiles.isEmpty)
        XCTAssertTrue(config.compressFASTA, "Default compressFASTA should be true")
        XCTAssertEqual(config.source.organism, "Test organism")
        XCTAssertEqual(config.source.assembly, "TestAssembly1.0")
    }

    /// Verifies creating a BuildConfiguration with all optional fields populated,
    /// including annotation, variant, and signal inputs.
    func testBuildConfigurationWithAllInputTypes() {
        let fastaURL = tempDirectory.appendingPathComponent("genome.fa")
        let gff3URL = tempDirectory.appendingPathComponent("genes.gff3")
        let vcfURL = tempDirectory.appendingPathComponent("variants.vcf")
        let bigwigURL = tempDirectory.appendingPathComponent("coverage.bw")
        let outputDir = tempDirectory.appendingPathComponent("output")

        let source = SourceInfo(
            organism: "Homo sapiens",
            commonName: "Human",
            taxonomyId: 9606,
            assembly: "GRCh38",
            assemblyAccession: "GCF_000001405.40",
            database: "NCBI"
        )

        let annotations = [
            AnnotationInput(
                url: gff3URL,
                name: "NCBI RefSeq Genes",
                description: "Gene annotations from NCBI RefSeq",
                id: "refseq_genes",
                annotationType: .gene
            )
        ]

        let variants = [
            VariantInput(
                url: vcfURL,
                name: "dbSNP Common",
                description: "Common variants from dbSNP",
                id: "dbsnp_common",
                variantType: .snp
            )
        ]

        let signals = [
            SignalInput(
                url: bigwigURL,
                name: "Read Coverage",
                description: "Sequencing depth",
                id: "coverage",
                signalType: .coverage
            )
        ]

        let config = BuildConfiguration(
            name: "Human GRCh38",
            identifier: "org.lungfish.hg38",
            fastaURL: fastaURL,
            annotationFiles: annotations,
            variantFiles: variants,
            signalFiles: signals,
            outputDirectory: outputDir,
            source: source,
            compressFASTA: false
        )

        XCTAssertEqual(config.name, "Human GRCh38")
        XCTAssertEqual(config.identifier, "org.lungfish.hg38")
        XCTAssertFalse(config.compressFASTA)

        XCTAssertEqual(config.annotationFiles.count, 1)
        XCTAssertEqual(config.annotationFiles[0].name, "NCBI RefSeq Genes")
        XCTAssertEqual(config.annotationFiles[0].id, "refseq_genes")
        XCTAssertEqual(config.annotationFiles[0].annotationType, .gene)

        XCTAssertEqual(config.variantFiles.count, 1)
        XCTAssertEqual(config.variantFiles[0].name, "dbSNP Common")
        XCTAssertEqual(config.variantFiles[0].variantType, .snp)

        XCTAssertEqual(config.signalFiles.count, 1)
        XCTAssertEqual(config.signalFiles[0].name, "Read Coverage")
        XCTAssertEqual(config.signalFiles[0].signalType, .coverage)

        // Verify source info
        XCTAssertEqual(config.source.organism, "Homo sapiens")
        XCTAssertEqual(config.source.commonName, "Human")
        XCTAssertEqual(config.source.taxonomyId, 9606)
        XCTAssertEqual(config.source.assembly, "GRCh38")
        XCTAssertEqual(config.source.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(config.source.database, "NCBI")
    }

    /// Verifies that a BuildConfiguration can be created from NCBI assembly
    /// metadata, simulating the full download-to-build pipeline.
    func testBuildConfigurationFromAssemblyMetadata() throws {
        let summary = try makeAssemblySummary(
            assemblyAccession: "GCF_000002985.6",
            assemblyName: "WBcel235",
            organism: "Caenorhabditis elegans",
            taxid: 6239,
            speciesName: "Caenorhabditis elegans",
            ftpPathRefSeq: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235"
        )

        // Simulate what the app does: build a SourceInfo from the assembly summary
        let source = SourceInfo(
            organism: summary.organism ?? "Unknown",
            commonName: nil,
            taxonomyId: summary.taxid,
            assembly: summary.assemblyName ?? "Unknown",
            assemblyAccession: summary.assemblyAccession,
            database: "NCBI"
        )

        // Simulate building the identifier from the accession
        let identifier = "org.lungfish.ref.\(summary.assemblyAccession ?? summary.uid)"
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")

        let fastaURL = tempDirectory.appendingPathComponent("genome.fa")
        let outputDir = tempDirectory.appendingPathComponent("bundles")

        let config = BuildConfiguration(
            name: "\(summary.organism ?? "Unknown") - \(summary.assemblyName ?? "Unknown")",
            identifier: identifier,
            fastaURL: fastaURL,
            outputDirectory: outputDir,
            source: source
        )

        XCTAssertEqual(config.name, "Caenorhabditis elegans - WBcel235")
        XCTAssertEqual(config.identifier, "org-lungfish-ref-gcf_000002985-6")
        XCTAssertEqual(config.source.organism, "Caenorhabditis elegans")
        XCTAssertEqual(config.source.taxonomyId, 6239)
        XCTAssertEqual(config.source.assemblyAccession, "GCF_000002985.6")
        XCTAssertEqual(config.source.database, "NCBI")
    }

    /// Verifies bundle identifier formatting: lowercased, dots replaced with dashes.
    func testBundleIdentifierFormatting() {
        let testCases: [(input: String, expected: String)] = [
            ("GCF_000001405.40", "org-lungfish-ref-gcf_000001405-40"),
            ("GCA_000002985.3", "org-lungfish-ref-gca_000002985-3"),
            ("GCF_009858895.2", "org-lungfish-ref-gcf_009858895-2"),
        ]

        for (input, expected) in testCases {
            let identifier = "org.lungfish.ref.\(input)"
                .lowercased()
                .replacingOccurrences(of: ".", with: "-")
            XCTAssertEqual(identifier, expected,
                           "Identifier formatting failed for input '\(input)'")
        }
    }

    // MARK: - 4. AnnotationInput Tests

    /// Verifies that AnnotationInput auto-generates an ID from the filename
    /// when no explicit ID is provided.
    func testAnnotationInputAutoGeneratedID() {
        let url = tempDirectory.appendingPathComponent("NCBI RefSeq Genes.gff3")
        let input = AnnotationInput(url: url, name: "RefSeq Genes")

        XCTAssertEqual(input.id, "ncbi_refseq_genes",
                       "ID should be derived from filename: lowercased, spaces replaced with underscores")
        XCTAssertEqual(input.name, "RefSeq Genes")
        XCTAssertNil(input.description)
        XCTAssertEqual(input.annotationType, .custom,
                       "Default annotation type should be .custom")
    }

    /// Verifies that AnnotationInput uses an explicit ID when provided.
    func testAnnotationInputExplicitID() {
        let url = tempDirectory.appendingPathComponent("genes.gff3")
        let input = AnnotationInput(
            url: url,
            name: "Custom Genes",
            description: "My custom gene track",
            id: "my_custom_genes",
            annotationType: .gene
        )

        XCTAssertEqual(input.id, "my_custom_genes")
        XCTAssertEqual(input.name, "Custom Genes")
        XCTAssertEqual(input.description, "My custom gene track")
        XCTAssertEqual(input.annotationType, .gene)
        XCTAssertEqual(input.url, url)
    }

    /// Verifies all annotation track types can be specified.
    func testAnnotationInputAllTrackTypes() {
        let url = tempDirectory.appendingPathComponent("test.gff3")
        let types: [AnnotationTrackType] = [.gene, .transcript, .exon, .cds, .regulatory, .repeats, .conservation, .custom]

        for trackType in types {
            let input = AnnotationInput(url: url, name: "Track \(trackType.rawValue)", annotationType: trackType)
            XCTAssertEqual(input.annotationType, trackType,
                           "AnnotationInput should preserve track type \(trackType.rawValue)")
        }
    }

    // MARK: - 5. VariantInput Tests

    /// Verifies VariantInput auto-generates an ID from the filename.
    func testVariantInputAutoGeneratedID() {
        let url = tempDirectory.appendingPathComponent("dbSNP Common.vcf")
        let input = VariantInput(url: url, name: "dbSNP")

        XCTAssertEqual(input.id, "dbsnp_common",
                       "ID should be derived from filename: lowercased, spaces as underscores")
        XCTAssertEqual(input.name, "dbSNP")
        XCTAssertNil(input.description)
        XCTAssertEqual(input.variantType, .mixed,
                       "Default variant type should be .mixed")
    }

    /// Verifies VariantInput with explicit ID and all variant types.
    func testVariantInputAllTypes() {
        let url = tempDirectory.appendingPathComponent("test.vcf")
        let types: [VariantTrackType] = [.snp, .indel, .structural, .cnv, .mixed]

        for variantType in types {
            let input = VariantInput(
                url: url,
                name: "Variants",
                id: "track_\(variantType.rawValue)",
                variantType: variantType
            )
            XCTAssertEqual(input.variantType, variantType)
            XCTAssertEqual(input.id, "track_\(variantType.rawValue)")
        }
    }

    // MARK: - 6. SignalInput Tests

    /// Verifies SignalInput auto-generates an ID from the filename.
    func testSignalInputAutoGeneratedID() {
        let url = tempDirectory.appendingPathComponent("GC Content.bw")
        let input = SignalInput(url: url, name: "GC Content")

        XCTAssertEqual(input.id, "gc_content",
                       "ID should be derived from filename: lowercased, spaces as underscores")
        XCTAssertEqual(input.name, "GC Content")
        XCTAssertNil(input.description)
        XCTAssertEqual(input.signalType, .custom,
                       "Default signal type should be .custom")
    }

    /// Verifies all signal track types can be specified.
    func testSignalInputAllTypes() {
        let url = tempDirectory.appendingPathComponent("test.bw")
        let types: [SignalTrackType] = [.coverage, .gcContent, .conservation, .chipSeq, .atacSeq, .methylation, .custom]

        for signalType in types {
            let input = SignalInput(
                url: url,
                name: "Signal",
                id: "track_\(signalType.rawValue)",
                signalType: signalType
            )
            XCTAssertEqual(input.signalType, signalType)
        }
    }

    // MARK: - 7. SourceInfo Tests

    /// Verifies SourceInfo with all fields populated.
    func testSourceInfoFullConstruction() {
        let downloadDate = Date()
        let sourceURL = URL(string: "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/GCF_000001405.40_GRCh38.p14/")

        let source = SourceInfo(
            organism: "Homo sapiens",
            commonName: "Human",
            taxonomyId: 9606,
            assembly: "GRCh38.p14",
            assemblyAccession: "GCF_000001405.40",
            database: "NCBI",
            sourceURL: sourceURL,
            downloadDate: downloadDate,
            notes: "Primary reference assembly"
        )

        XCTAssertEqual(source.organism, "Homo sapiens")
        XCTAssertEqual(source.commonName, "Human")
        XCTAssertEqual(source.taxonomyId, 9606)
        XCTAssertEqual(source.assembly, "GRCh38.p14")
        XCTAssertEqual(source.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(source.database, "NCBI")
        XCTAssertEqual(source.sourceURL, sourceURL)
        XCTAssertEqual(source.downloadDate, downloadDate)
        XCTAssertEqual(source.notes, "Primary reference assembly")
    }

    /// Verifies SourceInfo with only required fields.
    func testSourceInfoMinimalConstruction() {
        let source = SourceInfo(
            organism: "Ebola virus",
            assembly: "ViralProj15199"
        )

        XCTAssertEqual(source.organism, "Ebola virus")
        XCTAssertEqual(source.assembly, "ViralProj15199")
        XCTAssertNil(source.commonName)
        XCTAssertNil(source.taxonomyId)
        XCTAssertNil(source.assemblyAccession)
        XCTAssertNil(source.database)
        XCTAssertNil(source.sourceURL)
        XCTAssertNil(source.downloadDate)
        XCTAssertNil(source.notes)
    }

    /// Verifies SourceInfo Codable round-trip through JSON.
    func testSourceInfoCodableRoundTrip() throws {
        let original = SourceInfo(
            organism: "Mus musculus",
            commonName: "Mouse",
            taxonomyId: 10090,
            assembly: "GRCm39",
            assemblyAccession: "GCF_000001635.27",
            database: "NCBI",
            notes: "Mouse reference genome"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SourceInfo.self, from: data)

        XCTAssertEqual(original, decoded,
                       "SourceInfo should survive JSON round-trip unchanged")
    }

    // MARK: - 8. GenomeFileInfo Tests

    /// Verifies that GenomeFileInfo captures the expected fields for a FASTA download.
    func testGenomeFileInfoConstruction() {
        let url = URL(string: "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/985/GCF_000002985.6_WBcel235/GCF_000002985.6_WBcel235_genomic.fna.gz")!
        let info = NCBIService.GenomeFileInfo(
            url: url,
            filename: "GCF_000002985.6_WBcel235_genomic.fna.gz",
            estimatedSize: 30_000_000,
            assemblyAccession: "GCF_000002985.6"
        )

        XCTAssertEqual(info.url, url)
        XCTAssertEqual(info.filename, "GCF_000002985.6_WBcel235_genomic.fna.gz")
        XCTAssertEqual(info.estimatedSize, 30_000_000)
        XCTAssertEqual(info.assemblyAccession, "GCF_000002985.6")
    }

    /// Verifies GenomeFileInfo with nil estimated size (when server does not
    /// provide Content-Length).
    func testGenomeFileInfoNilSize() {
        let url = URL(string: "https://example.com/genome.fna.gz")!
        let info = NCBIService.GenomeFileInfo(
            url: url,
            filename: "genome.fna.gz",
            estimatedSize: nil,
            assemblyAccession: "GCF_TEST"
        )

        XCTAssertNil(info.estimatedSize)
        XCTAssertEqual(info.assemblyAccession, "GCF_TEST")
    }

    // MARK: - 9. BundleManifest Integration with BuildConfiguration

    /// Verifies that a BundleManifest created from BuildConfiguration metadata
    /// can be saved and reloaded successfully.
    func testManifestFromBuildConfigurationMetadata() throws {
        // Simulate creating a manifest that would result from a build
        let source = SourceInfo(
            organism: "Drosophila melanogaster",
            commonName: "Fruit fly",
            taxonomyId: 7227,
            assembly: "Release_6_plus_ISO1_MT",
            assemblyAccession: "GCF_000001215.4",
            database: "NCBI"
        )

        let genome = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: "genome/sequence.fa.gz.gzi",
            totalLength: 143_726_002,
            chromosomes: [
                ChromosomeInfo(
                    name: "chr2L",
                    length: 23_513_712,
                    offset: 7,
                    lineBases: 70,
                    lineWidth: 71,
                    isPrimary: true
                ),
                ChromosomeInfo(
                    name: "chr2R",
                    length: 25_286_936,
                    offset: 23_849_423,
                    lineBases: 70,
                    lineWidth: 71,
                    isPrimary: true
                ),
                ChromosomeInfo(
                    name: "chrM",
                    length: 19_524,
                    offset: 143_700_000,
                    lineBases: 70,
                    lineWidth: 71,
                    isPrimary: false,
                    isMitochondrial: true
                ),
            ]
        )

        let annotationTrack = AnnotationTrackInfo(
            id: "ncbi_genes",
            name: "NCBI RefSeq Genes",
            description: "Gene annotations from NCBI RefSeq",
            path: "annotations/ncbi_genes.bb",
            annotationType: .gene,
            featureCount: 17_559,
            source: "NCBI",
            version: "Release 6"
        )

        let manifest = BundleManifest(
            name: "Drosophila melanogaster - Release_6_plus_ISO1_MT",
            identifier: "org-lungfish-ref-gcf_000001215-4",
            description: "Fruit fly reference genome from NCBI",
            source: source,
            genome: genome,
            annotations: [annotationTrack]
        )

        // Save and reload
        let bundleDir = tempDirectory.appendingPathComponent("dmel.lungfishref")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try manifest.save(to: bundleDir)
        let loaded = try BundleManifest.load(from: bundleDir)

        // Verify key fields survived
        XCTAssertEqual(loaded.name, "Drosophila melanogaster - Release_6_plus_ISO1_MT")
        XCTAssertEqual(loaded.identifier, "org-lungfish-ref-gcf_000001215-4")
        XCTAssertEqual(loaded.description, "Fruit fly reference genome from NCBI")
        XCTAssertEqual(loaded.source.organism, "Drosophila melanogaster")
        XCTAssertEqual(loaded.source.commonName, "Fruit fly")
        XCTAssertEqual(loaded.source.taxonomyId, 7227)
        XCTAssertEqual(loaded.source.assemblyAccession, "GCF_000001215.4")
        XCTAssertEqual(loaded.genome!.totalLength, 143_726_002)
        XCTAssertEqual(loaded.genome!.chromosomes.count, 3)
        XCTAssertEqual(loaded.genome!.chromosomes[2].isMitochondrial, true)
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(loaded.annotations[0].featureCount, 17_559)

        // Validate
        let errors = loaded.validate()
        XCTAssertTrue(errors.isEmpty,
                       "Manifest should pass validation, got: \(errors)")
    }

    // MARK: - 10. NCBIDatabase and NCBIFormat Enums

    /// Verifies the NCBI database enum raw values and computed properties.
    func testNCBIDatabaseProperties() {
        XCTAssertEqual(NCBIDatabase.nucleotide.rawValue, "nucleotide")
        XCTAssertEqual(NCBIDatabase.assembly.rawValue, "assembly")
        XCTAssertEqual(NCBIDatabase.genome.rawValue, "genome")

        // Databases that support efetch
        XCTAssertTrue(NCBIDatabase.nucleotide.supportsEfetch)
        XCTAssertTrue(NCBIDatabase.protein.supportsEfetch)
        XCTAssertTrue(NCBIDatabase.gene.supportsEfetch)

        // Databases that do NOT support efetch
        XCTAssertFalse(NCBIDatabase.assembly.supportsEfetch)
        XCTAssertFalse(NCBIDatabase.genome.supportsEfetch)

        // Virus taxonomy filter
        XCTAssertEqual(NCBIDatabase.virusTaxonomyFilter, "txid10239[Organism:exp]")
    }

    /// Verifies NCBIFormat file extensions and rettype values.
    func testNCBIFormatProperties() {
        XCTAssertEqual(NCBIFormat.fasta.fileExtension, "fasta")
        XCTAssertEqual(NCBIFormat.genbank.fileExtension, "gb")
        XCTAssertEqual(NCBIFormat.xml.fileExtension, "xml")

        // Download formats should include genbank and fasta
        let downloadFormats = NCBIFormat.downloadFormats
        XCTAssertTrue(downloadFormats.contains(.genbank))
        XCTAssertTrue(downloadFormats.contains(.fasta))
        XCTAssertEqual(downloadFormats.count, 2)
    }

    /// Verifies NCBISearchType enum values and properties.
    func testNCBISearchTypeProperties() {
        XCTAssertEqual(NCBISearchType.nucleotide.displayName, "GenBank (Nucleotide)")
        XCTAssertEqual(NCBISearchType.genome.displayName, "Genome (Assembly)")
        XCTAssertEqual(NCBISearchType.virus.displayName, "Virus")

        XCTAssertEqual(NCBISearchType.allCases.count, 3)

        // Icons should be non-empty SF Symbol names
        for searchType in NCBISearchType.allCases {
            XCTAssertFalse(searchType.icon.isEmpty,
                           "\(searchType) should have an icon")
            XCTAssertFalse(searchType.helpText.isEmpty,
                           "\(searchType) should have help text")
        }
    }

    // MARK: - 11. BuildStep Enum Tests

    /// Verifies that all build steps have progress weights that sum to 1.0.
    func testBuildStepProgressWeightsSum() {
        let totalWeight = BuildStep.allCases.reduce(0.0) { $0 + $1.progressWeight }
        XCTAssertEqual(totalWeight, 1.0, accuracy: 0.001,
                       "Build step progress weights should sum to 1.0")
    }

    /// Verifies each build step has a non-empty display string.
    func testBuildStepDisplayStrings() {
        for step in BuildStep.allCases {
            XCTAssertFalse(step.rawValue.isEmpty,
                           "Build step \(step) should have a non-empty raw value")
        }
    }

    // MARK: - 12. End-to-End Pipeline Simulation

    /// Simulates the complete pipeline: assembly summary -> URL derivation ->
    /// configuration building -> manifest creation, all without network calls.
    func testFullPipelineSimulationWithoutNetwork() throws {
        // Step 1: Decode an assembly summary (as would come from NCBI API)
        let summary = try makeAssemblySummary(
            uid: "200001",
            assemblyAccession: "GCF_009858895.2",
            assemblyName: "ASM985889v3",
            organism: "Severe acute respiratory syndrome coronavirus 2",
            taxid: 2697049,
            speciesName: "SARS-CoV-2",
            ftpPathRefSeq: "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/858/895/GCF_009858895.2_ASM985889v3",
            submitter: "NCBI",
            coverage: "N/A",
            contigN50: 29903,
            scaffoldN50: 29903
        )

        // Step 2: Derive file URLs using the same logic as NCBIService
        let fastaURL = deriveFASTAURL(from: summary)
        let gff3URL = deriveGFF3URL(from: summary)

        XCTAssertNotNil(fastaURL)
        XCTAssertNotNil(gff3URL)
        XCTAssertEqual(fastaURL!.lastPathComponent, "GCF_009858895.2_ASM985889v3_genomic.fna.gz")
        XCTAssertEqual(gff3URL!.lastPathComponent, "GCF_009858895.2_ASM985889v3_genomic.gff.gz")

        // Step 3: Build SourceInfo from assembly summary
        let source = SourceInfo(
            organism: summary.organism ?? "Unknown",
            commonName: summary.speciesName != summary.organism ? summary.speciesName : nil,
            taxonomyId: summary.taxid,
            assembly: summary.assemblyName ?? "Unknown",
            assemblyAccession: summary.assemblyAccession,
            database: "NCBI",
            sourceURL: fastaURL,
            downloadDate: Date()
        )

        XCTAssertEqual(source.organism, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(source.commonName, "SARS-CoV-2")
        XCTAssertEqual(source.taxonomyId, 2697049)

        // Step 4: Build the configuration (using local placeholder paths)
        let localFASTA = tempDirectory.appendingPathComponent("genome.fa")
        let localGFF3 = tempDirectory.appendingPathComponent("annotations.gff3")
        let outputDir = tempDirectory.appendingPathComponent("bundles")

        let identifier = "org.lungfish.ref.\(summary.assemblyAccession!)"
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")

        let config = BuildConfiguration(
            name: "\(summary.organism!) - \(summary.assemblyName!)",
            identifier: identifier,
            fastaURL: localFASTA,
            annotationFiles: [
                AnnotationInput(
                    url: localGFF3,
                    name: "NCBI Gene Annotations",
                    description: "GFF3 annotations from NCBI RefSeq",
                    id: "ncbi_genes",
                    annotationType: .gene
                )
            ],
            outputDirectory: outputDir,
            source: source
        )

        XCTAssertEqual(config.name, "Severe acute respiratory syndrome coronavirus 2 - ASM985889v3")
        XCTAssertEqual(config.identifier, "org-lungfish-ref-gcf_009858895-2")
        XCTAssertEqual(config.annotationFiles.count, 1)

        // Step 5: Create a manifest (simulating what the builder produces)
        let genome = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: "genome/sequence.fa.gz.gzi",
            totalLength: 29_903,
            chromosomes: [
                ChromosomeInfo(
                    name: "NC_045512.2",
                    length: 29_903,
                    offset: 50,
                    lineBases: 70,
                    lineWidth: 71,
                    aliases: ["MN908947.3"],
                    isPrimary: true
                )
            ]
        )

        let manifest = BundleManifest(
            name: config.name,
            identifier: config.identifier,
            description: "SARS-CoV-2 reference genome",
            source: config.source,
            genome: genome,
            annotations: [
                AnnotationTrackInfo(
                    id: "ncbi_genes",
                    name: "NCBI Gene Annotations",
                    description: "GFF3 annotations from NCBI RefSeq",
                    path: "annotations/ncbi_genes.bb",
                    annotationType: .gene,
                    featureCount: 12,
                    source: "NCBI"
                )
            ]
        )

        // Step 6: Save and verify
        let bundleDir = tempDirectory.appendingPathComponent("sars-cov-2.lungfishref")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try manifest.save(to: bundleDir)

        let loaded = try BundleManifest.load(from: bundleDir)
        XCTAssertEqual(loaded.identifier, "org-lungfish-ref-gcf_009858895-2")
        XCTAssertEqual(loaded.genome!.totalLength, 29_903)
        XCTAssertEqual(loaded.genome!.chromosomes[0].name, "NC_045512.2")
        XCTAssertEqual(loaded.genome!.chromosomes[0].aliases, ["MN908947.3"])
        XCTAssertEqual(loaded.annotations[0].featureCount, 12)

        let errors = loaded.validate()
        XCTAssertTrue(errors.isEmpty,
                       "Pipeline-produced manifest should pass validation, got: \(errors)")
    }
}
