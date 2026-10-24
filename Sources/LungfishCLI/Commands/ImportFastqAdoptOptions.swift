// ImportFastqAdoptOptions.swift - `import fastq <result folder> --adopt`, the import of a plan folder a Linux run returned
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// `lungfish-cli import fastq <result folder> --adopt --project <project>` (CHTC C4 lane A, design section 2). The one
/// input names a plan folder that `lungfish-executor run --plan` returned. The plan fixed every setting, so each setting
/// option is refused by name, and `--name`, `--dry-run`, `--force` and `--format json` keep their meaning. The run is
/// `ExecutorRunAdoption.adopt`, the function the app's adopt entry runs through this command.
struct ImportFastqAdoptOptions: ParsableArguments {
    @Flag(
        name: .customLong("adopt"),
        help: ArgumentHelp(
            "Adopt a plan folder that a Linux run of lungfish-executor returned, as one bundle",
            discussion: """
            The one input names the returned plan folder, which holds plan.json, run-record.json and the run's \
            output. The plan fixed every setting, so no setting option is taken with --adopt. --name, --dry-run, \
            --force and --format json keep their meaning.
            """
        )
    )
    var adopt: Bool = false
}

extension ImportCommand.FastqSubcommand {
    /// Why the adopt takes no other input than one plan folder.
    private static let oneFolder = "the adopt reads one returned plan folder"
    /// Why the adopt takes no setting.
    private static let planFixed = "the plan the run followed fixed it"

    /// Each option the adopt refuses, in the order the help lists it, with whether it was given and why it is refused.
    /// An option given at its default value cannot be told from one not given, and it asks for nothing.
    var adoptRefusedOptions: [(option: String, given: Bool, reason: String)] {
        [
            ("--samplesheet", samplesheet != nil, Self.oneFolder),
            ("--platform", importOptions.platform != "auto", Self.planFixed),
            ("--pairing", importOptions.pairing != "auto", Self.planFixed),
            ("--quality-binning", importOptions.qualityBinning != nil, Self.planFixed),
            ("--compression", importOptions.compression != "balanced", Self.planFixed),
            ("--recipe", importOptions.recipe.lowercased() != "none", Self.planFixed),
            ("--remove-duplicates", importOptions.removeDuplicates != nil, Self.planFixed),
            ("--remove-ribosomal-rna", importOptions.removeRibosomalRNA != nil, Self.planFixed),
            ("--no-optimize-storage", importOptions.noOptimizeStorage, Self.planFixed),
            ("--clumping-tool", importOptions.clumpingTool != nil, Self.planFixed),
            ("--log-dir", logDir != nil, "the adopt runs no tool and writes no sample log"),
            ("--recursive", recursive, Self.oneFolder),
            ("--clumpify-heap-gb", clumpifyHeapGB != nil, Self.planFixed),
            ("--threads", threads != nil, Self.planFixed),
        ]
    }

    /// The one sentence that refuses the first option `--adopt` does not take, or a count of inputs other than one.
    var adoptRefusal: String? {
        if let refused = adoptRefusedOptions.first(where: \.given) {
            return "\(refused.option) cannot be used with --adopt, because \(refused.reason)."
        }
        guard input.count == 1 else {
            return "--adopt takes one returned plan folder, and \(input.count) inputs were given."
        }
        return nil
    }

    /// The adopt: each refusal before any bundle file, then one bundle, with the import's events under `--format json`.
    func runAdopt() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        // Landing 3: the F2 fixes made `project` optional, since `validate()` lets `--write-plan` run without one, and the
        // adopt writes its bundle into a project, so it names the same missing option the command's own run does.
        let projectDirectory = URL(fileURLWithPath: project ?? planOptions.writePlan ?? FileManager.default.currentDirectoryPath)
        let reporter = ImportFastqReporter(globalOptions: globalOptions, formatter: formatter, projectDirectory: projectDirectory)
        reporter.start()
        if let sentence = adoptRefusal {
            throw reporter.fail(sentence, exitCode: .inputError)
        }
        guard project != nil else {
            throw reporter.fail("Missing expected argument '--project <project>'", exitCode: .inputError)
        }
        let folder = URL(fileURLWithPath: input[0])
        do {
            if dryRun {
                let sample = try ExecutorRunAdoption.dryRun(
                    resultFolder: folder, projectDirectory: projectDirectory, name: name, force: force
                )
                reporter.text("\(folder.lastPathComponent) passed every check and would be adopted as \(sample).")
                reporter.complete(message: "Dry-run mode — no files were imported.")
                return
            }
            let started = Date()
            // Review A2 fix 2: the window's Cancel is a SIGTERM, so the adopt runs as `import fastq` does, under a scope
            // that turns the signal into a cancel, and its staging bundle is removed before the command exits 125.
            let (adoptName, adoptForce, eventsOn) = (name, force, reporter.eventsOn)
            let outcome = await runCancellingOnSIGTERM {
                try await ExecutorRunAdoption.adopt(
                    resultFolder: folder, projectDirectory: projectDirectory, name: adoptName, force: adoptForce,
                    eventsOn: eventsOn
                )
            }
            let bundle = try outcome.get()
            let sample = bundle.deletingPathExtension().lastPathComponent
            reporter.log(.sampleComplete(
                sample: sample, bundle: bundle.path, durationSeconds: Date().timeIntervalSince(started), originalBytes: 0,
                finalBytes: 0
            ))
            reporter.text("Adopted \(folder.lastPathComponent) as \(bundle.lastPathComponent)")
            reporter.complete(message: "Adopted 1 sample")
        } catch let refusal as ExecutorAdoptRefusal {
            throw reporter.fail(refusal.reason, exitCode: .inputError)
        } catch let error as BatchImportError {
            throw reporter.fail(error.localizedDescription, exitCode: .inputError)
        } catch is CancellationError {
            throw reporter.fail("Adopt cancelled", detail: nil, exitCode: .cancelled)
        } catch {
            throw reporter.fail("The adopt failed. \(error.localizedDescription)", exitCode: .workflowError)
        }
    }
}
