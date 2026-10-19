// TaxTriageExportCommandsTests.swift - lungfish-cli taxtriage export organism-matrix and batch-report
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.32, ARCH ruling X-1 rows A4 and A5, BIO ruling on 12.32 (F1, F2). The expected bytes are the
// ones `TaxTriageExportPinTests` pins for the viewer's own writers on the same result, so each leaf writes what the
// viewer wrote. The record names the leaf, its canonical argv and exactly the files it read.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageExportCommandsTests: XCTestCase {
    private var folder: URL!
    private var resultFolder: URL!
    private var config: TaxTriageConfig!

    private static let delta = "Delta, \"quoted\" virus"
    private static let matrixHeader = "Organism,Mean TASS,Samples Detected,Contamination Risk,sample-1,sample-2"
    private static let deltaField = "\"Delta, \"\"quoted\"\" virus\""

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageExportCommands-\(UUID().uuidString)", isDirectory: true)
        resultFolder = folder.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: resultFolder.appendingPathComponent("taxtriage.sqlite"),
            rows: [
                Self.row("sample-1", "Alpha virus", 1001, 0.91, 42, "High"),
                Self.row("sample-1", "Beta virus", 1002, 0.76, 24, "High"),
                Self.row("sample-1", Self.delta, 3001, 0.60, 6, "Medium"),
                Self.row("sample-2", "Gamma virus", 2001, 0.50, 12, "Medium"),
                Self.row("sample-2", "Alpha virus", 1001, 0.20, 3, "Low"),
            ],
            metadata: ["tool": "taxtriage"]
        )
        config = TaxTriageConfig(
            samples: ["sample-1", "sample-2"].map {
                TaxTriageSample(
                    sampleId: $0,
                    fastq1: resultFolder.appendingPathComponent("\($0).fastq.gz"),
                    isNegativeControl: $0 == "sample-2"
                )
            },
            outputDirectory: resultFolder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TaxTriageResult(config: config, runtime: 61, exitCode: 0, outputDirectory: resultFolder))
            .write(to: resultFolder.appendingPathComponent("taxtriage-result.json"))
        // A batch manifest beside the database. No export reads it, so no record names it.
        try Data("{}".utf8).write(to: resultFolder.appendingPathComponent("taxtriage-batch-manifest.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func row(
        _ sample: String, _ organism: String, _ taxId: Int, _ tass: Double, _ reads: Int, _ confidence: String
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: tass,
            readsAligned: reads, uniqueReads: reads / 2, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: confidence,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
            bamIndexPath: nil, primaryAccession: "NC_\(taxId)", accessionLength: 1000
        )
    }

    private func matrixCommand(_ arguments: [String]) throws -> TaxTriageCommand.ExportOrganismMatrixSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["taxtriage", "export", "organism-matrix", resultFolder.path] + arguments)
        return try XCTUnwrap(parsed as? TaxTriageCommand.ExportOrganismMatrixSubcommand)
    }

    private func reportCommand(_ arguments: [String]) throws -> TaxTriageCommand.ExportBatchReportSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["taxtriage", "export", "batch-report", resultFolder.path] + arguments)
        return try XCTUnwrap(parsed as? TaxTriageCommand.ExportBatchReportSubcommand)
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func inputs(of outputURL: URL) throws -> [(name: String, digest: String?)] {
        try envelope(of: outputURL).files.filter { $0.role == .input }
            .map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.checksumSHA256) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - The organism matrix (A4)

    func testMatrixLeafWritesTheBytesTheViewerPinned() throws {
        let all = folder.appendingPathComponent("matrix-all.csv")
        _ = try matrixCommand(["--output", all.path]).export()
        XCTAssertEqual(try text(all), [
            Self.matrixHeader,
            "Alpha virus,0.5550,2/2,Yes,0.9100,0.2000",
            "Beta virus,0.7600,1/2,No,0.7600,",
            "\(Self.deltaField),0.6000,1/2,No,0.6000,",
            "Gamma virus,0.5000,1/2,Yes,,0.5000",
        ].joined(separator: "\n") + "\n")

        // One ticked sample narrows the metrics to its rows and the matrix loses the control's flags, as the viewer's.
        let one = folder.appendingPathComponent("matrix-one.csv")
        _ = try matrixCommand(["--sample", "sample-1", "--output", one.path]).export()
        XCTAssertEqual(try text(one), [
            Self.matrixHeader,
            "Alpha virus,0.9100,1/2,No,0.9100,",
            "Beta virus,0.7600,1/2,No,0.7600,",
            "\(Self.deltaField),0.6000,1/2,No,0.6000,",
        ].joined(separator: "\n") + "\n")

        let searched = folder.appendingPathComponent("matrix-search.csv")
        _ = try matrixCommand(["--sample", "sample-1", "--sample", "sample-2", "--search", "beta", "--output", searched.path]).export()
        XCTAssertEqual(try text(searched), [Self.matrixHeader, "Beta virus,0.7600,1/2,No,0.7600,"].joined(separator: "\n") + "\n")
    }

    func testMatrixRecordNamesTheLeafItsArgvAndTheFilesItRead() throws {
        let output = folder.appendingPathComponent("record.csv")
        let arguments = [
            "taxtriage", "export", "organism-matrix", resultFolder.path,
            "--sample", "sample-1", "--sample", "sample-2", "--search", "alpha", "--output", output.path,
        ]
        _ = try matrixCommand(Array(arguments.dropFirst(4))).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish taxtriage export organism-matrix")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath", "samples", "searchText"])
        XCTAssertTrue(envelope.options.defaults.isEmpty)
        XCTAssertEqual(envelope.options.resolvedDefaults.keys.sorted(), [
            "exportedOrganismCount", "metricCount", "negativeControlSampleIds", "rowCount", "sampleCount",
            "sampleIds", "tableMode",
        ])
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 1)
        XCTAssertEqual(resolved["metricCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["sampleCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["sampleIds"]?.arrayValue?.compactMap(\.stringValue), ["sample-1", "sample-2"])
        XCTAssertEqual(resolved["negativeControlSampleIds"]?.arrayValue?.compactMap(\.stringValue), ["sample-2"])
        XCTAssertEqual(resolved["tableMode"]?.stringValue, "batchGroup")

        let inputs = try Self.inputs(of: output)
        XCTAssertEqual(inputs.map(\.name), ["taxtriage-result.json", "taxtriage.sqlite"], "never the batch manifest")
        XCTAssertTrue(inputs.allSatisfy { $0.digest != nil })
    }

    func testMatrixWithoutASidecarHasNoNegativeControlsAndNamesOnlyTheDatabase() throws {
        try FileManager.default.removeItem(at: resultFolder.appendingPathComponent("taxtriage-result.json"))
        let output = folder.appendingPathComponent("no-sidecar.csv")
        _ = try matrixCommand(["--output", output.path]).export()
        XCTAssertTrue(try text(output).contains("Alpha virus,0.5550,2/2,No,0.9100,0.2000"))
        XCTAssertEqual(try Self.inputs(of: output).map(\.name), ["taxtriage.sqlite"])
    }

    // MARK: - The batch report (A5)

    /// The report the viewer wrote on the same result, with the clock of the export masked.
    private static func expectedReport(
        platform: String,
        negativeControls: String,
        perSample: [String],
        crossSample: [String],
        contamination: [String],
        highConfidence: [String]
    ) -> String {
        let bar = "============================================================"
        var lines = [
            bar, "TaxTriage Batch Analysis Report", bar, "",
            "Date: <masked>", "Samples: 2", "Platform: \(platform)", "Runtime: 61.0 seconds", "Exit Code: 0",
            "Negative Controls: \(negativeControls)",
        ]
        lines += ["", "--- Per-Sample Summary ---", ""] + perSample.map { "  " + $0 }
        lines += ["", "--- Cross-Sample Organisms ---", ""] + crossSample.map { "  " + $0 }
        lines += ["", "--- Contamination Risk Organisms ---", ""] + contamination.map { "  " + $0 }
        lines += ["", "--- High-Confidence Organisms (TASS >= 0.8) ---", ""] + highConfidence.map { "  " + $0 }
        lines += ["", bar, ""]
        return lines.joined(separator: "\n")
    }

    private func maskedText(_ url: URL) throws -> String {
        try text(url).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("Date: ") ? "Date: <masked>" : String($0) }
            .joined(separator: "\n")
    }

    func testReportLeafWritesTheBytesTheViewerPinned() throws {
        let platform = config.platform.displayName
        let all = folder.appendingPathComponent("report-all.txt")
        _ = try reportCommand(["--output", all.path]).export()
        XCTAssertEqual(try maskedText(all), Self.expectedReport(
            platform: platform, negativeControls: "sample-2",
            perSample: ["sample-1: 3 organisms (1 high confidence)", "sample-2 [NTC]: 2 organisms (0 high confidence)"],
            crossSample: ["Alpha virus: 2/2 samples, mean TASS=0.555 [CONTAMINATION RISK]"],
            contamination: ["Alpha virus (detected in: sample-1, sample-2)", "Gamma virus (detected in: sample-2)"],
            highConfidence: ["None."]
        ))
        let allLines = try text(all).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(try XCTUnwrap(allLines.first { $0.hasPrefix("Date: ") }).count > "Date: ".count, "the run's clock")

        let one = folder.appendingPathComponent("report-one.txt")
        _ = try reportCommand(["--sample", "sample-1", "--output", one.path]).export()
        XCTAssertEqual(try maskedText(one), Self.expectedReport(
            platform: platform, negativeControls: "sample-2",
            perSample: ["sample-1: 3 organisms (1 high confidence)", "sample-2 [NTC]: 0 organisms (0 high confidence)"],
            crossSample: ["No organisms detected in multiple samples."],
            contamination: ["No organisms detected in negative controls."],
            highConfidence: ["Alpha virus: mean TASS=0.910, 1 sample(s)"]
        ))
    }

    func testReportRecordNamesTheLeafItsArgvAndTheFilesItRead() throws {
        let output = folder.appendingPathComponent("report-record.txt")
        let arguments = ["taxtriage", "export", "batch-report", resultFolder.path, "--output", output.path]
        _ = try reportCommand(Array(arguments.dropFirst(4))).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish taxtriage export batch-report")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath"])
        XCTAssertTrue(envelope.options.defaults.isEmpty)
        XCTAssertEqual(envelope.options.resolvedDefaults.keys.sorted(), [
            "classifierCount", "exportedOrganismCount", "metricCount", "negativeControlSampleIds",
            "reportLineCount", "sampleCount", "sampleIds", "tableMode",
        ])
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved["metricCount"]?.integerValue, 5)
        XCTAssertEqual(resolved["exportedOrganismCount"]?.integerValue, 4)
        XCTAssertEqual(resolved["classifierCount"]?.integerValue, config.classifiers.count)
        XCTAssertEqual(
            resolved["reportLineCount"]?.integerValue,
            try text(output).split(separator: "\n", omittingEmptySubsequences: false).count
        )
        XCTAssertEqual(try Self.inputs(of: output).map(\.name), ["taxtriage-result.json", "taxtriage.sqlite"])
    }

    // MARK: - Refusals

    func testBatchReportRefusesAResultWithoutASidecarBeforeWriting() throws {
        try FileManager.default.removeItem(at: resultFolder.appendingPathComponent("taxtriage-result.json"))
        let output = folder.appendingPathComponent("refused-report.txt")
        XCTAssertThrowsError(try reportCommand(["--output", output.path]).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }

    func testBothLeavesRefuseBeforeWriting() throws {
        let existing = folder.appendingPathComponent("exists.csv")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try matrixCommand(["--output", existing.path]).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal)
        }
        XCTAssertEqual(try text(existing), "keep")
        _ = try matrixCommand(["--output", existing.path, "--force"]).export()
        XCTAssertNotEqual(try text(existing), "keep")

        for (name, make) in [
            ("matrix", { (extra: [String]) in try self.matrixCommand(extra).export() }),
            ("report", { (extra: [String]) in try self.reportCommand(extra).export() }),
        ] {
            let unknown = folder.appendingPathComponent("unknown-\(name).out")
            XCTAssertThrowsError(try make(["--sample", "sample-Z", "--output", unknown.path]), name) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path), name)

            let database = resultFolder.appendingPathComponent("taxtriage.sqlite")
            let before = try Data(contentsOf: database)
            XCTAssertThrowsError(try make(["--output", database.path, "--force"]), name) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "--force never replaces an input: \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: database), before, name)

            let missing = folder.appendingPathComponent("missing-\(name)", isDirectory: true)
            XCTAssertThrowsError(try make(["--output", missing.appendingPathComponent("out").path]), name) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), name)
        }

        try FileManager.default.removeItem(at: resultFolder.appendingPathComponent("taxtriage.sqlite"))
        let noDatabase = folder.appendingPathComponent("no-database.csv")
        XCTAssertThrowsError(try matrixCommand(["--output", noDatabase.path]).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: noDatabase.path))
    }

    // MARK: - The arguments the app builds

    /// ARCH ruling G2 section 5. The arguments the begin helpers build parse through the root into each leaf, whose
    /// canonical argv is the executable name and the same array.
    func testTheLeavesParseTheGUIArguments() throws {
        let matrix = TaxTriageOrganismMatrixExport.invocation(
            resultURL: resultFolder, samples: ["sample-1", "sample-2"], searchText: "alpha virus",
            outputURL: folder.appendingPathComponent("gui matrix.csv"), force: true
        )
        let matrixLeaf = try matrixCommand(Array(matrix.arguments().dropFirst(4)))
        XCTAssertEqual(try matrixLeaf.invocation(), matrix)
        XCTAssertEqual(try matrixLeaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + matrix.arguments())
        XCTAssertEqual(Array(matrix.arguments().prefix(3)), TaxTriageOrganismMatrixExport.commandPath)
        XCTAssertEqual(
            TaxTriageCommand.ExportOrganismMatrixSubcommand.configuration.commandName,
            TaxTriageOrganismMatrixExport.commandPath.last
        )

        let report = TaxTriageBatchReportExport.invocation(
            resultURL: resultFolder, samples: ["sample-2"], searchText: nil,
            outputURL: folder.appendingPathComponent("gui report.txt"), force: false
        )
        let reportLeaf = try reportCommand(Array(report.arguments().dropFirst(4)))
        XCTAssertEqual(try reportLeaf.invocation(), report)
        XCTAssertEqual(try reportLeaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + report.arguments())
        XCTAssertEqual(Array(report.arguments().prefix(3)), TaxTriageBatchReportExport.commandPath)
        XCTAssertEqual(
            TaxTriageCommand.ExportBatchReportSubcommand.configuration.commandName,
            TaxTriageBatchReportExport.commandPath.last
        )
    }

    /// BIO ruling on 12.32, F1 and F2. The bytes follow the samples and the search and nothing else, so the leaves
    /// take no sort, filter, mode, metadata column or format.
    func testTheLeavesRefuseAnOptionTheyDoNotTake() {
        let output = folder.appendingPathComponent("refuse.out").path
        for extra in [
            ["--sort", "tt_reads:ascending"], ["--filter", "{}"], ["--mode", "batchGroup"],
            ["--metadata-column", "Group"], ["--output-format", "tsv"],
        ] {
            XCTAssertThrowsError(try matrixCommand(extra + ["--output", output]), "\(extra)")
            XCTAssertThrowsError(try reportCommand(extra + ["--output", output]), "\(extra)")
        }
    }
}
