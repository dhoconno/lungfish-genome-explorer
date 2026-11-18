// RNASeqQualitySummaryTests.swift - The quality numbers and the sample correlation of a bulk result (5.4 RS-BULK-VIEW M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each result is written by the one writer. The salmon-c1 numbers are pinned to salmon's own `aux_info/meta_info.json`,
// the shares on the refset-mito set to a hand sum written here, and one correlation cell to the formula done here.

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class RNASeqQualitySummaryTests: RNASeqExportTestCase {
    // MARK: - salmon-c1 through the import's request

    /// `import rnaseq` of the two salmon-c1 folders with no `--tx2gene`, built as `ImportRNASeqSubcommand` builds it.
    private func importSalmonC1() throws -> URL {
        let folders = try RNASeqFixtures.salmonRunIDs.map {
            try SalmonQuantFolderReader.read(folder: RNASeqFixtures.root.appendingPathComponent("salmon-c1/\($0)", isDirectory: true))
        }
        let transcripts = try SalmonQuantFolderReader.transcriptCounts(folders)
        let route = try SalmonQuantFolderReader.route(folders, tx2geneName: nil)
        let request = RNASeqResultWriter.Request(
            name: "c1", modality: .bulk, origin: .init(kind: .imported, tool: SalmonQuantFolderReader.tool, toolVersion: route.toolVersion),
            route: route, referenceSet: nil, samples: folders.map { RNASeqSampleRecord(id: $0.sample, runs: [$0.sample]) },
            genes: .ids(transcripts.rows.map(\.id)),
            counts: [.init(rows: .transcript, column: .default, unit: .estimated, table: transcripts)],
            sourceFiles: SalmonQuantFolderReader.sourceFiles(folders), notHost: [],
            quality: SalmonQuantFolderReader.qualityTable(folders))
        let url = analyses.appendingPathComponent("c1.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
    }

    func testSalmonC1LibrarySizeAndMappingRateEqualMetaInfoAndNoRRNAGenesAreAnnotated() throws {
        let summary = try RNASeqQualitySummary.read(resultAt: try importSalmonC1())
        XCTAssertEqual(summary.samples.map(\.sample), RNASeqFixtures.salmonRunIDs)
        XCTAssertEqual(summary.countTable, "counts/transcripts.counts.tsv")
        for row in summary.samples {
            let metaURL = RNASeqFixtures.root.appendingPathComponent("salmon-c1/\(row.sample)/aux_info/meta_info.json")
            let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
            let processed = try XCTUnwrap(meta["num_processed"] as? Int)
            let mapped = try XCTUnwrap(meta["percent_mapped"] as? Double)
            let types = try XCTUnwrap(meta["library_types"] as? [String])
            XCTAssertEqual(row.librarySize, String(processed), row.sample)
            XCTAssertEqual(row.librarySizeSource, "salmon num_processed", row.sample)
            XCTAssertEqual(Double(row.mappingRatePercent), mapped, row.sample)
            XCTAssertEqual(row.mappingRatePercent, "\(mapped)", "percent_mapped as salmon printed it, \(row.sample)")
            XCTAssertEqual(row.libraryType, types.joined(separator: ","), row.sample)
            XCTAssertEqual(row.rRNAPercent, "no rRNA genes annotated", "an import names no reference set, \(row.sample)")
            XCTAssertEqual(row.notHostPercent, "Not recorded", "an import names no reference set, so its files do not say which features are not host, \(row.sample)")
            XCTAssertEqual(row.globinPercent, "Not recorded", "no globin rule is named, \(row.sample)")
        }
        XCTAssertEqual(summary.document().columns, RNASeqQualitySummary.columns)
        XCTAssertEqual(summary.document().rows, summary.samples.map(\.cells))
    }

    // MARK: - refset-mito with a not-host extra, against a hand sum

    /// The rhesus mitochondrion of Ensembl 100 (2 genes of biotype Mt_rRNA, 22 Mt_tRNA, 13 protein coding) with the
    /// SARS-CoV-2 extra, built by the owner with the stand-in deriver. Returns the set's genes.tsv and its rows.
    private func rhesusSetGenes() async throws -> (url: URL, set: ReferenceSetOutcome, rows: [[String]]) {
        let folder = ReferenceSetMitoFixture.folder
        var request = ReferenceSetRequest(
            name: "Rhesus mitochondrion", species: "Macaca mulatta", assemblyName: "Mmul_10", annotationSource: "Ensembl",
            annotationRelease: "100", genome: folder.appendingPathComponent("rhesus-mt.fa"),
            annotation: folder.appendingPathComponent("rhesus-mt.gtf"), layout: .lge, mitochondrialContigs: ["MT"])
        request.extras = [ReferenceSetExtraInput(name: "sars-cov-2", kind: .virus, fasta: folder.appendingPathComponent("sars-cov-2.fa"))]
        let owner = ReferenceSetOwner(
            storageRoot: root.appendingPathComponent("storage", isDirectory: true), deriver: StandInTranscriptDeriver(),
            provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let set = try await owner.build(request)
        let genes = set.url.appendingPathComponent("derived/genes.tsv")
        let rows = try String(contentsOf: genes, encoding: .utf8).split(separator: "\n").dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        return (genes, set, rows)
    }

    func testTheRRNAAndNotHostSharesOnRefsetMitoEqualAHandSum() async throws {
        let (genesURL, set, rows) = try await rhesusSetGenes()
        let ids = rows.map { $0[0] }
        let rRNA = rows.filter { $0[2] == "Mt_rRNA" }.map { $0[0] }
        let notHost = rows.filter { $0[5] == "true" }.map { $0[0] }
        XCTAssertEqual(ids.count, 38, "37 host genes and one feature for the virus")
        XCTAssertEqual(rRNA.count, 2)
        XCTAssertEqual(notHost, ["NC_045512.2"])
        // S1: 1.5 on each of the 35 other host genes, 100 and 200.25 on the two rRNA genes, 50 on the virus.
        // S2: 1.5 on the 35 other host genes and 0 on the rRNA genes and the virus.
        let counts = ids.map { id -> RNASeqCountTable.Row in
            if id == rRNA[0] { return .init(id: id, counts: [100, 0]) }
            if id == rRNA[1] { return .init(id: id, counts: [200.25, 0]) }
            if notHost.contains(id) { return .init(id: id, counts: [50, 0]) }
            return .init(id: id, counts: [1.5, 1.5])
        }
        let request = RNASeqResultWriter.Request(
            name: "mito", modality: .bulk, origin: .init(kind: .quantified), route: RNASeqExportFixture.salmonReads,
            referenceSet: .init(id: set.manifest.id, layout: .lge),
            samples: [RNASeqSampleRecord(id: "S1", runs: ["S1"]), RNASeqSampleRecord(id: "S2", runs: ["S2"])],
            genes: .referenceSetTable(url: genesURL, keeping: ids),
            counts: [.init(rows: .gene, column: .default, unit: .reads, table: RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: counts))],
            sourceFiles: [], notHost: notHost)
        let url = analyses.appendingPathComponent("mito.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq quantification", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)

        let summary = try RNASeqQualitySummary.read(resultAt: url)
        let s1 = summary.samples[0]
        let s2 = summary.samples[1]
        // The hand sums: S1 counts 35 x 1.5 + 100 + 200.25 + 50 = 402.75, S2 counts 35 x 1.5 = 52.5.
        XCTAssertEqual(s1.counted, "402.75")
        XCTAssertEqual(s2.counted, "52.5")
        XCTAssertEqual(s1.librarySize, "402.75", "no quality table, so the library size is the column sum")
        XCTAssertEqual(s1.librarySizeSource, "column sum of counts/genes.counts.tsv in reads")
        XCTAssertEqual(s1.mappingRatePercent, "Not recorded")
        XCTAssertEqual(s1.libraryType, "Not recorded")
        XCTAssertEqual(try XCTUnwrap(Double(s1.rRNAPercent)), 300.25 / 402.75 * 100, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(Double(s1.notHostPercent)), 50 / 402.75 * 100, accuracy: 1e-12)
        XCTAssertEqual(s2.rRNAPercent, "0")
        XCTAssertEqual(s2.notHostPercent, "0")
        XCTAssertEqual(s1.globinPercent, "Not recorded")
        XCTAssertFalse(s1.rRNAPercent.contains("e"), "a share prints in plain digits: \(s1.rRNAPercent)")
        let facts = summary.document().facts
        XCTAssertEqual(facts["rRNA"], "annotated rRNA genes, the host genes whose biotype in genes.tsv is rRNA or Mt_rRNA: 2 in the table. Ribosomal RNA that the annotation lists as no gene is in no count")
        XCTAssertEqual(facts["notHost"], "the 1 feature that the manifest lists under notHost")
        XCTAssertEqual(facts["globin"], "Not recorded: no rule names the globin genes yet")
    }

    /// An import names no reference set, so its files do not say which features are not host (the salmon-c1 test above). A
    /// result that names a set and lists no extra feature keeps the words that say there is none.
    func testAResultThatNamesAReferenceSetAndListsNoNotHostFeatureKeepsTheWordsThatSayThereIsNone() throws {
        let url = try make(.init(name: "plain", samples: ["S1"]))
        XCTAssertEqual(try RNASeqQualitySummary.read(resultAt: url).samples[0].notHostPercent, "no not-host features")
    }

    /// The writer sums the transcripts of a gene in doubles, so a printed cell can carry the noise of that sum
    /// (5.7379999999999995 for the 5.738 that salmon measured). `counted` is the sum of the printed cells rounded to
    /// 6 decimals, without trailing zeros, and it is the library size when the result has no quality table.
    func testCountedIsTheRoundedSumOfThePrintedCellsAndNotTheNoiseOfTheWritersDoubleSums() throws {
        let table = RNASeqCountTable(
            sampleIDs: ["S1"], rows: [.init(id: "G1", counts: [5.7379999999999995]), .init(id: "G2", counts: [0.1])])
        let request = RNASeqResultWriter.Request(
            name: "noisy", modality: .bulk, origin: .init(kind: .quantified), route: RNASeqExportFixture.salmonReads, referenceSet: nil,
            samples: [RNASeqSampleRecord(id: "S1", runs: ["S1"])], genes: .ids(["G1", "G2"]),
            counts: [.init(rows: .gene, column: .default, unit: .estimated, table: table)], sourceFiles: [], notHost: [])
        let url = analyses.appendingPathComponent("noisy.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq quantification", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
        let printed = try String(contentsOf: url.appendingPathComponent("counts/genes.counts.tsv"), encoding: .utf8)
        XCTAssertTrue(printed.contains("5.7379999999999995"), "the writer prints the noise of the double: \(printed)")
        let row = try RNASeqQualitySummary.read(resultAt: url).samples[0]
        XCTAssertEqual(row.counted, "5.838")
        XCTAssertEqual(row.librarySize, "5.838", "no quality table, so the library size is the column sum")
    }

    // MARK: - The sample correlation

    func testTheCorrelationHasADiagonalOfOneIsSymmetricAndEqualsTheFormulaOnHostGenes() throws {
        let url = try make(.init(name: "corr", samples: ["S1", "S2", "S3"], genes: ["G1", "G2", "G3", "G4", "G5"], notHost: ["G5"], noise: 0.4))
        let correlation = try RNASeqSampleCorrelation.read(resultAt: url)
        XCTAssertEqual(correlation.samples, ["S1", "S2", "S3"])
        XCTAssertEqual(correlation.geneCount, 4, "the not-host feature is left out")
        for i in 0..<3 {
            XCTAssertEqual(correlation.values[i][i], 1)
            for j in 0..<3 { XCTAssertEqual(correlation.values[i][j], correlation.values[j][i], "\(i) \(j)") }
        }
        // The formula, done here: CPM on each sample's sum over host genes, log2(CPM + 1), then Pearson's r.
        let table = try RNASeqCountTable(tsv: Data(contentsOf: url.appendingPathComponent("counts/genes.counts.tsv")), path: "counts")
        let host = table.rows.filter { $0.id != "G5" }
        func logCPM(_ sample: Int) -> [Double] {
            let total = host.reduce(0) { $0 + $1.counts[sample] }
            return host.map { log2($0.counts[sample] / total * 1_000_000 + 1) }
        }
        let x = logCPM(0)
        let y = logCPM(2)
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let syy = y.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        XCTAssertEqual(try XCTUnwrap(correlation.values[0][2]), sxy / (sxx * syy).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(RNASeqSampleCorrelation.measure, "Pearson r")
        XCTAssertEqual(RNASeqSampleCorrelation.transform, "log2(CPM + 1)")
        let document = correlation.document()
        XCTAssertEqual(document.facts["measure"], "Pearson r")
        XCTAssertEqual(document.facts["transform"], "log2(CPM + 1)")
        XCTAssertEqual(document.columns, ["sample_id", "S1", "S2", "S3"])
        XCTAssertEqual(document.rows[1][2], "1")
    }

    /// A gene of 0 in every sample adds only a point at the origin, so it leaves the correlation. G1 counts 0 in the one
    /// sample of a shift of -10, and the plain digits of a share hold no exponent.
    func testAGeneWithNoCountInAnySampleIsLeftOutAndAShareIsPlainDigits() throws {
        let url = try make(.init(name: "zero", samples: ["S1"], genes: ["G1", "G2", "G3"], shift: -10))
        let correlation = try RNASeqSampleCorrelation.read(resultAt: url)
        XCTAssertEqual(correlation.geneCount, 2)
        XCTAssertEqual(correlation.values, [[1]])
        XCTAssertEqual(RNASeqQualitySummary.plainDigits(0.00001), "0.00001")
        XCTAssertEqual(RNASeqQualitySummary.plainDigits(1e16), "10000000000000000")
        XCTAssertEqual(RNASeqQualitySummary.plainDigits(33.333333333333336), "33.333333333333336")
    }

    // MARK: - The sum text and the rRNA rule

    /// The values are the exact sums in the kept C1 and C5 tables (`quality-samples.tsv`), with the text a person should read.
    func testASumPrintsWithoutTheNoiseOfTheWritersDoubleSums() throws {
        let posix = Locale(identifier: "en_US_POSIX")
        for (exact, shown) in [
            ("4829448.9820000000172139", "4829448.982"), ("7711258.0000000000103918", "7711258"),
            ("11239954.9499999999717548", "11239954.95"), ("17121121.1010000009239852", "17121121.101"),
            ("402.75", "402.75"), ("52.5", "52.5"), ("0", "0"),
        ] {
            XCTAssertEqual(RNASeqQualitySummary.sumText(try XCTUnwrap(Decimal(string: exact, locale: posix))), shown, exact)
        }
    }

    /// Decision 1 of the lane: a host gene is an rRNA gene when its biotype is rRNA or Mt_rRNA. A pseudogene of rRNA is not,
    /// and neither is an rRNA gene that the manifest lists under notHost. The counts of S1 are 10, 20 ... 60 on G1 to G6.
    func testTheRRNAShareCountsRRNAAndMtRRNAGenesAndLeavesOutPseudogenesAndNotHostFeatures() throws {
        var spec = RNASeqExportFixture.Spec(name: "rrna", samples: ["S1"], genes: ["G1", "G2", "G3", "G4", "G5", "G6"], notHost: ["G6"])
        spec.biotypes = ["G1": "rRNA", "G2": "Mt_rRNA", "G3": "rRNA_pseudogene", "G6": "rRNA"]
        let summary = try RNASeqQualitySummary.read(resultAt: try make(spec))
        let row = summary.samples[0]
        XCTAssertEqual(summary.rRNAGenes, ["G1", "G2"])
        XCTAssertEqual(row.counted, "210")
        XCTAssertEqual(try XCTUnwrap(Double(row.rRNAPercent)), 30.0 / 210 * 100, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(Double(row.notHostPercent)), 60.0 / 210 * 100, accuracy: 1e-12)
    }
}
