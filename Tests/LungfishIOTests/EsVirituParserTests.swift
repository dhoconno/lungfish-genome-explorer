// EsVirituParserTests.swift - Tests for EsViritu viral metagenomics parsers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class EsVirituParserTests: XCTestCase {

    // MARK: - Detection Parser: Valid Input

    func testParseSimpleDetection() throws {
        let text = """
        sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample
        SAMPLE01\tRift Valley fever virus\tRVFV segment L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRift Valley fever phlebovirus\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)

        XCTAssertEqual(detections.count, 1)

        let d = detections[0]
        XCTAssertEqual(d.sampleId, "SAMPLE01")
        XCTAssertEqual(d.name, "Rift Valley fever virus")
        XCTAssertEqual(d.description, "RVFV segment L")
        XCTAssertEqual(d.length, 6404)
        XCTAssertEqual(d.segment, "L")
        XCTAssertEqual(d.accession, "KX944809.1")
        XCTAssertEqual(d.assembly, "GCF_000856585.1")
        XCTAssertEqual(d.assemblyLength, 11979)
        XCTAssertEqual(d.kingdom, "Viruses")
        XCTAssertEqual(d.phylum, "Negarnaviricota")
        XCTAssertEqual(d.tclass, "Ellioviricetes")
        XCTAssertEqual(d.order, "Bunyavirales")
        XCTAssertEqual(d.family, "Phenuiviridae")
        XCTAssertEqual(d.genus, "Phlebovirus")
        XCTAssertEqual(d.species, "Rift Valley fever phlebovirus")
        XCTAssertNil(d.subspecies) // "NA" maps to nil
        XCTAssertEqual(d.rpkmf, 125.4, accuracy: 0.01)
        XCTAssertEqual(d.readCount, 500)
        XCTAssertEqual(d.coveredBases, 6200)
        XCTAssertEqual(d.meanCoverage, 12.5, accuracy: 0.01)
        XCTAssertEqual(d.avgReadIdentity, 97.8, accuracy: 0.01)
        XCTAssertEqual(d.pi, 0.0021, accuracy: 0.0001)
        XCTAssertEqual(d.filteredReadsInSample, 1000000)
    }

    func testParseMultipleDetections() throws {
        let text = """
        sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        SAMPLE01\tRVFV\tseg M\t3885\tM\tKX944810.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t88.2\t300\t3700\t10.1\t96.5\t0.0018\t1000000
        SAMPLE01\tDengue virus 2\tDENV2 genome\t10723\tNA\tNC_001474.2\tGCF_000862125.1\t10723\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tDengue virus 2\t45.7\t200\t9500\t5.3\t95.2\t0.0035\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 3)

        // First two share an assembly
        XCTAssertEqual(detections[0].assembly, "GCF_000856585.1")
        XCTAssertEqual(detections[1].assembly, "GCF_000856585.1")

        // Third has a different assembly
        XCTAssertEqual(detections[2].assembly, "GCF_000862125.1")
        XCTAssertEqual(detections[2].subspecies, "Dengue virus 2")
    }

    func testParseDetectionWithoutHeader() throws {
        // Some files may lack a header; parser should still work
        let text = "SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000"

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections[0].name, "RVFV")
    }

    func testDetectionIdentifiable() throws {
        let text = "SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000"

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections[0].id, "KX944809.1")
    }

    // MARK: - Detection Parser: NA / Missing Fields

    func testParseDetectionWithNAFields() throws {
        // All taxonomy fields set to "NA" or "none"
        let text = "SAMPLE01\tUnknown virus\tsome desc\t5000\tNA\tACC001.1\tGCF_000001.1\t5000\tNA\tNA\tNA\tNA\tnone\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\t500000"

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 1)

        let d = detections[0]
        XCTAssertNil(d.segment)
        XCTAssertNil(d.kingdom)
        XCTAssertNil(d.phylum)
        XCTAssertNil(d.tclass)
        XCTAssertNil(d.order)
        XCTAssertNil(d.family)
        XCTAssertNil(d.genus)
        XCTAssertNil(d.species)
        XCTAssertNil(d.subspecies)
        // Numeric "NA" fields default to 0
        XCTAssertEqual(d.rpkmf, 0.0)
        XCTAssertEqual(d.readCount, 0)
        XCTAssertEqual(d.coveredBases, 0)
        XCTAssertEqual(d.meanCoverage, 0.0)
        XCTAssertEqual(d.avgReadIdentity, 0.0)
        XCTAssertEqual(d.pi, 0.0)
    }

    func testParseDetectionWithEmptyTaxonomyFields() throws {
        // Empty string taxonomy fields
        let text = "SAMPLE01\tVirus X\tdesc\t3000\t\tACC002.1\tGCF_000002.1\t3000\t\t\t\t\t\t\t\t\t50.0\t100\t2500\t5.0\t96.0\t0.001\t800000"

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 1)

        let d = detections[0]
        XCTAssertNil(d.segment) // empty -> nil
        XCTAssertNil(d.kingdom)
        XCTAssertNil(d.phylum)
        XCTAssertNil(d.tclass)
        XCTAssertNil(d.order)
        XCTAssertNil(d.family)
        XCTAssertNil(d.genus)
        XCTAssertNil(d.species)
        XCTAssertNil(d.subspecies)
        // Numeric fields should still parse correctly
        XCTAssertEqual(d.rpkmf, 50.0)
        XCTAssertEqual(d.readCount, 100)
    }

    // MARK: - Detection Parser: Error Cases

    func testParseEmptyDetectionFileThrows() {
        XCTAssertThrowsError(try EsVirituDetectionParser.parse(text: "")) { error in
            XCTAssertTrue(error is EsVirituDetectionParserError)
            if let esError = error as? EsVirituDetectionParserError {
                switch esError {
                case .emptyFile:
                    break // Expected
                default:
                    XCTFail("Expected emptyFile error, got \(esError)")
                }
            }
        }
    }

    func testParseDetectionHeaderOnlyReturnsNoDetections() throws {
        let text = "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample\n"

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertTrue(detections.isEmpty, "Header-only EsViritu output represents a successful zero-hit run")
    }

    func testParseMalformedDetectionLinesSkipped() throws {
        let text = """
        sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        this line is too short to be valid
        another\tbad\tline
        SAMPLE01\tDENV\tgenome\t10723\tNA\tNC_001474.2\tGCF_000862125.1\t10723\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tDengue virus 2\t45.7\t200\t9500\t5.3\t95.2\t0.0035\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 2)
        XCTAssertEqual(detections[0].name, "RVFV")
        XCTAssertEqual(detections[1].name, "DENV")
    }

    func testParseDetectionWithInvalidLengthSkipsLine() throws {
        // "abc" is not a valid integer for Length
        let text = """
        SAMPLE01\tRVFV\tseg L\tabc\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        SAMPLE01\tDENV\tgenome\t10723\tNA\tNC_001474.2\tGCF_000862125.1\t10723\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tNA\t45.7\t200\t9500\t5.3\t95.2\t0.0035\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections[0].name, "DENV")
    }

    func testParseDetectionFileNotFound() {
        let bogusURL = URL(fileURLWithPath: "/nonexistent/path/detected_virus.info.tsv")
        XCTAssertThrowsError(try EsVirituDetectionParser.parse(url: bogusURL)) { error in
            XCTAssertTrue(error is EsVirituDetectionParserError)
            if let esError = error as? EsVirituDetectionParserError {
                switch esError {
                case .fileReadError(let url, _):
                    XCTAssertEqual(url, bogusURL)
                default:
                    XCTFail("Expected fileReadError, got \(esError)")
                }
            }
        }
    }

    func testParseDetectionCommentLinesSkipped() throws {
        let text = """
        # This is a comment
        # Another comment
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 1)
    }

    // MARK: - Detection Parser: Assembly Grouping

    func testGroupByAssembly() throws {
        let text = """
        sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t80.0\t300\t6200\t12.5\t97.8\t0.0021\t1000000
        SAMPLE01\tRVFV\tseg M\t3885\tM\tKX944810.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t60.0\t200\t3700\t10.0\t96.0\t0.0018\t1000000
        SAMPLE01\tDENV2\tgenome\t10723\tNA\tNC_001474.2\tGCF_000862125.1\t10723\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tDengue virus 2\t45.7\t200\t9500\t5.3\t95.2\t0.0035\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        let assemblies = EsVirituDetectionParser.groupByAssembly(detections)

        XCTAssertEqual(assemblies.count, 2)

        // Assemblies are sorted by total reads descending
        // RVFV assembly: 300 + 200 = 500 reads
        // DENV assembly: 200 reads
        let rvfv = assemblies[0]
        XCTAssertEqual(rvfv.assembly, "GCF_000856585.1")
        XCTAssertEqual(rvfv.totalReads, 500)
        XCTAssertEqual(rvfv.contigs.count, 2)
        XCTAssertEqual(rvfv.rpkmf, 140.0, accuracy: 0.01) // 80 + 60
        XCTAssertEqual(rvfv.family, "Phenuiviridae")

        // Weighted average coverage: (12.5*300 + 10.0*200) / 500 = 5750/500 = 11.5
        XCTAssertEqual(rvfv.meanCoverage, 11.5, accuracy: 0.01)

        // Weighted average identity: (97.8*300 + 96.0*200) / 500 = (29340+19200)/500 = 97.08
        XCTAssertEqual(rvfv.avgReadIdentity, 97.08, accuracy: 0.01)

        let denv = assemblies[1]
        XCTAssertEqual(denv.assembly, "GCF_000862125.1")
        XCTAssertEqual(denv.totalReads, 200)
        XCTAssertEqual(denv.contigs.count, 1)
    }

    func testGroupByAssemblyEmpty() {
        let assemblies = EsVirituDetectionParser.groupByAssembly([])
        XCTAssertTrue(assemblies.isEmpty)
    }

    // MARK: - Detection Parser: Codable

    func testViralDetectionCodable() throws {
        let text = "SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000"

        let detections = try EsVirituDetectionParser.parse(text: text)
        let encoded = try JSONEncoder().encode(detections)
        let decoded = try JSONDecoder().decode([ViralDetection].self, from: encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].accession, "KX944809.1")
        XCTAssertEqual(decoded[0].rpkmf, 125.4, accuracy: 0.01)
        XCTAssertNil(decoded[0].subspecies)
    }

    // MARK: - Detection Parser: Error Descriptions

    func testDetectionErrorDescriptions() {
        let emptyErr = EsVirituDetectionParserError.emptyFile
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("Empty"))

        let fileErr = EsVirituDetectionParserError.fileReadError(
            URL(fileURLWithPath: "/tmp/detected_virus.info.tsv"),
            "No such file"
        )
        XCTAssertNotNil(fileErr.errorDescription)
        XCTAssertTrue(fileErr.errorDescription!.contains("detected_virus.info.tsv"))

        let colErr = EsVirituDetectionParserError.invalidColumnValue(
            line: 5, column: "Length", value: "abc"
        )
        XCTAssertNotNil(colErr.errorDescription)
        XCTAssertTrue(colErr.errorDescription!.contains("Length"))
        XCTAssertTrue(colErr.errorDescription!.contains("abc"))
    }

    // MARK: - Tax Profile Parser: Valid Input

    func testParseSimpleTaxProfile() throws {
        let text = """
        sample_ID\tfiltered_reads_in_sample\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tread_count\tRPKMF\tavg_read_identity\tassembly_list
        SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRift Valley fever phlebovirus\tNA\t500\t125.4\t97.8\tGCF_000856585.1
        """

        let profiles = try EsVirituTaxProfileParser.parse(text: text)

        XCTAssertEqual(profiles.count, 1)

        let p = profiles[0]
        XCTAssertEqual(p.sampleId, "SAMPLE01")
        XCTAssertEqual(p.filteredReadsInSample, 1000000)
        XCTAssertEqual(p.kingdom, "Viruses")
        XCTAssertEqual(p.phylum, "Negarnaviricota")
        XCTAssertEqual(p.tclass, "Ellioviricetes")
        XCTAssertEqual(p.order, "Bunyavirales")
        XCTAssertEqual(p.family, "Phenuiviridae")
        XCTAssertEqual(p.genus, "Phlebovirus")
        XCTAssertEqual(p.species, "Rift Valley fever phlebovirus")
        XCTAssertNil(p.subspecies)
        XCTAssertEqual(p.readCount, 500)
        XCTAssertEqual(p.rpkmf, 125.4, accuracy: 0.01)
        XCTAssertEqual(p.avgReadIdentity, 97.8, accuracy: 0.01)
        XCTAssertEqual(p.assemblyList, "GCF_000856585.1")
    }

    func testParseMultipleTaxProfiles() throws {
        let text = """
        sample_ID\tfiltered_reads_in_sample\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tread_count\tRPKMF\tavg_read_identity\tassembly_list
        SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t500\t125.4\t97.8\tGCF_000856585.1
        SAMPLE01\t1000000\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tDengue virus 2\t200\t45.7\t95.2\tGCF_000862125.1
        """

        let profiles = try EsVirituTaxProfileParser.parse(text: text)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].family, "Phenuiviridae")
        XCTAssertEqual(profiles[1].family, "Flaviviridae")
        XCTAssertEqual(profiles[1].subspecies, "Dengue virus 2")
    }

    func testParseTaxProfileWithNAFields() throws {
        let text = "SAMPLE01\t500000\tNA\tNA\tNA\tNA\tnone\tNA\tNA\tNA\t100\t20.0\t94.5\tGCF_000001.1,GCF_000002.1"

        let profiles = try EsVirituTaxProfileParser.parse(text: text)
        XCTAssertEqual(profiles.count, 1)

        let p = profiles[0]
        XCTAssertNil(p.kingdom)
        XCTAssertNil(p.phylum)
        XCTAssertNil(p.family)
        XCTAssertEqual(p.readCount, 100)
        XCTAssertEqual(p.assemblyList, "GCF_000001.1,GCF_000002.1")
    }

    func testParseTaxProfileWithoutHeader() throws {
        let text = "SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t500\t125.4\t97.8\tGCF_000856585.1"

        let profiles = try EsVirituTaxProfileParser.parse(text: text)
        XCTAssertEqual(profiles.count, 1)
    }

    // MARK: - Tax Profile Parser: Error Cases

    func testParseEmptyTaxProfileThrows() {
        XCTAssertThrowsError(try EsVirituTaxProfileParser.parse(text: "")) { error in
            XCTAssertTrue(error is EsVirituTaxProfileParserError)
            if let esError = error as? EsVirituTaxProfileParserError {
                switch esError {
                case .emptyFile:
                    break // Expected
                default:
                    XCTFail("Expected emptyFile error, got \(esError)")
                }
            }
        }
    }

    func testParseTaxProfileHeaderOnlyThrows() {
        let text = "sample_ID\tfiltered_reads_in_sample\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tread_count\tRPKMF\tavg_read_identity\tassembly_list\n"

        XCTAssertThrowsError(try EsVirituTaxProfileParser.parse(text: text)) { error in
            XCTAssertTrue(error is EsVirituTaxProfileParserError)
        }
    }

    func testParseMalformedTaxProfileLineSkipped() throws {
        let text = """
        sample_ID\tfiltered_reads_in_sample\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tread_count\tRPKMF\tavg_read_identity\tassembly_list
        SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t500\t125.4\t97.8\tGCF_000856585.1
        too\tfew\tcolumns
        SAMPLE01\t1000000\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tNA\t200\t45.7\t95.2\tGCF_000862125.1
        """

        let profiles = try EsVirituTaxProfileParser.parse(text: text)
        XCTAssertEqual(profiles.count, 2)
    }

    func testParseTaxProfileFileNotFound() {
        let bogusURL = URL(fileURLWithPath: "/nonexistent/path/tax_profile.tsv")
        XCTAssertThrowsError(try EsVirituTaxProfileParser.parse(url: bogusURL)) { error in
            XCTAssertTrue(error is EsVirituTaxProfileParserError)
        }
    }

    // MARK: - Tax Profile Parser: Codable

    func testViralTaxProfileCodable() throws {
        let text = "SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t500\t125.4\t97.8\tGCF_000856585.1"

        let profiles = try EsVirituTaxProfileParser.parse(text: text)
        let encoded = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([ViralTaxProfile].self, from: encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].sampleId, "SAMPLE01")
        XCTAssertEqual(decoded[0].family, "Phenuiviridae")
    }

    // MARK: - Tax Profile Parser: Error Descriptions

    func testTaxProfileErrorDescriptions() {
        let emptyErr = EsVirituTaxProfileParserError.emptyFile
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("Empty"))

        let fileErr = EsVirituTaxProfileParserError.fileReadError(
            URL(fileURLWithPath: "/tmp/tax_profile.tsv"),
            "Permission denied"
        )
        XCTAssertNotNil(fileErr.errorDescription)
        XCTAssertTrue(fileErr.errorDescription!.contains("tax_profile.tsv"))
    }

    // MARK: - Coverage Parser: Valid Input

    func testParseSimpleCoverage() throws {
        let text = """
        Accession\twindow_index\twindow_start\twindow_end\taverage_coverage
        KX944809.1\t0\t0\t100\t15.3
        KX944809.1\t1\t100\t200\t22.7
        KX944809.1\t2\t200\t300\t8.1
        """

        let windows = try EsVirituCoverageParser.parse(text: text)

        XCTAssertEqual(windows.count, 3)

        XCTAssertEqual(windows[0].accession, "KX944809.1")
        XCTAssertEqual(windows[0].windowIndex, 0)
        XCTAssertEqual(windows[0].windowStart, 0)
        XCTAssertEqual(windows[0].windowEnd, 100)
        XCTAssertEqual(windows[0].averageCoverage, 15.3, accuracy: 0.01)

        XCTAssertEqual(windows[1].windowIndex, 1)
        XCTAssertEqual(windows[1].windowStart, 100)
        XCTAssertEqual(windows[1].averageCoverage, 22.7, accuracy: 0.01)

        XCTAssertEqual(windows[2].windowIndex, 2)
        XCTAssertEqual(windows[2].averageCoverage, 8.1, accuracy: 0.01)
    }

    func testParseMultiAccessionCoverage() throws {
        let text = """
        Accession\twindow_index\twindow_start\twindow_end\taverage_coverage
        KX944809.1\t0\t0\t100\t15.3
        KX944809.1\t1\t100\t200\t22.7
        NC_001474.2\t0\t0\t100\t5.2
        NC_001474.2\t1\t100\t200\t3.8
        """

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 4)

        // Group by accession
        let grouped = Dictionary(grouping: windows, by: \.accession)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped["KX944809.1"]?.count, 2)
        XCTAssertEqual(grouped["NC_001474.2"]?.count, 2)
    }

    func testParseCoverageWithoutHeader() throws {
        let text = """
        KX944809.1\t0\t0\t100\t15.3
        KX944809.1\t1\t100\t200\t22.7
        """

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 2)
    }

    func testParseCoverageZeroCoverage() throws {
        let text = "KX944809.1\t0\t0\t100\t0.0"

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].averageCoverage, 0.0)
    }

    // MARK: - Coverage Parser: Error Cases

    func testParseEmptyCoverageThrows() {
        XCTAssertThrowsError(try EsVirituCoverageParser.parse(text: "")) { error in
            XCTAssertTrue(error is EsVirituCoverageParserError)
            if let esError = error as? EsVirituCoverageParserError {
                switch esError {
                case .emptyFile:
                    break // Expected
                default:
                    XCTFail("Expected emptyFile error, got \(esError)")
                }
            }
        }
    }

    func testParseCoverageHeaderOnlyThrows() {
        let text = "Accession\twindow_index\twindow_start\twindow_end\taverage_coverage\n"

        XCTAssertThrowsError(try EsVirituCoverageParser.parse(text: text)) { error in
            XCTAssertTrue(error is EsVirituCoverageParserError)
        }
    }

    func testParseMalformedCoverageLineSkipped() throws {
        let text = """
        Accession\twindow_index\twindow_start\twindow_end\taverage_coverage
        KX944809.1\t0\t0\t100\t15.3
        bad line here
        KX944809.1\t1\t100\t200\t22.7
        """

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 2)
    }

    func testParseCoverageInvalidNumericSkipped() throws {
        let text = """
        KX944809.1\t0\t0\t100\t15.3
        KX944809.1\tabc\t100\t200\t22.7
        KX944809.1\t2\t200\t300\t8.1
        """

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].windowIndex, 0)
        XCTAssertEqual(windows[1].windowIndex, 2)
    }

    func testParseCoverageFileNotFound() {
        let bogusURL = URL(fileURLWithPath: "/nonexistent/path/coverage.tsv")
        XCTAssertThrowsError(try EsVirituCoverageParser.parse(url: bogusURL)) { error in
            XCTAssertTrue(error is EsVirituCoverageParserError)
        }
    }

    func testParseCoverageCommentLinesSkipped() throws {
        let text = """
        # Coverage data
        KX944809.1\t0\t0\t100\t15.3
        # Another comment
        KX944809.1\t1\t100\t200\t22.7
        """

        let windows = try EsVirituCoverageParser.parse(text: text)
        XCTAssertEqual(windows.count, 2)
    }

    // MARK: - Coverage Parser: Codable

    func testViralCoverageWindowCodable() throws {
        let text = "KX944809.1\t0\t0\t100\t15.3"

        let windows = try EsVirituCoverageParser.parse(text: text)
        let encoded = try JSONEncoder().encode(windows)
        let decoded = try JSONDecoder().decode([ViralCoverageWindow].self, from: encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].accession, "KX944809.1")
        XCTAssertEqual(decoded[0].averageCoverage, 15.3, accuracy: 0.01)
    }

    // MARK: - Coverage Parser: Error Descriptions

    func testCoverageErrorDescriptions() {
        let emptyErr = EsVirituCoverageParserError.emptyFile
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("Empty"))

        let fileErr = EsVirituCoverageParserError.fileReadError(
            URL(fileURLWithPath: "/tmp/coverage.tsv"),
            "No such file"
        )
        XCTAssertNotNil(fileErr.errorDescription)
        XCTAssertTrue(fileErr.errorDescription!.contains("coverage.tsv"))

        let colErr = EsVirituCoverageParserError.invalidColumnValue(
            line: 3, column: "window_index", value: "abc"
        )
        XCTAssertNotNil(colErr.errorDescription)
        XCTAssertTrue(colErr.errorDescription!.contains("window_index"))
    }

    // MARK: - EsVirituResult

    func testEsVirituResultConstruction() throws {
        // Parse detections
        let detectionText = """
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t125.4\t500\t6200\t12.5\t97.8\t0.0021\t1000000
        SAMPLE01\tDENV2\tgenome\t10723\tNA\tNC_001474.2\tGCF_000862125.1\t10723\tViruses\tKitrinoviricota\tFlasuviricetes\tAmarillovirales\tFlaviviridae\tFlavivirus\tDengue virus\tDengue virus 2\t45.7\t200\t9500\t5.3\t95.2\t0.0035\t1000000
        """
        let detections = try EsVirituDetectionParser.parse(text: detectionText)
        let assemblies = EsVirituDetectionParser.groupByAssembly(detections)

        // Parse tax profile
        let taxText = "SAMPLE01\t1000000\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV\tNA\t500\t125.4\t97.8\tGCF_000856585.1"
        let taxProfile = try EsVirituTaxProfileParser.parse(text: taxText)

        // Parse coverage
        let covText = "KX944809.1\t0\t0\t100\t15.3\nKX944809.1\t1\t100\t200\t22.7"
        let coverageWindows = try EsVirituCoverageParser.parse(text: covText)

        // Assemble result
        let families = Set(detections.compactMap(\.family))
        let species = Set(detections.compactMap(\.species))

        let result = EsVirituResult(
            sampleId: "SAMPLE01",
            detections: detections,
            assemblies: assemblies,
            taxProfile: taxProfile,
            coverageWindows: coverageWindows,
            totalFilteredReads: 1000000,
            detectedFamilyCount: families.count,
            detectedSpeciesCount: species.count,
            runtime: 42.5,
            toolVersion: "1.2.3"
        )

        XCTAssertEqual(result.sampleId, "SAMPLE01")
        XCTAssertEqual(result.detections.count, 2)
        XCTAssertEqual(result.assemblies.count, 2)
        XCTAssertEqual(result.taxProfile.count, 1)
        XCTAssertEqual(result.coverageWindows.count, 2)
        XCTAssertEqual(result.totalFilteredReads, 1000000)
        XCTAssertEqual(result.detectedFamilyCount, 2) // Phenuiviridae, Flaviviridae
        XCTAssertEqual(result.detectedSpeciesCount, 2) // RVFV species, Dengue virus
        XCTAssertEqual(result.runtime, 42.5)
        XCTAssertEqual(result.toolVersion, "1.2.3")
    }

    func testEsVirituResultCodable() throws {
        let result = EsVirituResult(
            sampleId: "TEST",
            detections: [],
            assemblies: [],
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: 0,
            detectedFamilyCount: 0,
            detectedSpeciesCount: 0,
            runtime: nil,
            toolVersion: nil
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EsVirituResult.self, from: encoded)

        XCTAssertEqual(decoded.sampleId, "TEST")
        XCTAssertNil(decoded.runtime)
        XCTAssertNil(decoded.toolVersion)
    }

    // MARK: - Helper Method Tests

    func testOptionalStringHandling() {
        XCTAssertNil(EsVirituDetectionParser.optionalString(""))
        XCTAssertNil(EsVirituDetectionParser.optionalString("  "))
        XCTAssertNil(EsVirituDetectionParser.optionalString("NA"))
        XCTAssertNil(EsVirituDetectionParser.optionalString("na"))
        XCTAssertNil(EsVirituDetectionParser.optionalString("none"))
        XCTAssertNil(EsVirituDetectionParser.optionalString("None"))
        XCTAssertNil(EsVirituDetectionParser.optionalString("NONE"))
        XCTAssertEqual(EsVirituDetectionParser.optionalString("Viruses"), "Viruses")
        XCTAssertEqual(EsVirituDetectionParser.optionalString("  Viruses  "), "Viruses")
    }

    func testParseDoubleHandling() {
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("125.4", default: 0.0), 125.4, accuracy: 0.01)
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("NA", default: 0.0), 0.0)
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("none", default: 0.0), 0.0)
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("", default: 0.0), 0.0)
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("abc", default: -1.0), -1.0)
        XCTAssertEqual(EsVirituDetectionParser.parseDouble("  42.5  ", default: 0.0), 42.5, accuracy: 0.01)
    }

    func testParseIntHandling() {
        XCTAssertEqual(EsVirituDetectionParser.parseInt("500", default: 0), 500)
        XCTAssertEqual(EsVirituDetectionParser.parseInt("NA", default: 0), 0)
        XCTAssertEqual(EsVirituDetectionParser.parseInt("none", default: 0), 0)
        XCTAssertEqual(EsVirituDetectionParser.parseInt("", default: 0), 0)
        XCTAssertEqual(EsVirituDetectionParser.parseInt("abc", default: -1), -1)
        XCTAssertEqual(EsVirituDetectionParser.parseInt("  100  ", default: 0), 100)
    }

    // MARK: - ViralAssembly Identity

    func testViralAssemblyIdentifiable() throws {
        let text = """
        SAMPLE01\tRVFV\tseg L\t6404\tL\tKX944809.1\tGCF_000856585.1\t11979\tViruses\tNegarnaviricota\tEllioviricetes\tBunyavirales\tPhenuiviridae\tPhlebovirus\tRVFV species\tNA\t80.0\t300\t6200\t12.5\t97.8\t0.0021\t1000000
        """

        let detections = try EsVirituDetectionParser.parse(text: text)
        let assemblies = EsVirituDetectionParser.groupByAssembly(detections)

        XCTAssertEqual(assemblies[0].id, "GCF_000856585.1")
    }

    func testViralAssemblyEquatable() throws {
        let a1 = ViralAssembly(
            assembly: "GCF_000856585.1", assemblyLength: 11979, name: "RVFV",
            family: "Phenuiviridae", genus: "Phlebovirus", species: "RVFV",
            totalReads: 500, rpkmf: 100.0, meanCoverage: 10.0, avgReadIdentity: 97.0,
            contigs: []
        )
        let a2 = ViralAssembly(
            assembly: "GCF_000856585.1", assemblyLength: 11979, name: "RVFV different name",
            family: "Phenuiviridae", genus: "Phlebovirus", species: "RVFV",
            totalReads: 999, rpkmf: 200.0, meanCoverage: 20.0, avgReadIdentity: 99.0,
            contigs: []
        )

        XCTAssertEqual(a1, a2) // Same assembly accession
        XCTAssertEqual(a1.hashValue, a2.hashValue)
    }
}
