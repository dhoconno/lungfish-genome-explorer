// VariantsCommand+CallGATK.swift - `variants call --caller gatk`, GATK HaplotypeCaller attached to a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The GATK options of `variants call`. Their defaults are the values the Call Variants dialog's GATK row
/// runs with, so a run with no GATK flag equals a dialog run (Phase 2.11 lane A50, BIO objections 2 and 3):
/// reference confidence NONE and the configuration's defaults. `--ploidy` and `--extra-args` are the
/// command's own options. No GATK option rides in `--extra-args`, which holds only the free text of the
/// dialog's Extra arguments field.
struct VariantsCallGATKOptions: ParsableArguments {
    @Option(name: .customLong("emit-ref-confidence"), help: "GATK: reference confidence mode, NONE or GVCF. NONE writes a plain VCF of the called variants.")
    var emitReferenceConfidence: String = GATKEmitReferenceConfidence.none.rawValue

    @Option(name: .customLong("intervals"), help: "GATK: optional intervals file, a BED file or an interval list. The value is read as a file path, so a contig name or a region such as chr1:1-100 is not accepted")
    var intervals: String?

    @Option(name: .customLong("pcr-indel-model"), help: "GATK: PCR indel model")
    var pcrIndelModel: String = "CONSERVATIVE"

    @Option(name: .customLong("stand-call-conf"), help: "GATK: calling confidence threshold, used when reference confidence is NONE")
    var standCallConf: Double = 30.0

    @Option(name: .customLong("max-alternate-alleles"), help: "GATK: maximum alternate alleles")
    var maxAlternateAlleles: Int = 6

    @Option(name: .customLong("pair-hmm-threads"), help: "GATK: native PairHMM threads")
    var pairHMMThreads: Int = 4
}

extension VariantsCommand.CallSubcommand {
    /// The runner of a live GATK call, on the managed gatk-core environment. It carries the time limit of the run
    /// (`--time-limit`), so the limit the track's record names is the one the launch had. `.infinity` is no limit.
    static func liveRunner() -> ManagedGATKCommandRunner {
        ManagedGATKCommandRunner(timeout: AnalysisTimeLimit.launchTimeout)
    }

    /// The GATK call on the managed gatk-core environment. The tool version is the one the installed GATK
    /// answers, as `gatk haplotype-caller --execute` records it.
    func executeGATKLive(
        emitEvent: @escaping (VariantsCommand.VariantCallingEvent) -> Void
    ) async throws -> GATKBundleVariantAttachmentResult {
        try await executeGATK(
            runner: Self.liveRunner(),
            toolVersion: await GATKCLICommand.resolvedToolVersion(execute: true),
            runtimeIdentity: GATKCLICommand.defaultRuntimeIdentity(),
            recordedArguments: recordedCommandLine(),
            emitEvent: emitEvent
        )
    }

    /// Runs GATK HaplotypeCaller on the bundle's alignment track with `GATKPipelineExecutor`, then attaches
    /// the VCF as a variant track with `GATKBundleVariantAttachmentService`, as the Inspector's GATK row does.
    /// The VCF, its index, the track's database and the records stay in `variants/gatk/`, where older bundles
    /// hold theirs. The execution record is the track's own `<track>.gatk-run.lungfish-provenance.json` (2.13
    /// lane 13.16), so a later call never replaces it. It names `recordedArguments` as the run's command and keeps the GATK
    /// command of every step. `outputExtension` is `vcf.gz` as the dialog writes it, and a test with a
    /// stand-in runner passes `vcf`.
    func executeGATK<Runner: GATKCommandRunning>(
        runner: Runner,
        toolVersion: String,
        runtimeIdentity: GATKRuntimeIdentity,
        recordedArguments: [String],
        outputExtension: String = "vcf.gz",
        emitEvent: @escaping (VariantsCommand.VariantCallingEvent) -> Void
    ) async throws -> GATKBundleVariantAttachmentResult {
        try rejectOptionsGATKIgnores()
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let extraArguments = try GATKCLICommand.parseExtraArgs(advancedOptions)
        let alignmentID = try Self.resolveAlignmentTrackID(alignmentTrackID, bundleURL: bundleURL)
        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw CLIError.validationFailed(errors: ["Could not read the bundle manifest at \(bundleURL.path): \(error.localizedDescription)"])
        }
        guard let track = manifest.alignments.first(where: { $0.id == alignmentID }) else {
            throw CLIError.validationFailed(errors: ["Alignment track '\(alignmentID)' not found."])
        }
        guard let genome = manifest.genome else {
            throw CLIError.validationFailed(errors: ["Bundle does not expose a reference genome."])
        }
        let referenceURL = try BundleManifest.validatedBundleMemberURL(for: genome.path, in: bundleURL, field: "genome.path")
        let bamPath = try ReferenceBundle(url: bundleURL, manifest: manifest).resolveAlignmentPath(track)
        for path in [referenceURL.path, bamPath] where !FileManager.default.fileExists(atPath: path) {
            throw CLIError.inputFileNotFound(path: path)
        }
        guard let emitConfidence = GATKEmitReferenceConfidence(rawValue: gatkOptions.emitReferenceConfidence.uppercased()) else {
            throw ValidationError("--emit-ref-confidence must be NONE or GVCF, not '\(gatkOptions.emitReferenceConfidence)'.")
        }
        let gatkPloidy = ploidy ?? 2
        guard gatkPloidy >= 1 else { throw ValidationError("--ploidy must be at least 1 for --caller gatk.") }

        // The dialog suggests "<alignment> • GATK HaplotypeCaller" and numbers a name the bundle already holds.
        let requestedName = outputTrackName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingNames = Set(manifest.variants.map(\.name))
        var trackName = requestedName
        if trackName.isEmpty {
            let base = "\(track.name) \u{2022} GATK HaplotypeCaller"
            trackName = base
            var suffix = 2
            while existingNames.contains(trackName) {
                trackName = "\(base) (\(suffix))"
                suffix += 1
            }
        }
        let outputTrackID = "vc-\(UUID().uuidString.lowercased())"
        let outputURL = bundleURL
            .appendingPathComponent("variants/gatk", isDirectory: true)
            .appendingPathComponent("\(outputTrackID).\(outputExtension)")
        let configuration = GATKHaplotypeCallerConfiguration(
            referenceFASTAURL: referenceURL,
            inputBAMURL: URL(fileURLWithPath: bamPath),
            outputVCFURL: outputURL,
            emitReferenceConfidence: emitConfidence,
            ploidy: gatkPloidy,
            intervalsURL: gatkOptions.intervals.map { URL(fileURLWithPath: $0) },
            pcrIndelModel: gatkOptions.pcrIndelModel,
            standardMinConfidenceThresholdForCalling: gatkOptions.standCallConf,
            maxAlternateAlleles: gatkOptions.maxAlternateAlleles,
            nativePairHMMThreads: gatkOptions.pairHMMThreads,
            extraArguments: extraArguments
        )
        let request = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: configuration,
            toolVersion: toolVersion,
            runtimeIdentity: runtimeIdentity
        )
        .recording(cliCommandLine: recordedArguments)
        .recording(recordAt: GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: outputTrackID, inBundle: bundleURL))

        func event(
            _ name: String, _ progress: Double?, _ message: String,
            attachment: GATKBundleVariantAttachmentResult? = nil
        ) -> VariantsCommand.VariantCallingEvent {
            VariantsCommand.VariantCallingEvent(
                event: name,
                progress: progress,
                message: message,
                bundlePath: bundleURL.path,
                variantTrackID: attachment?.trackInfo.id,
                variantTrackName: attachment?.trackInfo.name,
                caller: "gatk",
                vcfPath: attachment.map { bundleURL.appendingPathComponent($0.trackInfo.path).path },
                tbiPath: attachment?.indexURL.path,
                databasePath: attachment?.databaseURL.path,
                importedVariantCount: attachment?.variantCount,
                provenancePath: name == "runComplete" ? attachment?.provenanceURL.path : nil
            )
        }

        do {
            emitEvent(event("runStart", 0.0, "Running GATK HaplotypeCaller..."))
            let result = try await GATKPipelineExecutor(runner: runner).run(request)
            // The attach steps report progress, so the row's bar moves as the in-process route's did.
            emitEvent(event("stageProgress", 0.75, "Attaching GATK variants to bundle..."))
            let attachment = try await GATKBundleVariantAttachmentService().attach(
                request: GATKBundleVariantAttachmentRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: alignmentID,
                    outputTrackID: outputTrackID,
                    outputTrackName: trackName,
                    outputVCFURL: outputURL,
                    executionProvenanceURL: result.provenanceURL,
                    executionRequest: request,
                    invocationArgv: recordedArguments
                )
            )
            emitEvent(event("stageProgress", 0.97, "Attached variant track \(attachment.trackInfo.name)", attachment: attachment))
            emitEvent(event("runComplete", 1.0, "Variant calling complete", attachment: attachment))
            return attachment
        } catch {
            emitEvent(event("runFailed", nil, error.localizedDescription))
            throw error
        }
    }

    /// An option that GATK HaplotypeCaller has no use for is refused, as `--platform` is for the callers
    /// that choose no model by it, so a value the user typed never goes unread.
    private func rejectOptionsGATKIgnores() throws {
        let ignored: [(option: String, given: Bool)] = [
            ("--min-af", minimumAlleleFrequency != nil),
            ("--min-depth", minimumDepth != nil),
            ("--medaka-model", medakaModel != nil),
            ("--platform", platform != nil),
            ("--ivar-primer-trimmed", ivarPrimerTrimConfirmed),
        ]
        if let refused = ignored.first(where: \.given) {
            throw ValidationError(
                "\(refused.option) does not apply to --caller gatk. GATK takes --ploidy, --emit-ref-confidence, --intervals, "
                    + "--pcr-indel-model, --stand-call-conf, --max-alternate-alleles, --pair-hmm-threads and --extra-args."
            )
        }
    }
}
