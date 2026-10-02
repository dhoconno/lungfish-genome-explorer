// PrimerSchemeSaveCommandTests.swift - Save as Primer Scheme records the scheme-from-analysis command it runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The primer analysis viewport saves a tiled design as a .lungfishprimers
// bundle through PrimerSchemeFromAnalysisService and records
// `lungfish-cli primers scheme-from-analysis` in the Operations panel. The row
// used to quote its words by hand, so a scheme name with an apostrophe broke
// the command, and the scheme's provenance recorded the app process's own
// launch arguments (R3, R8). These tests parse the row command with the real
// CLI parser, check that the provenance argv is that command, and run the GUI
// request and the parsed command on one saved PrimalScheme3 analysis.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class PrimerSchemeSaveCommandTests: XCTestCase {
    private let analysisURL = URL(
        fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/Analyses/Saved design.lungfishprimeranalysis",
        isDirectory: true
    )
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1k3/Project.lungfish", isDirectory: true)
    private let resultID = UUID()
    private var root: URL?

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func rowCommand(name: String, projectURL: URL? = nil, analysisURL: URL? = nil, resultID: UUID? = nil) -> String {
        MainSplitViewController.primerSchemeSaveCLICommand(
            analysisURL: analysisURL ?? self.analysisURL,
            resultID: resultID ?? self.resultID,
            name: name,
            projectURL: projectURL ?? self.projectURL
        )
    }

    // MARK: - The row command

    func testRowCommandParsesWithTheSaveValuesForNamesWithAnApostropheOrALeadingHyphen() throws {
        for name in ["Pat's MHC-A1 scheme", "-draft scheme", "O'Connor's \"panel\" $HOME"] {
            let command = try RecordedCLICommand.parse(
                rowCommand(name: name),
                as: PrimerCommand.SchemeFromAnalysisSubcommand.self
            )
            XCTAssertEqual(command.analysisPath, analysisURL.path)
            XCTAssertEqual(command.resultID, resultID.uuidString)
            XCTAssertEqual(command.outputPath, name, "the name reaches --output unchanged")
            XCTAssertEqual(command.projectPath, projectURL.path)
            XCTAssertNil(command.displayName, "the save passes no display name, so the CLI default applies on both paths")
            XCTAssertFalse(command.list)
        }
    }

    func testProvenanceArgvIsTheRowCommandAsWords() throws {
        let name = "Pat's MHC-A1 scheme"
        let request = MainSplitViewController.primerSchemeSaveRequest(
            analysisURL: analysisURL, resultID: resultID, name: name, projectURL: projectURL
        )

        XCTAssertEqual(
            request.argv,
            [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: rowCommand(name: name)))
        )
        XCTAssertNotEqual(request.argv, CommandLine.arguments, "the argv used to be the app process's launch arguments")
        XCTAssertEqual(request.analysisURL, analysisURL)
        XCTAssertEqual(request.resultID, resultID)
        XCTAssertEqual(request.outputURL, URL(fileURLWithPath: name))
        XCTAssertEqual(request.projectURL, projectURL)
        XCTAssertNil(request.displayName)
        XCTAssertEqual(request.workflowName, "lungfish primers scheme-from-analysis")
    }

    // MARK: - The GUI save and the recorded command write the same scheme

    func testGUISaveAndTheRecordedCommandWriteTheSameScheme() throws {
        let root = try makeRoot()
        let analysis = try makePrimalSchemeAnalysis(in: root)
        let candidate = try XCTUnwrap(PrimerSchemeFromAnalysisService.candidates(analysisURL: analysis).first)
        XCTAssertNil(candidate.refusalReason)
        let name = "Pat's MHC-A1 scheme"
        let guiProject = root.appendingPathComponent("GUI.lungfish", isDirectory: true)
        let cliProject = root.appendingPathComponent("CLI.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: guiProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliProject, withIntermediateDirectories: true)

        // The GUI path, with the request the viewport builds.
        let gui = try PrimerSchemeFromAnalysisService.export(request: MainSplitViewController.primerSchemeSaveRequest(
            analysisURL: analysis, resultID: candidate.resultID, name: name, projectURL: guiProject
        ))
        // The command the row records for a second project, run through the real CLI parser.
        let cliRow = rowCommand(name: name, projectURL: cliProject, analysisURL: analysis, resultID: candidate.resultID)
        let command = try RecordedCLICommand.parse(cliRow, as: PrimerCommand.SchemeFromAnalysisSubcommand.self)
        let cli = try command.executeForTesting(
            argv: [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: cliRow))
        )

        XCTAssertEqual(gui.bundleURL.lastPathComponent, "\(name).lungfishprimers")
        XCTAssertEqual(cli.bundleURL.lastPathComponent, gui.bundleURL.lastPathComponent)
        XCTAssertEqual(
            gui.bundleURL.deletingLastPathComponent().standardizedFileURL,
            guiProject.appendingPathComponent(PrimerSchemesFolder.folderName, isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(
            cli.bundleURL.deletingLastPathComponent().standardizedFileURL,
            cliProject.appendingPathComponent(PrimerSchemesFolder.folderName, isDirectory: true).standardizedFileURL
        )

        let guiBundle = try PrimerSchemeBundle.load(from: gui.bundleURL)
        let cliBundle = try PrimerSchemeBundle.load(from: cli.bundleURL)
        XCTAssertEqual(try Data(contentsOf: cliBundle.bedURL), try Data(contentsOf: guiBundle.bedURL))
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(cliBundle.fastaURL)),
            try Data(contentsOf: try XCTUnwrap(guiBundle.fastaURL))
        )
        let reference = "attachments/design-reference.fasta"
        XCTAssertEqual(
            try Data(contentsOf: cli.bundleURL.appendingPathComponent(reference)),
            try Data(contentsOf: gui.bundleURL.appendingPathComponent(reference))
        )
        let guiManifest = guiBundle.manifest, cliManifest = cliBundle.manifest
        XCTAssertEqual(cliManifest.name, guiManifest.name)
        XCTAssertEqual(cliManifest.displayName, guiManifest.displayName)
        XCTAssertEqual(cliManifest.description, guiManifest.description)
        XCTAssertEqual(cliManifest.referenceAccessions, guiManifest.referenceAccessions)
        XCTAssertEqual(cliManifest.primerCount, guiManifest.primerCount)
        XCTAssertEqual(cliManifest.ampliconCount, guiManifest.ampliconCount)
        XCTAssertEqual(cliManifest.source, guiManifest.source)
        XCTAssertEqual(cliManifest.attachments, guiManifest.attachments)

        // The scheme's provenance names the command the GUI row records.
        let guiRow = rowCommand(name: name, projectURL: guiProject, analysisURL: analysis, resultID: candidate.resultID)
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: gui.bundleURL))
        XCTAssertEqual(
            Self.readerPaths(envelope.argv),
            Self.readerPaths([CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: guiRow)))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish primers scheme-from-analysis")
        let markdown = try String(contentsOf: guiBundle.provenanceURL, encoding: .utf8)
        XCTAssertTrue(
            markdown.contains("Command: \(CLICommandIdentity.executableName) primers scheme-from-analysis "),
            markdown
        )
    }

    // MARK: - Fixtures

    /// A provenance write and read returns a `/private/var` path as `/var`,
    /// so the argv words are compared in that form.
    private static func readerPaths(_ words: [String]) -> [String] {
        words.map { $0.hasPrefix("/private/var/") ? String($0.dropFirst("/private".count)) : $0 }
    }

    private func makeRoot() throws -> URL {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("primer-scheme-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        return root
    }

    /// A saved PrimalScheme3 analysis with one exportable result, the fixture
    /// PrimerSchemeFromAnalysisServiceTests writes.
    private func makePrimalSchemeAnalysis(in root: URL) throws -> URL {
        let inputID = UUID(), resultID = UUID()
        let hex = inputID.uuidString.replacingOccurrences(of: "-", with: "")
        let row0 = "input_\(hex)_row_0", row1 = "input_\(hex)_row_1"
        let native = "native/\(resultID.uuidString)/"
        let payloads: [String: String] = [
            "inputs/\(inputID.uuidString).fasta": ">\(row0)\nAACC-GGTTAACCGGTT\n>\(row1)\nAACCTGGTTAACCGGTT\n",
            "inputs/\(inputID.uuidString)-row-map.json": """
            {"schemaVersion":1,"inputID":"\(inputID.uuidString)","rows":[
            {"rowIndex":0,"originalHeader":"Mamu-A1_001 first allele","normalizedHeader":"\(row0)"},
            {"rowIndex":1,"originalHeader":"Mamu-A1_002","normalizedHeader":"\(row1)"}]}
            """,
            native + "reference.fasta": ">\(row0)\nAACCGGTTAACCGGTT\n",
            native + "primer.bed": "# artic-bed-version v3.0\n\(row0)\t2\t5\tfx_1_LEFT_1\t1\t+\tCCG\n"
                + "\(row0)\t1\t5\tfx_1_LEFT_2\t1\t+\tACCG\n\(row0)\t9\t12\tfx_1_RIGHT_1\t1\t-\tGGT\n",
            native + "amplicon.bed": "\(row0)\t1\t12\tfx_1\t1\n",
        ]
        let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
            let source = root.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: source)
            return PrimerAnalysisSourceArtifact(
                sourceURL: source,
                relativePath: path,
                role: path.hasPrefix("inputs/") ? "input" : "nativeOutput",
                format: path.hasSuffix(".bed") ? "bed" : path.hasSuffix(".json") ? "json" : "fasta"
            )
        }
        let written = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: inputID, label: "Mamu-A1.lungfishmsa",
                artifactPaths: payloads.keys.filter { $0.hasPrefix("inputs/") }.sorted())],
            results: [.init(id: resultID, label: "Mamu-A1", inputIDs: [inputID],
                artifactPaths: payloads.keys.filter { $0.hasPrefix(native) }.sorted())],
            artifacts: artifacts,
            destinationURL: root.appendingPathComponent("Saved design.lungfishprimeranalysis"),
            invocation: .init(argv: ["fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())
        ))
        return written.url
    }
}
