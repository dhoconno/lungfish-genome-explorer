// PrimerDesignCommandRoundTripTests.swift - The recorded `primers design` command resolves to the dialog's parameters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A67 M1, row primer-design and BIO risk BR13. PrimerDesignCLIArguments builds the
// command from the typed options the dialog builds. Each case parses that command with the real
// command type of its engine and shows that the options the command resolves equal the dialog's,
// for untouched dialogs and for edited ones. For Olivar and varVAMP the names the caller supplied
// are left out of the comparison, since a command can only name the flags it holds.

import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import XCTest
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class PrimerDesignCommandRoundTripTests: XCTestCase {
    private static let input = URL(fileURLWithPath: "/input/mhc.fasta")
    private static let output = URL(fileURLWithPath: "/tmp/out dir/out.lungfishprimeranalysis")

    private func dialog(_ engine: PrimerDesignEngine) -> PrimerDesignDialogState {
        let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
        state.engine = engine
        state.addInputs([Self.input])
        return state
    }

    private func normalized(_ options: PrimerSchemeDesignOptions) -> PrimerSchemeDesignOptions {
        var copy = options
        copy.suppliedOptionNames = []
        copy.olivar?.suppliedOptionNames = []
        copy.varvamp?.suppliedOptionNames = []
        return copy
    }

    // MARK: - Primer3

    private func assertPrimer3RoundTrip(_ state: PrimerDesignDialogState, file: StaticString = #filePath, line: UInt = #line) throws {
        let options = try state.primer3Options()
        let selections: [Primer3TemplateSelection] = [
            .fastaRecord(inputURL: Self.input, recordIndex: 0), .fastaRecord(inputURL: Self.input, recordIndex: 2),
        ]
        let args = try XCTUnwrap(
            PrimerDesignCLIArguments.primer3(selections: selections, output: Self.output, options: options),
            file: file, line: line)
        let command = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "primers design primer3", args: args),
            as: PrimerDesignCommand.Primer3Subcommand.self, file: file, line: line)
        XCTAssertEqual(try command.makeOptions(), options, file: file, line: line)
        XCTAssertEqual(command.fastaRecords, [Self.input.path + "@0", Self.input.path + "@2"], file: file, line: line)
        XCTAssertEqual(command.outputPath, Self.output.path, file: file, line: line)
    }

    func testPrimer3CommandResolvesToTheDialogsOptionsForEveryAssay() throws {
        for chemistry in PrimerDesignChemistry.allCases {
            let state = dialog(.primer3)
            state.chemistry = chemistry
            try assertPrimer3RoundTrip(state)
        }
    }

    func testPrimer3CommandKeepsEditedValuesTheTargetAndTheZeroProbeOffset() throws {
        let state = dialog(.primer3)
        state.chemistry = .hydrolysisProbe
        state.pairCount = "8"
        state.productSizeMin = "90"
        state.primerOptTm = "61.5"
        state.primerMaxPolyX = "3"
        state.targetEnabled = true
        state.targetStart = "120"
        state.targetEnd = "180"
        state.forceLeftEnd = "150"
        state.probeMinTmOffsetOverPrimers = "0"
        try assertPrimer3RoundTrip(state)

        let pcr = dialog(.primer3)
        pcr.primerMaxEndGC = "2"
        pcr.pairMaxTmDifference = "3.5"
        try assertPrimer3RoundTrip(pcr)
    }

    func testPrimer3CommandNamesAnMSATemplateAndItsBindingPolicy() throws {
        let state = dialog(.primer3)
        let template = URL(fileURLWithPath: "/input/panel.lungfishmsa")
        let args = try XCTUnwrap(PrimerDesignCLIArguments.primer3(
            selections: [.msaTemplate(inputURL: template, rowIndex: 3, bindingSitePolicy: .templateOnly)],
            output: Self.output, options: try state.primer3Options()))
        let command = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "primers design primer3", args: args),
            as: PrimerDesignCommand.Primer3Subcommand.self)
        XCTAssertEqual(command.msaTemplates, [template.path + "@3"])
        XCTAssertEqual(command.bindingSitePolicy, "template-only")
    }

    func testPrimer3HasNoCommandForAPresetRuleTheDialogCleared() throws {
        let state = dialog(.primer3)
        state.chemistry = .intercalatingDye
        state.primerMaxPolyX = ""
        // The command takes the preset's value for a missing flag and cannot clear it.
        XCTAssertNil(PrimerDesignCLIArguments.primer3(
            selections: [.fastaRecord(inputURL: Self.input, recordIndex: 0)],
            output: Self.output, options: try state.primer3Options()))
    }

    // MARK: - PrimalScheme3

    func testPrimalSchemeCommandResolvesToTheDialogsOptionsAndNamesAChosenExecutable() throws {
        let state = dialog(.primalScheme)
        state.grouping = .combined
        state.primalschemeExecutablePath = "/usr/bin/true"
        let command = try XCTUnwrap(PrimerDesignOperation.cliCommand(state: state, destination: Self.output))
        let parsed = try RecordedCLICommand.parse(command, as: PrimerDesignCommand.PrimalScheme3Subcommand.self)
        let run = try parsed.makeOptions()
        XCTAssertEqual(run.options, try state.primalSchemeOptions())
        XCTAssertEqual(run.grouping, .combined)
        XCTAssertEqual(parsed.executablePath, "/usr/bin/true")
        XCTAssertEqual(parsed.msaPaths, [Self.input.path])
        XCTAssertEqual(parsed.outputPath, Self.output.path)
    }

    // MARK: - Olivar and varVAMP

    private func assertOlivarRoundTrip(_ state: PrimerDesignDialogState, file: StaticString = #filePath, line: UInt = #line) throws {
        let command = try XCTUnwrap(PrimerDesignOperation.cliCommand(state: state, destination: Self.output), file: file, line: line)
        let parsed = try RecordedCLICommand.parse(command, as: OlivarDesignCommand.self, file: file, line: line)
        let args = try RecordedCLICommand.arguments(of: command)
        XCTAssertEqual(
            normalized(try parsed.makeOptions(argv: args)), normalized(try state.primerSchemeOptions()), file: file, line: line)
        XCTAssertEqual(parsed.msaPaths, [Self.input.path], file: file, line: line)
        XCTAssertEqual(parsed.outputPath, Self.output.path, file: file, line: line)
    }

    private func assertVarVAMPRoundTrip(_ state: PrimerDesignDialogState, file: StaticString = #filePath, line: UInt = #line) throws {
        let command = try XCTUnwrap(PrimerDesignOperation.cliCommand(state: state, destination: Self.output), file: file, line: line)
        let parsed = try RecordedCLICommand.parse(command, as: VarVAMPDesignCommand.self, file: file, line: line)
        let args = try RecordedCLICommand.arguments(of: command)
        XCTAssertEqual(
            normalized(try parsed.makeOptions(argv: args)), normalized(try state.primerSchemeOptions()), file: file, line: line)
        XCTAssertEqual(parsed.msaPaths, [Self.input.path], file: file, line: line)
        XCTAssertEqual(parsed.outputPath, Self.output.path, file: file, line: line)
    }

    func testOlivarCommandResolvesToTheDialogsParameters() throws {
        let state = dialog(.olivar)
        try assertOlivarRoundTrip(state)
        state.grouping = .combined
        state.olivarDegenerate = true
        state.olivarCheckVariants = true
        state.olivarSeed = "7"
        state.olivarEffort = "2"
        state.olivarRiskVariation = "2.5"
        state.ampliconSize = "420"
        try assertOlivarRoundTrip(state)
    }

    func testVarVAMPCommandNamesEveryConfigOverrideAndResolvesToTheDialogsParametersInEveryMode() throws {
        for mode in [PrimerSchemeMode.tiled, .single, .qpcr] {
            let state = dialog(.varVAMP)
            state.schemeMode = mode
            if mode == .qpcr { state.varVAMPConsensusThreshold = "0.95" }
            try assertVarVAMPRoundTrip(state)
            let command = try XCTUnwrap(PrimerDesignOperation.cliCommand(state: state, destination: Self.output))
            XCTAssertTrue(command.contains("--primer-tm-min=56"), "\(mode): \(command)")
            XCTAssertTrue(command.contains("--primer-size-max=24"), "\(mode): \(command)")
        }
        let edited = dialog(.varVAMP)
        edited.schemeMode = .single
        edited.varVAMPConsensusThreshold = "0.9"
        edited.varVAMPReportCount = "3"
        edited.varVAMPPrimerTmMinimum = "55.5"
        try assertVarVAMPRoundTrip(edited)
    }
}
