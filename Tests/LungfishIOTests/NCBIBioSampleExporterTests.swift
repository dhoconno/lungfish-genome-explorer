// NCBIBioSampleExporterTests.swift - Tests for NCBI BioSample TSV export
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class NCBIBioSampleExporterTests: XCTestCase {

    func testExportSingleSample() {
        var meta = FASTQSampleMetadata(sampleName: "ClinicalSample1")
        meta.sampleType = "Nasopharyngeal swab"
        meta.collectionDate = "2026-01-15"
        meta.geoLocName = "USA:Georgia:Atlanta"
        meta.host = "Homo sapiens"
        meta.organism = "SARS-CoV-2"
        meta.sequencingInstrument = "Illumina MiSeq"

        let tsv = NCBIBioSampleExporter.export(samples: [meta])

        // Check comment lines
        XCTAssertTrue(tsv.contains("# BioSample package: Pathogen.cl.1.0"))

        // Check header
        XCTAssertTrue(tsv.contains("sample_name\tsample_title\torganism"))

        // Check data row
        XCTAssertTrue(tsv.contains("ClinicalSample1\tClinicalSample1\tSARS-CoV-2"))
        XCTAssertTrue(tsv.contains("Nasopharyngeal swab"))
        XCTAssertTrue(tsv.contains("2026-01-15"))
        XCTAssertTrue(tsv.contains("USA:Georgia:Atlanta"))
        XCTAssertTrue(tsv.contains("Homo sapiens"))
        XCTAssertTrue(tsv.contains("Illumina MiSeq"))
    }

    func testExportMultipleSamples() {
        let s1 = FASTQSampleMetadata(sampleName: "S1")
        var s2 = FASTQSampleMetadata(sampleName: "S2")
        s2.organism = "metagenome"

        let tsv = NCBIBioSampleExporter.export(samples: [s1, s2])

        let lines = tsv.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 3) // header + 2 data rows
    }

    func testExportEnvironmentalPackage() {
        let meta = FASTQSampleMetadata(sampleName: "EnvSample")
        let tsv = NCBIBioSampleExporter.export(samples: [meta], package: .pathogenEnvironmental)
        XCTAssertTrue(tsv.contains("# BioSample package: Pathogen.env.1.0"))
    }

    func testExportEmptySamples() {
        let tsv = NCBIBioSampleExporter.export(samples: [])
        XCTAssertEqual(tsv, "")
    }

    func testExportDefaultOrganismIsMetagenome() {
        let meta = FASTQSampleMetadata(sampleName: "NoOrganism")
        let tsv = NCBIBioSampleExporter.export(samples: [meta])

        // organism column should default to "metagenome"
        let lines = tsv.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let dataLine = lines.last!
        let fields = dataLine.components(separatedBy: "\t")
        // organism is the 3rd column (index 2)
        XCTAssertEqual(fields[2], "metagenome")
    }

    func testExportToFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BioSampleExportTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meta = FASTQSampleMetadata(sampleName: "FileExportTest")
        let outputURL = tmpDir.appendingPathComponent("biosample.tsv")

        try NCBIBioSampleExporter.exportToFile(samples: [meta], url: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("FileExportTest"))
    }

    func testBioSamplePackageDisplayLabels() {
        XCTAssertTrue(NCBIBioSampleExporter.BioSamplePackage.pathogenClinical.displayLabel.contains("Clinical"))
        XCTAssertTrue(NCBIBioSampleExporter.BioSamplePackage.pathogenEnvironmental.displayLabel.contains("Environmental"))
    }
}
