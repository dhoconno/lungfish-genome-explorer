// MetagenomicsImportServiceTests+TaxTriageBatch.swift - A TaxTriage import of a run made inside a project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN (UX-IMPORT-BATCH items 12 and 13, BIO-IMPORT-BATCH
// item 10). A run made with `taxtriage run --output <project>/Analyses/<name>` carries `isBatch` true in its own
// `analysis-metadata.json`, and `copyInputPayload` put that file over the importer's. The importer also wrote
// `samples: []` over the run's record, so the sidebar hid the result and the viewer lost the negative controls.

import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

extension MetagenomicsImportServiceTests {
    /// The importer's `analysis-metadata.json` wins over the source's: tool `taxtriage`, `isBatch` false, made now.
    @Test
    func testImportTaxTriageWritesTheImportersMetadataOverTheSources() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceCreated = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try makeTaxTriageSourceRun(
            in: workspace,
            metadata: AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: true, created: sourceCreated),
            samples: [ttSample("S1"), ttSample("S2")]
        )

        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: workspace.appendingPathComponent("imports", isDirectory: true)
        )

        let metadata = try #require(AnalysesFolder.readAnalysisMetadata(from: imported.resultDirectory))
        #expect(metadata.tool == "taxtriage")
        #expect(metadata.isBatch == false)
        #expect(metadata.created > sourceCreated)
    }

    /// Every run fact of the source's record stays, and the two folders it names are the imported one.
    @Test
    func testImportTaxTriageKeepsTheRunsSamplesAndNegativeControl() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("run-source", isDirectory: true)
        try writeODR(source.appendingPathComponent("report/S1.odr.txt"), rows: 3)
        try writeODR(source.appendingPathComponent("report/NTC1.odr.txt"), rows: 1)
        var config = TaxTriageConfig(
            samples: [ttSample("S1"), ttSample("NTC1", negativeControl: true)],
            platform: .oxford,
            outputDirectory: source,
            kraken2DatabasePath: workspace.appendingPathComponent("Databases/k2_pluspf_20250714", isDirectory: true),
            maxCpus: 2,
            profile: "docker"
        )
        config.k2Confidence = 0.5
        config.topHitsCount = 25
        config.rank = "G"
        let failure = TaxTriageSampleFailure(
            sampleID: "S1",
            outputDirectory: source.appendingPathComponent("S1", isDirectory: true),
            errorDescription: "Kraken 2 stopped"
        )
        var record = TaxTriageResult(config: config, runtime: 1234.5, exitCode: 0, outputDirectory: source, sampleFailures: [failure])
        record.deduplicatedReadCounts = ["S1": 100]
        try record.save()

        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: workspace.appendingPathComponent("imports", isDirectory: true)
        )

        let loaded = try TaxTriageResult.load(from: imported.resultDirectory)
        #expect(loaded.config.samples.map(\.sampleId) == ["S1", "NTC1"])
        #expect(loaded.config.samples.first { $0.sampleId == "NTC1" }?.isNegativeControl == true)
        #expect(loaded.config.samples.first { $0.sampleId == "S1" }?.isNegativeControl == false)
        #expect(loaded.config.platform == .oxford)
        #expect(loaded.config.k2Confidence == 0.5)
        #expect(loaded.config.topHitsCount == 25)
        #expect(loaded.config.rank == "G")
        #expect(loaded.config.kraken2DatabasePath?.lastPathComponent == "k2_pluspf_20250714")
        #expect(loaded.runtime == 1234.5)
        #expect(loaded.exitCode == 0)
        #expect(loaded.sampleFailures == [failure])
        #expect(loaded.deduplicatedReadCounts == ["S1": 100])
        #expect(loaded.config.outputDirectory.path == imported.resultDirectory.path)
        #expect(loaded.outputDirectory.path == imported.resultDirectory.path)
    }

    /// The record names the Kraken 2 database folder the run's record names, and with no run record it says so.
    @Test
    func testImportTaxTriageNamesTheDatabaseTheRunRecords() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let named = workspace.appendingPathComponent("named", isDirectory: true)
        try writeODR(named.appendingPathComponent("report/S1.odr.txt"), rows: 3)
        let config = TaxTriageConfig(
            samples: [ttSample("S1")],
            outputDirectory: named,
            kraken2DatabasePath: workspace.appendingPathComponent("Databases/k2_pluspf_20250714", isDirectory: true)
        )
        try TaxTriageResult(config: config, runtime: 10, exitCode: 0, outputDirectory: named).save()
        let unnamed = workspace.appendingPathComponent("unnamed", isDirectory: true)
        try writeODR(unnamed.appendingPathComponent("report/S1.odr.txt"), rows: 3)

        let withRecord = try MetagenomicsImportService.importTaxTriage(
            inputURL: named,
            outputDirectory: workspace.appendingPathComponent("imports-named", isDirectory: true)
        )
        let withoutRecord = try MetagenomicsImportService.importTaxTriage(
            inputURL: unnamed,
            outputDirectory: workspace.appendingPathComponent("imports-unnamed", isDirectory: true)
        )

        let namedDefaults = try importRecordDefaults(of: withRecord.resultDirectory)
        #expect(ttText(namedDefaults["databaseIdentityStatus"]) == "namedBySource")
        #expect(ttText(namedDefaults["kraken2DatabaseName"]) == "k2_pluspf_20250714")
        #expect(ttText(namedDefaults["databaseIdentityNote"])?.contains("k2_pluspf_20250714") == true)
        let unnamedDefaults = try importRecordDefaults(of: withoutRecord.resultDirectory)
        #expect(ttText(unnamedDefaults["databaseIdentityStatus"]) == "notNamedBySource")
        #expect(ttText(unnamedDefaults["databaseIdentityNote"]) == "No run record was found, so this record cannot name the release that made its calls. Cite it from the run that made the result.")
    }

    /// Two samples of three and one rows read four, flat in `report/` and in a folder a sample.
    @Test
    func testImportTaxTriageCountsEveryReportsRows() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let flat = try importReports([("report/S1.odr.txt", 3), ("report/NTC1.odr.txt", 1)], named: "flat", in: workspace)
        let folders = try importReports([("S1/report/S1.odr.txt", 3), ("NTC1/report/NTC1.odr.txt", 1)], named: "folders", in: workspace)

        #expect(flat.reportEntryCount == 4)
        #expect(folders.reportEntryCount == 4)
    }

    /// A sample with an `.odr.txt` and an `.organisms.report.txt`, and the combined `all.odr.txt`, counts its own `.odr.txt` once.
    @Test
    func testImportTaxTriageCountsOneReportPerSample() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let imported = try importReports(
            [("report/S1.odr.txt", 3), ("report/S1.organisms.report.txt", 3), ("report/all.odr.txt", 3)],
            named: "doubled",
            in: workspace
        )

        #expect(imported.reportEntryCount == 3)
    }

    /// With no per-sample report the combined report is the count, and a MultiQC table is not added to it.
    @Test
    func testImportTaxTriageCountsTheCombinedReportNotMultiQC() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let imported = try importReports([("report/all.odr.txt", 3), ("report/multiqc_report.txt", 5)], named: "multiqc", in: workspace)

        #expect(imported.reportEntryCount == 3)
    }

    /// A folder with only `report/all.odr.txt` is a result: it imports, and its record names the report.
    @Test
    func testImportTaxTriageKeepsACombinedReportAlone() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let imported = try importReports([("report/all.odr.txt", 3)], named: "combined", in: workspace)

        #expect(imported.reportEntryCount == 3)
        let loaded = try TaxTriageResult.load(from: imported.resultDirectory)
        #expect(loaded.reportFiles.map(\.lastPathComponent) == ["all.odr.txt"])
    }

    /// A folder with no report, metrics or Krona file is refused with words, and nothing is left behind.
    @Test
    func testImportTaxTriageRefusesAFolderWithNoReports() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let wrongFolder = workspace.appendingPathComponent("wrong-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongFolder, withIntermediateDirectories: true)
        try "notes".write(to: wrongFolder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)

        #expect {
            try MetagenomicsImportService.importTaxTriage(inputURL: wrongFolder, outputDirectory: outputDirectory)
        } throws: { error in
            (error as? LocalizedError)?.errorDescription
                == "No TaxTriage reports were found in \(wrongFolder.path). Nothing was imported. Choose the run's output folder."
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        #expect(left.filter { $0.hasPrefix("taxtriage") }.isEmpty)
    }

    /// Hidden files of a run folder stay behind, as `.skipsHiddenFiles` has always left them.
    @Test
    func testImportTaxTriageDoesNotCopyHiddenFiles() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try makeTaxTriageSourceRun(
            in: workspace,
            metadata: AnalysesFolder.AnalysisMetadata(tool: "taxtriage", isBatch: true),
            samples: [ttSample("S1")]
        )
        try "hidden".write(to: source.appendingPathComponent(".hidden-source-note"), atomically: true, encoding: .utf8)
        let hiddenFolder = source.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
        try "cached".write(to: hiddenFolder.appendingPathComponent("entry.txt"), atomically: true, encoding: .utf8)

        let imported = try MetagenomicsImportService.importTaxTriage(
            inputURL: source,
            outputDirectory: workspace.appendingPathComponent("imports", isDirectory: true)
        )

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: imported.resultDirectory.appendingPathComponent(".hidden-source-note").path))
        #expect(!fm.fileExists(atPath: imported.resultDirectory.appendingPathComponent(".cache").path))
        #expect(fm.fileExists(atPath: imported.resultDirectory.appendingPathComponent("S1/S1.top_report.tsv").path))
    }

    /// EsViritu keeps the source's batch mark, so the TaxTriage fix does not reach it (row IMPORT-ESVIRITU-FLAT-BATCH-HIDDEN).
    @Test
    func testImportEsVirituBatchKeepsItsBatchMark() throws {
        let workspace = ttBatchWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("esv-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "esviritu", isBatch: true),
            to: source
        )
        let detection = [
            "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample",
            "SampleA\tExample virus\tExample description\t1000\t\tACCN0001\tGCF_000001\t1000\tViruses\t\t\t\tExampleviridae\tExamplevirus\tExample virus species\t\t1.5\t42\t900\t12.4\t97.2\t0.01\t10000",
        ].joined(separator: "\n")
        try detection.write(to: source.appendingPathComponent("SampleA.detected_virus.info.tsv"), atomically: true, encoding: .utf8)

        let imported = try MetagenomicsImportService.importEsViritu(
            inputURL: source,
            outputDirectory: workspace.appendingPathComponent("imports", isDirectory: true)
        )

        let metadata = try #require(AnalysesFolder.readAnalysisMetadata(from: imported.resultDirectory))
        #expect(metadata.tool == "esviritu")
        #expect(metadata.isBatch == true)
    }
}

private func ttBatchWorkspace() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("taxtriage-batch-import-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func ttSample(_ id: String, negativeControl: Bool = false) -> TaxTriageSample {
    TaxTriageSample(
        sampleId: id,
        fastq1: URL(fileURLWithPath: "/nonexistent/reads/\(id).fastq.gz"),
        isNegativeControl: negativeControl
    )
}

private func ttText(_ value: ParameterValue?) -> String? {
    if case .string(let text)? = value { return text }
    return nil
}

/// A report table of a header and `rows` data lines, with its folders made.
private func writeODR(_ url: URL, rows: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = ["Detected Organism\tSpecimen ID\tTASS Score"] + (0..<rows).map { "Virus \($0)\tS1\t0.9" }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// Imports a run folder holding the reports `files` name (path under the folder and row count) and returns the import.
private func importReports(_ files: [(String, Int)], named name: String, in workspace: URL) throws -> TaxTriageImportResult {
    let source = workspace.appendingPathComponent(name, isDirectory: true)
    for (path, rows) in files {
        try writeODR(source.appendingPathComponent(path), rows: rows)
    }
    return try MetagenomicsImportService.importTaxTriage(
        inputURL: source,
        outputDirectory: workspace.appendingPathComponent("imports-\(name)", isDirectory: true)
    )
}

/// The resolved defaults of the import record at the root of `resultDirectory`.
private func importRecordDefaults(of resultDirectory: URL) throws -> [String: ParameterValue] {
    let record = try #require(try ProvenanceEnvelopeReader.load(
        fromSidecar: resultDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    ))
    return record.options.resolvedDefaults
}

/// A run folder as `taxtriage run` leaves it in a project. Each sample has a folder with a report of two rows, and the
/// folder's own `taxtriage-result.json` names the samples, a 417 second runtime and a Kraken 2 database path.
private func makeTaxTriageSourceRun(
    in workspace: URL,
    metadata: AnalysesFolder.AnalysisMetadata?,
    samples: [TaxTriageSample]
) throws -> URL {
    let fm = FileManager.default
    let source = workspace.appendingPathComponent("run-source", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    if let metadata {
        try AnalysesFolder.writeAnalysisMetadata(metadata, to: source)
    }
    var reports: [URL] = []
    for sample in samples {
        let folder = source.appendingPathComponent(sample.sampleId, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = folder.appendingPathComponent("\(sample.sampleId).top_report.tsv")
        try "taxid\tname\treads\n111\tVirus A\t12\n222\tVirus B\t8\n".write(to: report, atomically: true, encoding: .utf8)
        reports.append(report)
    }
    let config = TaxTriageConfig(
        samples: samples,
        outputDirectory: source,
        kraken2DatabasePath: workspace.appendingPathComponent("Databases/kraken2", isDirectory: true),
        maxCpus: 2,
        profile: "docker"
    )
    try TaxTriageResult(config: config, runtime: 417, exitCode: 0, outputDirectory: source, reportFiles: reports).save()
    return source
}
