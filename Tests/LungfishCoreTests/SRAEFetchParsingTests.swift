// SRAEFetchParsingTests.swift - Tests for parsing SRA EFetch runinfo CSV
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SRAEFetchParsingTests: XCTestCase {

    func testParseRunInfoCSV() {
        let csv = """
        Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName,g1k_pop_code,source,g1k_analysis_group,Subject_ID,Sex,Disease,Tumor,Affection_Status,Analyte_Type,Histological_Type,Body_Site,CenterName,Submission,dbgap_study_accession,Consent,RunHash,ReadHash
        DRR028938,2015-01-14,2015-01-14,631,190562,631,302,0,na,https://sra-downloadb.be-md.ncbi.nlm.nih.gov/sos3/sra-pub-zq-14/DRR028/DRR028938/DRR028938.sra,DRX026575,,,WGS,RANDOM,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina HiSeq 2500,DRP002739,PRJDB3502,,281982,DRS022844,SAMD00024406,simple,1386,Bacillus cereus,NBRC 15305,,,,,,,,,,DDBJ,DRA002883,,public,ABC123,DEF456
        DRR051810,2016-05-18,2016-05-18,270,81000,270,300,0,na,https://example.com/DRR051810.sra,DRX046950,,,WGS,RANDOM,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina HiSeq 2000,DRP003850,PRJDB4000,,300000,DRS040000,SAMD00044332,simple,9606,Homo sapiens,Sample1,,,,,,,,,,DDBJ,DRA004000,,public,GHI789,JKL012
        """
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810"])
    }

    func testParseRunInfoCSVEmptyResponse() {
        let csv = ""
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertTrue(accessions.isEmpty)
    }

    func testParseRunInfoCSVHeaderOnly() {
        let csv = "Run,ReleaseDate,LoadDate,spots,bases\n"
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertTrue(accessions.isEmpty)
    }

    func testParseRunInfoCSVSkipsEmptyRunColumn() {
        let csv = """
        Run,ReleaseDate
        DRR028938,2015-01-14
        ,2016-05-18
        DRR051810,2016-05-18
        """
        let accessions = NCBIService.parseRunInfoCSV(csv)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810"])
    }

    func testParseRunInfoRowsAcceptsDateOnlyReleaseDate() {
        let csv = """
        Run,ReleaseDate
        SRR11140748,2020-03-18
        """

        let rows = NCBIService.parseRunInfoRows(csv)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(rows.map(\.accession), ["SRR11140748"])
        XCTAssertEqual(
            rows.first?.releaseDate,
            calendar.date(from: DateComponents(year: 2020, month: 3, day: 18))
        )
    }
}
