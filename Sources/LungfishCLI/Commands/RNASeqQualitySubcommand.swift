// RNASeqQualitySubcommand.swift - `lungfish-cli rnaseq quality` (Phase 5.4 lane RS-BULK-VIEW M1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

/// Prints the quality numbers or the sample correlation of a bulk result, as `RNASeqQualitySummary` and
/// `RNASeqSampleCorrelation` give them, so the app's quality view has a CLI output to equal. It writes nothing into the
/// project, so it records no provenance (policy `cli.rnaseq.quality`, inspect only).
struct RNASeqQualitySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quality",
        abstract: "Print the quality numbers and the sample correlation of a bulk RNA-seq result",
        discussion: "Checks each file of the result against the sha256 its manifest lists, then prints one table and writes nothing. "
            + "--table samples gives each sample's library size, mapping rate and library type, and the shares on rRNA genes "
            + "and not-host features. The globin share reads Not recorded, since LGE names no globin genes yet. "
            + "--table correlation gives Pearson r of log2(CPM + 1) between the samples, on the features that the manifest does not "
            + "list under notHost. --format tsv prints the table alone, json one document, and text a line that names the table first."
    )

    enum Table: String, ExpressibleByArgument, CaseIterable {
        case samples, correlation
    }

    @Argument(help: "A bulk .lungfishrnaseq result")
    var resultPath: String

    @Option(name: .customLong("table"), help: "The table to print")
    var table: Table = .samples

    @OptionGroup var globalOptions: GlobalOptions

    var resultURL: URL { URL(fileURLWithPath: resultPath).standardizedFileURL }

    /// The command in one fixed order with an absolute path. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        [CLICommandIdentity.executableName, "rnaseq", "quality", resultURL.path, "--table", table.rawValue,
         "--format", globalOptions.outputFormat.rawValue]
    }

    func run() async throws {
        do {
            print(try render(), terminator: "")
        } catch {
            FileHandle.standardError.write(Data("Error: \(CLIFailureWords.describe(error))\n".utf8))
            throw (error is RNASeqQualityRefusal ? CLIExitCode.inputError : CLIExitCode.workflowError).exitCode
        }
    }

    /// The text the leaf prints, which ends in a line break.
    func render() throws -> String {
        let document: RNASeqQualityDocument
        let caption: String
        switch table {
        case .samples:
            let summary = try RNASeqQualitySummary.read(resultAt: resultURL)
            (document, caption) = (summary.document(), summary.caption)
        case .correlation:
            let correlation = try RNASeqSampleCorrelation.read(resultAt: resultURL)
            (document, caption) = (correlation.document(), correlation.caption)
        }
        switch globalOptions.outputFormat {
        case .json: return try document.jsonText() + "\n"
        case .tsv: return document.tsvText()
        case .text: return caption + "\n" + document.tsvText()
        }
    }
}
