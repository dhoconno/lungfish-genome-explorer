// PrimerDesignDefaultsPinTests.swift - A no-flag `primers design` run takes the dialog's defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A67 M1, BIO risk BR13. The recorded command of a primer design row is built from the
// dialog's settings. A builder that left out a flag would let the command replay with the CLI's own
// default, so these pins show first, at the base, which parameters a run with no flag but its inputs
// takes, and that they equal the parameters an untouched dialog sends. Each case compares the typed
// options the command resolves with the typed options the dialog builds. For Olivar and varVAMP it
// compares the resolved parameters the run records, since the dialog marks every option as supplied
// and a command can only mark the flags it names.

import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import XCTest
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class PrimerDesignDefaultsPinTests: XCTestCase {
    private static let input = "/input/mhc.fasta"
    private static let output = "/tmp/out.lungfishprimeranalysis"

    private func dialog(_ engine: PrimerDesignEngine) -> PrimerDesignDialogState {
        let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
        state.engine = engine
        state.addInputs([URL(fileURLWithPath: Self.input)])
        return state
    }

    /// The resolved parameters a Olivar or varVAMP run records, without the names the caller supplied.
    private func resolved(_ options: PrimerSchemeDesignOptions) -> [String: ParameterValue] {
        var result: [String: ParameterValue] = [:]
        for key in ["common", "olivar", "varvamp"] {
            guard case .dictionary(let section)? = options.provenanceOptions[key],
                  let values = section["resolved"] else { continue }
            result[key] = values
        }
        return result
    }

    func testPrimer3NoFlagRunTakesTheDialogsDefaultsForEveryAssay() throws {
        let cases: [(PrimerDesignChemistry, String)] = [
            (.pcr, "pcr"), (.intercalatingDye, "qpcr-dye"), (.hydrolysisProbe, "qpcr-probe"),
        ]
        for (chemistry, assay) in cases {
            let state = dialog(.primer3)
            state.chemistry = chemistry
            let command = try PrimerDesignCommand.Primer3Subcommand.parse(
                ["--fasta-record", Self.input + "@0", "--output", Self.output, "--assay", assay])
            XCTAssertEqual(try command.makeOptions(), try state.primer3Options(), "assay \(assay)")
        }
    }

    func testPrimalSchemeNoFlagRunTakesTheDialogsDefaultsForBothGroupings() throws {
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let state = dialog(.primalScheme)
            state.grouping = grouping
            let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse(
                ["--msa", Self.input, "--output", Self.output, "--grouping", grouping.rawValue])
            let run = try command.makeOptions()
            XCTAssertEqual(run.grouping, grouping)
            XCTAssertEqual(run.options, try state.primalSchemeOptions(), "grouping \(grouping.rawValue)")
        }
    }

    func testOlivarNoFlagRunTakesTheDialogsDefaultsForBothGroupings() throws {
        for grouping in [PrimerAnalysisGrouping.independent, .combined] {
            let state = dialog(.olivar)
            state.grouping = grouping
            let command = try OlivarDesignCommand.parse(
                ["--msa", Self.input, "--output", Self.output, "--grouping", grouping.rawValue])
            XCTAssertEqual(
                resolved(try command.makeOptions()), resolved(try state.primerSchemeOptions()),
                "grouping \(grouping.rawValue)")
        }
    }

    /// The one engine whose no-flag run does not take the dialog's defaults. The dialog sends every
    /// varVAMP config override with a value of its own (for example PRIMER_TMP 56 to 63 and
    /// PRIMER_SIZES 18 to 24), and a run with no override flag sends none, so varVAMP applies its
    /// own config. A recorded command must therefore name every override the dialog sends.
    func testVarVAMPNoFlagRunSendsNoConfigOverridesWhereTheDialogSendsEvery() throws {
        for mode in [PrimerSchemeMode.tiled, .single, .qpcr] {
            let state = dialog(.varVAMP)
            state.schemeMode = mode
            var flags = ["--msa", Self.input, "--output", Self.output, "--mode", mode.rawValue]
            if mode == .qpcr {
                // qPCR has no default threshold, so the command must name it as the dialog does.
                state.varVAMPConsensusThreshold = "0.95"
                flags += ["--consensus-threshold", "0.95"]
            }
            let command = try VarVAMPDesignCommand.parse(flags)
            let run = resolved(try command.makeOptions())
            let dialogValues = resolved(try state.primerSchemeOptions())
            XCTAssertEqual(withoutOverrides(run), withoutOverrides(dialogValues), "mode \(mode.rawValue)")
            XCTAssertEqual(overrides(run), [:], "mode \(mode.rawValue)")
            XCTAssertTrue(overrides(dialogValues).keys.contains("PRIMER_TMP"), "mode \(mode.rawValue)")
            XCTAssertTrue(overrides(dialogValues).keys.contains("PRIMER_SIZES"), "mode \(mode.rawValue)")
        }
    }

    private func overrides(_ values: [String: ParameterValue]) -> [String: ParameterValue] {
        guard case .dictionary(let varvamp)? = values["varvamp"],
              case .dictionary(let overrides)? = varvamp["configOverrides"] else { return [:] }
        return overrides
    }

    private func withoutOverrides(_ values: [String: ParameterValue]) -> [String: ParameterValue] {
        var copy = values
        if case .dictionary(var varvamp)? = copy["varvamp"] {
            varvamp["configOverrides"] = nil
            copy["varvamp"] = .dictionary(varvamp)
        }
        return copy
    }
}
