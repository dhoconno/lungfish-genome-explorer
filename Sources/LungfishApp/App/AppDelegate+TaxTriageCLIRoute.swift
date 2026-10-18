// AppDelegate+TaxTriageCLIRoute.swift - The TaxTriage launch through lungfish-cli taxtriage run, behind its key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the TaxTriage CLI route runs for one launch of the FASTQ operations dialog (Phase 2.11 lane
/// U30, panel decision K1). Every launch takes it since Phase 2.12 K1 deleted the hidden key and the
/// in-process route, and the run takes the classifier CLI route's one row path.
///
/// The argv is `taxtriage run` with the words the in-process route's row recorded for one sample
/// until Phase 2.12 K1, and `--project` in place of `--output`, the words the
/// parity class's side C runs (2.8 T17). The command then makes `Analyses/taxtriage-batch-<timestamp>/`
/// in the project, as the legacy route does for one sample too (UX F7). Several samples take one
/// `--input` each, in the dialog's order, and `--batch`, so each sample runs alone in its own folder as
/// the legacy serial batch does. A sample of one file takes that file. A pair takes the FASTQ bundle
/// that holds both files, which the command plans as a pair, since `--input2` names the mate of one
/// `--input` only. Each sample the dialog marks as a negative control takes `--negative-control`, so the
/// argv carries every effective parameter, as BIO's 2.10 requirement asks. The row records this argv,
/// the one the transport runs.
extension ClassifierCLIRouteLaunch {
    /// The launch of `config` into `projectURL`, or nil for a config with no sample.
    ///
    /// - Throws: ``TaxTriageCLIRouteRefusal`` when one `taxtriage run` argv cannot carry the samples
    ///   as the dialog shows them.
    static func taxTriage(config: TaxTriageConfig, projectURL: URL) throws(TaxTriageCLIRouteRefusal) -> ClassifierCLIRouteLaunch? {
        let samples = config.samples
        guard let first = samples.first else { return nil }
        var arguments = ["taxtriage", "run"]
        let sampleIDs: [String]
        if samples.count == 1 {
            arguments += ["--input", first.fastq1.path]
            if let fastq2 = first.fastq2 {
                arguments += ["--input2", fastq2.path]
            }
            arguments += ["--sample", first.sampleId]
            sampleIDs = [first.sampleId]
        } else {
            var inputs: [URL] = []
            for sample in samples {
                inputs.append(try taxTriageBatchInput(of: sample))
            }
            // The command names each of several inputs itself, so the names come from the command.
            sampleIDs = inputs.map {
                TaxTriageAnalysisRunTool.sampleID(for: $0, explicitSampleID: nil, totalSampleCount: inputs.count)
            }
            try refuseRenamedSamples(samples, commandNames: sampleIDs)
            arguments += inputs.flatMap { ["--input", $0.path] }
        }
        arguments += ["--project", projectURL.path]
        if samples.count > 1 {
            arguments.append("--batch")
        }
        for (sample, name) in zip(samples, sampleIDs) where sample.isNegativeControl {
            arguments += ["--negative-control", name]
        }
        arguments += taxTriageSettings(of: config, platform: samples.count == 1 ? first.platform : config.platform)
        arguments += ["--format", "json"]
        let sampleCount = samples.count
        return ClassifierCLIRouteLaunch(
            tool: .taxTriage,
            arguments: arguments,
            title: "TaxTriage (\(sampleCount) sample\(sampleCount == 1 ? "" : "s"))",
            firstDetail: "Starting TaxTriage pipeline\u{2026}",
            sampleIDs: sampleIDs,
            extractsReads: false
        )
    }

    /// The `--input` of one sample of several. A pair takes the FASTQ bundle that holds both files.
    private static func taxTriageBatchInput(of sample: TaxTriageSample) throws(TaxTriageCLIRouteRefusal) -> URL {
        guard let fastq2 = sample.fastq2 else { return sample.fastq1 }
        guard let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: sample.fastq1),
              SequenceInputResolver.enclosingFASTQBundleURL(for: fastq2)?.standardizedFileURL == bundle.standardizedFileURL else {
            throw .pairOutsideABundle(sampleID: sample.sampleId)
        }
        return bundle
    }

    /// Refuses several samples that the command would not name as the dialog does, first two samples
    /// that would share one name and then a sample whose name would change (U30 M1 review, item 2).
    private static func refuseRenamedSamples(_ samples: [TaxTriageSample], commandNames: [String]) throws(TaxTriageCLIRouteRefusal) {
        var firstNamed: [String: String] = [:]
        for (sample, name) in zip(samples, commandNames) {
            if let other = firstNamed[name] {
                throw .sharedName(first: other, second: sample.sampleId, name: name)
            }
            firstNamed[name] = sample.sampleId
        }
        for (sample, name) in zip(samples, commandNames) where sample.sampleId != name {
            throw .renamed(sampleID: sample.sampleId, commandName: name)
        }
    }

    /// The settings words, in the order and spelling of the legacy row's command.
    private static func taxTriageSettings(of config: TaxTriageConfig, platform: TaxTriageConfig.Platform) -> [String] {
        var arguments: [String] = []
        if let databasePath = config.kraken2DatabasePath {
            arguments += ["--db", databasePath.path]
        }
        arguments += ["--platform", platform.rawValue.lowercased()]
        arguments += ["--confidence", String(config.k2Confidence)]
        arguments += ["--top-hits", String(config.topHitsCount)]
        arguments += ["--rank", config.rank]
        if !config.skipAssembly {
            arguments.append("--no-skip-assembly")
        }
        if config.skipKrona {
            arguments.append("--skip-krona")
        }
        if let removeTaxids = config.effectiveRemoveTaxids {
            arguments += ["--remove-taxids", removeTaxids]
        }
        arguments += ["--max-memory", config.maxMemory]
        arguments += ["--max-cpus", String(config.maxCpus)]
        arguments += ["--nf-profile", config.profile]
        // The row names the revision the run takes, the pinned commit when the config names none (N4).
        if let revision = config.revision ?? (try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())?.revision {
            arguments += ["--revision", revision]
        }
        if !config.extraArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        return arguments
    }
}

/// Why the TaxTriage CLI route refuses a launch before it starts anything, in words (owner direction
/// of 2026-10-15, UX U-211-1).
enum TaxTriageCLIRouteRefusal: Error, Equatable {
    /// A pair of reads of a launch of several samples whose files lie in no one FASTQ bundle.
    /// `taxtriage run` takes the mate of one `--input` only, so the argv could not keep the pair.
    case pairOutsideABundle(sampleID: String)
    /// Two samples of several that the command would give one name, which would mix their results.
    case sharedName(first: String, second: String, name: String)
    /// A sample of several that the command would name otherwise than the dialog shows it.
    case renamed(sampleID: String, commandName: String)

    var title: String {
        "TaxTriage Cannot Run These Samples"
    }

    var message: String {
        switch self {
        case .pairOutsideABundle(let sampleID):
            return "Sample \(sampleID) is a pair of FASTQ files that do not lie together in one FASTQ bundle. When TaxTriage runs several samples, it takes each pair from one bundle. Import the reads into the project, or run this sample alone."
        case let .sharedName(first, second, name):
            return "Samples \(first) and \(second) would both be named \(name) when TaxTriage runs several samples. Change a Sample ID or rename a FASTQ bundle so that the names differ, or run the samples one at a time."
        case let .renamed(sampleID, commandName):
            return "TaxTriage would name sample \(sampleID) as \(commandName) when it runs several samples, so the results would not match the name in this window. Set its Sample ID to \(commandName), rename its FASTQ bundle, or run this sample alone."
        }
    }
}

extension AppDelegate {
    // MARK: - Launch

    /// Runs the TaxTriage `config` through `lungfish-cli taxtriage run --project` with today's row
    /// title and first detail. A launch with no project open is refused with the `No Project Open`
    /// sheet and starts nothing (decision L1), and a launch one argv cannot carry is refused in words.
    /// The run then takes the classifier CLI route's row, progress, end and failure
    /// (`runClassifierThroughCLI`), which write nothing after the command returns (R1).
    func runTaxTriageThroughCLI(
        config: TaxTriageConfig,
        viewerController: ViewerViewController,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        cliURLOverride: URL? = nil
    ) {
        guard !config.samples.isEmpty else { return }
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        guard let projectURL = routeContext?.projectURL else {
            refuseClassifierLaunchWithoutProject(
                tool: FASTQOperationToolID.taxTriage.title,
                viewerController: viewerController,
                routeContext: routeContext
            )
            return
        }
        let launch: ClassifierCLIRouteLaunch
        do {
            guard let made = try ClassifierCLIRouteLaunch.taxTriage(config: config, projectURL: projectURL) else { return }
            launch = made
        } catch {
            // The refusal presenter of a classifier launch, which sits as a sheet on the window and
            // is app-modal with none (decision A4), and which a test records.
            NoProjectPresenterSeam.presenter.present(
                title: error.title,
                message: error.message,
                on: viewerController.view.window ?? targetMainWindowController(routeContext: routeContext)?.window
            )
            return
        }
        runClassifierThroughCLI(launch, viewerController: viewerController, routeContext: routeContext, cliURLOverride: cliURLOverride)
    }
}
