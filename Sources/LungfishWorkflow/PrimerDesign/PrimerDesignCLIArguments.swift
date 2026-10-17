import Foundation
import LungfishIO

/// The arguments after `lungfish-cli primers design <engine>` that reproduce a design run
/// from the typed options the Primer Design dialog builds (Phase 2.11 lane A67, rows
/// `primer-design` and BR13).
///
/// A run with no flag but its inputs does not take the dialog's defaults for every engine.
/// varVAMP applies its own config unless a flag names an override, while the dialog sends
/// every override with a value of its own. So each builder names every value the dialog
/// controls, and a command replays with the parameters the run used. `makeOptions()` of the
/// command resolves back to the dialog's options, which the app tests show for each engine.
/// Every option is written as `--name=value`, so a negative value is a value.
public enum PrimerDesignCLIArguments {

    // MARK: - Primer3

    /// The arguments of `primers design primer3`, or nil when the command cannot say the
    /// options. The command cannot clear a rule the assay preset sets, nor drop the probe
    /// group of a probe assay, so options that do either have no command.
    public static func primer3(
        selections: [Primer3TemplateSelection], output: URL, options: Primer3DesignOptions
    ) -> [String]? {
        let preset = Primer3AssayDefaults.defaults(for: options.assayMode)
        let clearsPresetRule = [
            options.pairMaxTmDifference == nil && preset.pairMaxTmDifference != nil,
            options.primerMaxEndGC == nil && preset.primerMaxEndGC != nil,
            options.primerGCClamp == nil && preset.primerGCClamp != nil,
            options.primerMaxPolyX == nil && preset.primerMaxPolyX != nil,
            options.primerMaxSelfAnyTh == nil && preset.primerMaxSelfAnyTh != nil,
            options.primerMaxSelfEndTh == nil && preset.primerMaxSelfEndTh != nil,
            options.pairMaxComplAnyTh == nil && preset.pairMaxComplAnyTh != nil,
            options.pairMaxComplEndTh == nil && preset.pairMaxComplEndTh != nil,
            (options.probe == nil) != (preset.probe == nil),
            !options.pickInternalOligo && options.assayMode.picksInternalOligo,
        ]
        guard !selections.isEmpty, !clearsPresetRule.contains(true) else { return nil }
        // A path is a word of its own, so a replay that moves the project folder can rebase it
        // (RouteParityHarness.rebased only moves a word that starts with the folder).
        var args = ["--assay=\(options.assayMode.rawValue)"]
        var policy: Primer3BindingSitePolicy?
        for selection in selections {
            switch selection {
            case .fastaRecord(let url, let index):
                args += ["--fasta-record", "\(url.path)@\(index)"]
            case .msaTemplate(let url, let index, let selectionPolicy):
                args += ["--msa-template", "\(url.path)@\(index)"]
                policy = policy ?? selectionPolicy
            }
        }
        if let policy {
            args.append("--binding-site-policy=" + (policy == .templateOnly
                ? "template-only" : "exclude-variable-and-gapped-columns"))
        }
        args += ["--output", output.path]
        args += [
            "--product-size-min=\(options.productSizeMin)", "--product-size-max=\(options.productSizeMax)",
        ]
        if let start = options.targetStart, let end = options.targetEnd {
            args += ["--target-start=\(start)", "--target-end=\(end)"]
        }
        args += [
            "--pair-count=\(options.pairCount)",
            "--primer-min-size=\(options.primerMinSize)", "--primer-opt-size=\(options.primerOptSize)",
            "--primer-max-size=\(options.primerMaxSize)",
            "--primer-min-tm=\(number(options.primerMinTm))", "--primer-opt-tm=\(number(options.primerOptTm))",
            "--primer-max-tm=\(number(options.primerMaxTm))",
            "--primer-min-gc=\(number(options.primerMinGC))", "--primer-max-gc=\(number(options.primerMaxGC))",
        ]
        let optional: [(String, String?)] = [
            ("pair-max-tm-difference", options.pairMaxTmDifference.map(number)),
            ("primer-max-end-gc", options.primerMaxEndGC.map(String.init)),
            ("primer-gc-clamp", options.primerGCClamp.map(String.init)),
            ("primer-max-poly-x", options.primerMaxPolyX.map(String.init)),
            ("primer-max-self-any-th", options.primerMaxSelfAnyTh.map(number)),
            ("primer-max-self-end-th", options.primerMaxSelfEndTh.map(number)),
            ("pair-max-compl-any-th", options.pairMaxComplAnyTh.map(number)),
            ("pair-max-compl-end-th", options.pairMaxComplEndTh.map(number)),
        ]
        for (name, value) in optional { if let value { args.append("--\(name)=\(value)") } }
        if options.pickInternalOligo, !options.assayMode.picksInternalOligo { args.append("--pick-internal-oligo") }
        if let probe = options.probe {
            args += [
                "--probe-min-tm=\(number(probe.probeMinTm))", "--probe-opt-tm=\(number(probe.probeOptTm))",
                "--probe-max-tm=\(number(probe.probeMaxTm))",
                "--probe-min-size=\(probe.probeMinSize)", "--probe-opt-size=\(probe.probeOptSize)",
                "--probe-max-size=\(probe.probeMaxSize)",
                "--probe-min-gc=\(number(probe.probeMinGC))", "--probe-opt-gc=\(number(probe.probeOptGC))",
                "--probe-max-gc=\(number(probe.probeMaxGC))", "--probe-max-poly-x=\(probe.probeMaxPolyX)",
                // An empty value omits the tag, which the preset would otherwise add.
                "--probe-must-match-five-prime=\(probe.probeMustMatchFivePrime ?? "")",
            ]
        }
        let fixed = options.fixedOligos
        let fixedFlags: [(String, String?)] = [
            ("left-primer", fixed.leftPrimer), ("right-primer", fixed.rightPrimer), ("probe", fixed.probe),
            ("force-left-end", fixed.forceLeftEnd.map(String.init)),
            ("force-right-end", fixed.forceRightEnd.map(String.init)),
        ]
        for (name, value) in fixedFlags { if let value { args.append("--\(name)=\(value)") } }
        // Zero is how the command says no offset, since a missing flag takes the 5 C default.
        args.append("--probe-min-tm-offset-over-primers=\(options.probeMinTmOffsetOverPrimers.map(number) ?? "0")")
        return args
    }

    // MARK: - PrimalScheme3

    /// The arguments of `primers design primalscheme3` that reproduce `options` through the
    /// command's `makeOptions()`. They cover every control the dialog exposes. Allele-coverage
    /// tuning stays at its defaults. A native executable the user chose is named as
    /// `--primalscheme3-path`.
    public static func primalScheme3(
        inputs: [URL], output: URL, grouping: PrimerAnalysisGrouping,
        options: PrimalScheme3DesignOptions, executableURL: URL? = nil
    ) -> [String] {
        func option(_ name: String, _ value: String) -> [String] { ["--\(name)=\(value)"] }
        var args: [String] = []
        for input in inputs { args += ["--msa", input.path] }
        args += ["--output", output.path]
        args += option("grouping", grouping.rawValue)
        if let executableURL { args += ["--primalscheme3-path", executableURL.path] }
        args += option("amplicon-size", String(options.ampliconSize))
        if let value = options.requestedAmpliconSizeMinimum { args += option("amplicon-size-min", String(value)) }
        if let value = options.requestedAmpliconSizeMaximum { args += option("amplicon-size-max", String(value)) }
        args += option("pool-count", String(options.poolCount))
        if grouping == .independent { args += option("min-overlap", String(options.minOverlap)) }
        args += option("minimum-base-frequency", String(options.minimumBaseFrequency))
        if options.highGC { args.append("--high-gc") }
        args += option("core-count", String(options.coreCount))
        args += option("terminal-gap-policy", options.terminalGapPolicy.rawValue)
        args += option("dimer-score", String(options.dimerScore))
        if !options.useMatchDB { args.append("--disable-matchdb") }
        if options.backtrack { args.append("--backtrack") }
        if options.ignoreN { args.append("--ignore-n") }
        args += option("panel-mode", options.panelMode.rawValue)
        if let value = options.maxAmplicons { args += option("max-amplicons", String(value)) }
        if let value = options.maxAmpliconsPerMSA { args += option("max-amplicons-per-msa", String(value)) }
        args += option("selection-algorithm", options.selectionAlgorithm.rawValue)
        args += option("coverage-metric", options.coverageMetric.rawValue)
        args += option("coverage-target", String(options.coverageTarget))
        args += option("optimizer-seed", String(options.optimizerSeed))
        if let value = options.requestedOptimizerStarts { args += option("optimizer-starts", String(value)) }
        if let value = options.requestedOptimizerRepairRounds { args += option("optimizer-repair-rounds", String(value)) }
        if let value = options.requestedOptimizerTimeLimit { args += option("optimizer-time-limit", String(value)) }
        if let value = options.requestedMisprimingProductSize { args += option("mispriming-product-size", String(value)) }
        let salvage = options.legacySalvageOptions
        if salvage.mode != .off {
            args += option("legacy-salvage", salvage.mode.rawValue)
            if salvage.requestedOptionNames.contains("thresholds") {
                for value in salvage.thresholds { args += option("legacy-salvage-threshold", String(value)) }
            }
            if salvage.requestedOptionNames.contains("floor") { args += option("legacy-salvage-floor", String(salvage.floor)) }
            if salvage.requestedOptionNames.contains("maxEdgesPerPool") { args += option("legacy-salvage-max-edges-per-pool", String(salvage.maxEdgesPerPool)) }
            if salvage.requestedOptionNames.contains("maxIncidentSpeciesPerPool") { args += option("legacy-salvage-max-incident-species-per-pool", String(salvage.maxIncidentSpeciesPerPool)) }
            if salvage.requestedOptionNames.contains("minReferenceGain") { args += option("legacy-salvage-min-reference-gain", String(salvage.minReferenceGain)) }
            if salvage.requestedOptionNames.contains("maxCandidateEvaluations") { args += option("legacy-salvage-max-candidate-evaluations", String(salvage.maxCandidateEvaluations)) }
        }
        if let parent = options.gapCompletionParent { args += option("gap-completion-parent", parent.path) }
        let expansion = options.gapExpansionOptions
        if expansion.mode != .off {
            args += option("gap-expansion", expansion.mode.rawValue)
            if expansion.requestedOptionNames.contains("maxAnchorsPerMSA") { args += option("gap-expansion-max-anchors-per-msa", String(expansion.maxAnchorsPerMSA)) }
            if expansion.requestedOptionNames.contains("maxPairsPerMSA") { args += option("gap-expansion-max-pairs-per-msa", String(expansion.maxPairsPerMSA)) }
        }
        return args
    }

    // MARK: - Number format

    /// A value as the command reads it back: `57` for 57.0 and the shortest exact text otherwise.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
