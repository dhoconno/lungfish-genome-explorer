import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct PrimerDesignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "design",
        abstract: "Design primers from explicitly selected sequence inputs",
        subcommands: [Primer3Subcommand.self, PrimalScheme3Subcommand.self,
                      OlivarDesignCommand.self, VarVAMPDesignCommand.self]
    )

    static func parseIndexedPath(_ value: String, option: String) throws -> (url: URL, index: Int) {
        guard let separator = value.lastIndex(of: "@"), separator != value.startIndex,
              let index = Int(value[value.index(after: separator)...]), index >= 0 else {
            throw ValidationError("\(option) must be PATH@ZERO_BASED_INDEX.")
        }
        return (URL(fileURLWithPath: String(value[..<separator])), index)
    }

    struct Primer3Subcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "primer3",
            abstract: "Run independent Primer3 designs for explicit FASTA records or native MSA rows"
        )

        @Option(name: .customLong("fasta-record"), help: "FASTA record as PATH@ZERO_BASED_INDEX. Repeatable; duplicate headers are allowed.")
        var fastaRecords: [String] = []
        @Option(name: .customLong("msa-template"), help: "Native .lungfishmsa template row as PATH@ZERO_BASED_INDEX. Repeatable.")
        var msaTemplates: [String] = []
        @Option(name: .customLong("binding-site-policy"), help: "MSA binding policy: template-only or exclude-variable-and-gapped-columns.")
        var bindingSitePolicy: String = "exclude-variable-and-gapped-columns"
        @Option(name: .customLong("output"), help: "New .lungfishprimeranalysis destination.")
        var outputPath: String
        @Option(name: .customLong("primer3-path"), help: "Optional exact primer3_core executable path.")
        var executablePath: String?
        @Option(name: .customLong("assay"), help: "Assay preset, as in the GUI: pcr, qpcr-dye, or qpcr-probe. Omitted values below take the preset's defaults.") var assay = "pcr"
        @Option(name: .customLong("product-size-min"), help: "Preset default: 100 for pcr, 70 for qpcr-dye.") var productSizeMin: Int?
        @Option(name: .customLong("product-size-max"), help: "Preset default: 400 for pcr, 150 for qpcr-dye.") var productSizeMax: Int?
        @Option(name: .customLong("target-start"), help: "Optional 1-based inclusive target start; requires --target-end.") var targetStart: Int?
        @Option(name: .customLong("target-end"), help: "Optional 1-based inclusive target end; requires --target-start.") var targetEnd: Int?
        @Option(name: .customLong("pair-count")) var pairCount = 5
        @Option(name: .customLong("primer-min-size"), help: "Preset default: 18.") var primerMinSize: Int?
        @Option(name: .customLong("primer-opt-size"), help: "Preset default: 20.") var primerOptSize: Int?
        @Option(name: .customLong("primer-max-size"), help: "Preset default: 27 for pcr, 24 for qpcr-dye.") var primerMaxSize: Int?
        @Option(name: .customLong("primer-min-tm"), help: "Preset default: 57 for pcr, 58 for qpcr-dye.") var primerMinTm: Double?
        @Option(name: .customLong("primer-opt-tm"), help: "Preset default: 60.") var primerOptTm: Double?
        @Option(name: .customLong("primer-max-tm"), help: "Preset default: 63 for pcr, 62 for qpcr-dye.") var primerMaxTm: Double?
        @Option(name: .customLong("primer-min-gc"), help: "Preset default: 20 for pcr, 40 for qpcr-dye.") var primerMinGC: Double?
        @Option(name: .customLong("primer-max-gc"), help: "Preset default: 80 for pcr, 60 for qpcr-dye.") var primerMaxGC: Double?
        @Option(name: .customLong("pair-max-tm-difference"), help: "PRIMER_PAIR_MAX_DIFF_TM. Preset default: Primer3's own for pcr, 1 for qpcr-dye.") var pairMaxTmDifference: Double?
        @Option(name: .customLong("primer-max-end-gc"), help: "PRIMER_MAX_END_GC. Preset default: Primer3's own for pcr, 2 for qpcr-dye.") var primerMaxEndGC: Int?
        @Option(name: .customLong("primer-gc-clamp"), help: "PRIMER_GC_CLAMP. Preset default: Primer3's own for pcr, 1 for qpcr-dye.") var primerGCClamp: Int?
        @Option(name: .customLong("primer-max-poly-x"), help: "PRIMER_MAX_POLY_X. Preset default: Primer3's own for pcr, 4 for qpcr-dye.") var primerMaxPolyX: Int?
        @Option(name: .customLong("primer-max-self-any-th"), help: "PRIMER_MAX_SELF_ANY_TH. Preset default: Primer3's own for pcr, 40 for qpcr-dye.") var primerMaxSelfAnyTh: Double?
        @Option(name: .customLong("primer-max-self-end-th"), help: "PRIMER_MAX_SELF_END_TH. Preset default: Primer3's own for pcr, 30 for qpcr-dye.") var primerMaxSelfEndTh: Double?
        @Option(name: .customLong("pair-max-compl-any-th"), help: "PRIMER_PAIR_MAX_COMPL_ANY_TH. Preset default: Primer3's own for pcr, 40 for qpcr-dye.") var pairMaxComplAnyTh: Double?
        @Option(name: .customLong("pair-max-compl-end-th"), help: "PRIMER_PAIR_MAX_COMPL_END_TH. Preset default: Primer3's own for pcr, 30 for qpcr-dye.") var pairMaxComplEndTh: Double?
        @Flag(name: .customLong("pick-internal-oligo"), help: "Ask Primer3 for an ordinary internal oligo. Implied by --assay qpcr-probe.") var pickInternalOligo = false

        func run() async throws {
            let output = try await execute(argv: CommandLine.arguments)
            print("Primer3 analysis written to \(output.path)")
        }

        func executeForTesting(argv: [String]) async throws -> URL { try await execute(argv: argv) }

        private func execute(argv: [String]) async throws -> URL {
            let policy: Primer3BindingSitePolicy
            switch bindingSitePolicy {
            case "template-only": policy = .templateOnly
            case "exclude-variable-and-gapped-columns": policy = .excludeVariableAndGappedColumns
            default: throw ValidationError("--binding-site-policy must be template-only or exclude-variable-and-gapped-columns.")
            }
            var selections: [Primer3TemplateSelection] = []
            for raw in fastaRecords {
                let parsed = try PrimerDesignCommand.parseIndexedPath(raw, option: "--fasta-record")
                guard parsed.url.pathExtension.lowercased() != "lungfishmsa" else { throw ValidationError("Use --msa-template for native .lungfishmsa inputs.") }
                selections.append(.fastaRecord(inputURL: parsed.url, recordIndex: parsed.index))
            }
            for raw in msaTemplates {
                let parsed = try PrimerDesignCommand.parseIndexedPath(raw, option: "--msa-template")
                guard parsed.url.pathExtension.lowercased() == "lungfishmsa" else { throw ValidationError("--msa-template accepts only native .lungfishmsa bundles; import alignments with `\(CLICommandIdentity.executableName) align mafft` first.") }
                selections.append(.msaTemplate(inputURL: parsed.url, rowIndex: parsed.index, bindingSitePolicy: policy))
            }
            guard !selections.isEmpty else { throw ValidationError("Provide at least one explicit --fasta-record or --msa-template selection.") }
            var inputs: [URL] = []
            for selection in selections where !inputs.contains(selection.inputURL) { inputs.append(selection.inputURL) }
            var checksums: [URL: String] = [:]
            for input in inputs { checksums[input] = try await Primer3DesignPipeline.inspectInput(at: input).checksumSHA256 }
            let options = try makeOptions()
            let explicit = Self.explicitOptions(options, selections: selections)
            let invocation = PrimerAnalysisWrapperInvocation(argv: argv, callerVersion: LungfishAppVersion.cliToolVersion, explicitOptions: explicit, runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: argv.first ?? CLICommandIdentity.executableName))
            return try await Primer3DesignPipeline().run(request: .init(inputURLs: inputs, selections: selections, destinationURL: URL(fileURLWithPath: outputPath), options: options, invocation: invocation, executableURL: executablePath.map(URL.init(fileURLWithPath:)), expectedInputChecksums: checksums))
        }

        /// Resolves the parsed flags onto the shared assay preset so the CLI and
        /// the GUI dialog build identical options for the same visible choice.
        func makeOptions() throws -> Primer3DesignOptions {
            guard let mode = Primer3AssayMode(rawValue: assay) else {
                throw ValidationError("--assay must be pcr, qpcr-dye, or qpcr-probe.")
            }
            let defaults = Primer3AssayDefaults.defaults(for: mode)
            return Primer3DesignOptions(
                assayMode: mode,
                productSizeMin: productSizeMin ?? defaults.productSizeMin,
                productSizeMax: productSizeMax ?? defaults.productSizeMax,
                targetStart: targetStart, targetEnd: targetEnd, pairCount: pairCount,
                primerMinSize: primerMinSize ?? defaults.primerMinSize,
                primerOptSize: primerOptSize ?? defaults.primerOptSize,
                primerMaxSize: primerMaxSize ?? defaults.primerMaxSize,
                primerMinTm: primerMinTm ?? defaults.primerMinTm,
                primerOptTm: primerOptTm ?? defaults.primerOptTm,
                primerMaxTm: primerMaxTm ?? defaults.primerMaxTm,
                primerMinGC: primerMinGC ?? defaults.primerMinGC,
                primerMaxGC: primerMaxGC ?? defaults.primerMaxGC,
                pickInternalOligo: pickInternalOligo || mode.picksInternalOligo,
                pairMaxTmDifference: pairMaxTmDifference ?? defaults.pairMaxTmDifference,
                primerMaxEndGC: primerMaxEndGC ?? defaults.primerMaxEndGC,
                primerGCClamp: primerGCClamp ?? defaults.primerGCClamp,
                primerMaxPolyX: primerMaxPolyX ?? defaults.primerMaxPolyX,
                primerMaxSelfAnyTh: primerMaxSelfAnyTh ?? defaults.primerMaxSelfAnyTh,
                primerMaxSelfEndTh: primerMaxSelfEndTh ?? defaults.primerMaxSelfEndTh,
                pairMaxComplAnyTh: pairMaxComplAnyTh ?? defaults.pairMaxComplAnyTh,
                pairMaxComplEndTh: pairMaxComplEndTh ?? defaults.pairMaxComplEndTh)
        }

        private static func explicitOptions(_ options: Primer3DesignOptions, selections: [Primer3TemplateSelection]) -> [String: ParameterValue] {
            var values: [String: ParameterValue] = ["assayMode": .string(options.assayMode.rawValue),
                "pairMaxTmDifference": options.pairMaxTmDifference.map(ParameterValue.number) ?? .null,
                "primerMaxEndGC": options.primerMaxEndGC.map(ParameterValue.integer) ?? .null,
                "primerGCClamp": options.primerGCClamp.map(ParameterValue.integer) ?? .null,
                "primerMaxPolyX": options.primerMaxPolyX.map(ParameterValue.integer) ?? .null,
                "primerMaxSelfAnyTh": options.primerMaxSelfAnyTh.map(ParameterValue.number) ?? .null,
                "primerMaxSelfEndTh": options.primerMaxSelfEndTh.map(ParameterValue.number) ?? .null,
                "pairMaxComplAnyTh": options.pairMaxComplAnyTh.map(ParameterValue.number) ?? .null,
                "pairMaxComplEndTh": options.pairMaxComplEndTh.map(ParameterValue.number) ?? .null]
            values.merge(baseExplicitOptions(options, selections: selections)) { _, new in new }
            return values
        }

        private static func baseExplicitOptions(_ options: Primer3DesignOptions, selections: [Primer3TemplateSelection]) -> [String: ParameterValue] {
            ["productSizeMin": .integer(options.productSizeMin), "productSizeMax": .integer(options.productSizeMax), "targetStart": options.targetStart.map(ParameterValue.integer) ?? .null, "targetEnd": options.targetEnd.map(ParameterValue.integer) ?? .null, "pairCount": .integer(options.pairCount), "primerMinSize": .integer(options.primerMinSize), "primerOptSize": .integer(options.primerOptSize), "primerMaxSize": .integer(options.primerMaxSize), "primerMinTm": .number(options.primerMinTm), "primerOptTm": .number(options.primerOptTm), "primerMaxTm": .number(options.primerMaxTm), "primerMinGC": .number(options.primerMinGC), "primerMaxGC": .number(options.primerMaxGC), "pickInternalOligo": .boolean(options.pickInternalOligo), "selectionCount": .integer(selections.count)]
        }
    }

    struct PrimalScheme3Subcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "primalscheme3", abstract: "Run PrimalScheme on nucleotide sequences or alignments")
        @Option(name: .customLong("msa"), help: "Native .lungfishmsa, .lungfishref, or raw aligned nucleotide FASTA input. Repeatable; a single sequence is valid.") var msaPaths: [String] = []
        @Option(name: .customLong("output")) var outputPath: String
        @Option(name: .customLong("grouping"), help: "independent or combined") var grouping = "independent"
        @Option(name: .customLong("primalscheme3-path")) var executablePath: String?
        @Option(name: .customLong("amplicon-size")) var ampliconSize = 400
        @Option(name: .customLong("amplicon-size-min"), help: "Inclusive minimum reference amplicon span, including primer sites. Defaults to 90% of --amplicon-size, as the GUI does.") var ampliconSizeMinimum: Int?
        @Option(name: .customLong("amplicon-size-max"), help: "Inclusive maximum reference amplicon span, including primer sites. Defaults to 110% of --amplicon-size, as the GUI does.") var ampliconSizeMaximum: Int?
        @Option(name: .customLong("pool-count")) var poolCount = 2
        @Option(name: .customLong("min-overlap"), help: "Minimum overlap for independent legacy designs; combined designs require the default 10.") var minOverlap = 10
        @Option(name: .customLong("minimum-base-frequency")) var minimumBaseFrequency = 0.0
        @Flag(name: .customLong("high-gc")) var highGC = false
        @Option(name: .customLong("core-count"), help: "CPU workers for custom Python or legacy Rust discovery.") var coreCount = PrimalScheme3DesignOptions.defaultCoreCount
        @Option(name: .customLong("terminal-gap-policy"), help: "Custom fork missing-data policy: observed-only or legacy.") var terminalGapPolicy = "observed-only"

        @Option(name: .customLong("dimer-score")) var dimerScore = -26.0
        @Flag(name: .customLong("disable-matchdb"), help: "Disable the native mispriming database.") var disableMatchDB = false
        @Flag(name: .customLong("backtrack"), help: "Independent schemes only.") var backtrack = false
        @Flag(name: .customLong("ignore-n"), help: "Omit unknown N bases; independent schemes only.") var ignoreN = false
        @Option(name: .customLong("panel-mode"), help: "Combined panels: equal or entropy.") var panelMode = "equal"
        @Option(name: .customLong("max-amplicons")) var maxAmplicons: Int?
        @Option(name: .customLong("max-amplicons-per-msa")) var maxAmpliconsPerMSA: Int?
        @Option(name: .customLong("selection-algorithm"), help: "Panel selector: legacy, coverage, or allele-coverage.") var selectionAlgorithm = "legacy"
        @Option(name: .customLong("coverage-metric"), help: "Coverage objective; defaults by selection algorithm.") var coverageMetric: String?
        @Option(name: .customLong("coverage-target"), help: "Coverage objective; defaults to 0.95 for allele coverage and 0.90 otherwise.") var coverageTarget: Double?
        @Option(name: .customLong("optimizer-seed")) var optimizerSeed = 0
        @Option(name: .customLong("optimizer-starts")) var optimizerStarts: Int?
        @Option(name: .customLong("optimizer-repair-rounds")) var optimizerRepairRounds: Int?
        @Option(name: .customLong("optimizer-time-limit")) var optimizerTimeLimit: Double?
        @Option(name: .customLong("mispriming-product-size")) var misprimingProductSize: Int?
        @Option(name: .customLong("preset")) var preset: String?
        @Option(name: .customLong("candidate-profiles")) var candidateProfiles: String?
        @Option(name: .customLong("reuse-discovery")) var reuseDiscovery: String?
        @Option(name: .customLong("variant-selection")) var variantSelection: String?
        @Option(name: .customLong("search-effort"), help: "Allele optimizer effort: standard-v1 or quality-v1.") var searchEffort: String?
        @Option(name: .customLong("phase-scheduling"), help: "Optimizer phase policy: serial or reserved.") var phaseScheduling: String?
        @Option(name: .customLong("intended-product-policy"), help: "Intended product policy: exact-supported or concrete-designated-sites.") var intendedProductPolicy: String?
        @Option(name: .customLong("allele-weighting")) var alleleWeighting: String?
        @Option(name: .customLong("discovery-length-mode")) var discoveryLengthMode: String?
        @Option(name: .customLong("specificity-terminal-k")) var specificityTerminalK: Int?
        @Option(name: .customLong("secondary-product-policy"), help: "Secondary product policy: ordered-disjoint-intended-sites, reject-secondary-products/v1, or ordered-disjoint-concrete-designated-sites/v1.") var secondaryProductPolicy: String?
        @Option(name: .customLong("subset-beam-width")) var subsetBeamWidth: Int?
        @Option(name: .customLong("subset-expansion-limit")) var subsetExpansionLimit: Int?
        @Option(name: .customLong("exchange-width")) var exchangeWidth: Int?
        @Option(name: .customLong("salvage")) var salvage: String?
        @Option(name: .customLong("salvage-threshold")) var salvageThresholds: [Double] = []
        @Option(name: .customLong("salvage-max-stages")) var salvageMaxStages: Int?
        @Option(name: .customLong("salvage-max-edges-per-pool")) var salvageMaxEdgesPerPool: Int?
        @Option(name: .customLong("salvage-max-oligos-per-pool")) var salvageMaxOligosPerPool: Int?
        @Option(name: .customLong("salvage-time-limit")) var salvageTimeLimit: Double?
        @Option(name: .customLong("primary-tier")) var primaryTier: String?
        @Option(name: .customLong("work-frontier-candidates")) var workFrontierCandidates: Int?
        @Option(name: .customLong("work-construction-candidate-attempts")) var workConstructionCandidateAttempts: Int?
        @Option(name: .customLong("work-repair-candidate-probes-per-round")) var workRepairCandidateProbesPerRound: Int?
        @Option(name: .customLong("work-repair-neighborhoods-per-round")) var workRepairNeighborhoodsPerRound: Int?
        @Option(name: .customLong("work-repair-trials-per-round")) var workRepairTrialsPerRound: Int?
        @Option(name: .customLong("work-pool-lookahead-candidates")) var workPoolLookaheadCandidates: Int?
        @Option(name: .customLong("work-cleanup-moves-per-round")) var workCleanupMovesPerRound: Int?
        @Option(name: .customLong("work-families-per-refresh")) var workFamiliesPerRefresh: Int?

        // GUI recovery controls. These mirror the native --legacy-salvage* and
        // --gap-expansion* arguments and are unrelated to the --salvage* allele-coverage flags.
        @Option(name: .customLong("legacy-salvage"), help: "Bounded dimer salvage for combined legacy panels: off or bounded.") var legacySalvage: String?
        @Option(name: .customLong("legacy-salvage-threshold"), help: "Strictly decreasing salvage dimer thresholds below the dimer score. Repeatable.") var legacySalvageThresholds: [Double] = []
        @Option(name: .customLong("legacy-salvage-floor"), help: "Lowest salvage dimer score considered.") var legacySalvageFloor: Double?
        @Option(name: .customLong("legacy-salvage-max-edges-per-pool")) var legacySalvageMaxEdgesPerPool: Int?
        @Option(name: .customLong("legacy-salvage-max-incident-species-per-pool")) var legacySalvageMaxIncidentSpeciesPerPool: Int?
        @Option(name: .customLong("legacy-salvage-min-reference-gain")) var legacySalvageMinReferenceGain: Int?
        @Option(name: .customLong("legacy-salvage-max-candidate-evaluations")) var legacySalvageMaxCandidateEvaluations: Int?
        @Option(name: .customLong("gap-completion-parent"), help: "Saved combined PrimalScheme analysis whose uncovered regions this follow-up design should fill.") var gapCompletionParent: String?
        @Option(name: .customLong("gap-expansion"), help: "Generate candidates for uncovered regions of the gap-completion parent: off or bounded.") var gapExpansion: String?
        @Option(name: .customLong("gap-expansion-max-anchors-per-msa")) var gapExpansionMaxAnchorsPerMSA: Int?
        @Option(name: .customLong("gap-expansion-max-pairs-per-msa")) var gapExpansionMaxPairsPerMSA: Int?

        func run() async throws {
            let output = try await execute(argv: CommandLine.arguments)
            print("PrimalScheme analysis written to \(output.path)")
        }
        func validatedInputURLs(paths: [String]) throws -> [URL] {
            guard !paths.isEmpty else { throw ValidationError("Provide at least one --msa input.") }
            return try paths.map { path in
                let url = URL(fileURLWithPath: path)
                guard PrimalScheme3DesignPipeline.supportsInput(at: url) else {
                    throw ValidationError("--msa accepts native .lungfishmsa, .lungfishref, or raw aligned nucleotide FASTA (.fa, .fasta, .fna, .ffn, .frn, .fas) inputs.")
                }
                return url
            }
        }
        private func execute(argv: [String]) async throws -> URL {
            let inputs = try validatedInputURLs(paths: msaPaths)
            let resolved = try makeOptions()
            let options = resolved.options
            let resolvedGrouping = resolved.grouping
            var checksums: [URL: String] = [:]
            for input in inputs { checksums[input] = try await Primer3DesignPipeline.inspectInput(at: input).checksumSHA256 }
            let explicit = options.provenanceOptions.merging(["grouping": .string(resolvedGrouping.rawValue), "inputCount": .integer(inputs.count)]) { _, new in new }
            let invocation = PrimerAnalysisWrapperInvocation(argv: argv, callerVersion: LungfishAppVersion.cliToolVersion, explicitOptions: explicit, runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: argv.first ?? CLICommandIdentity.executableName))
            return try await PrimalScheme3DesignPipeline().run(request: .init(inputURLs: inputs, destinationURL: URL(fileURLWithPath: outputPath), options: options, grouping: resolvedGrouping, invocation: invocation, executableURL: executablePath.map(URL.init(fileURLWithPath:)), expectedInputChecksums: checksums))
        }

        /// Resolves the parsed flags into the same typed options the GUI dialog
        /// builds, so identical visible settings produce identical requests.
        func makeOptions() throws -> (options: PrimalScheme3DesignOptions, grouping: PrimerAnalysisGrouping) {
            let resolvedGrouping: PrimerAnalysisGrouping
            switch grouping { case "independent": resolvedGrouping = .independent; case "combined": resolvedGrouping = .combined; default: throw ValidationError("--grouping must be independent or combined.") }
            if resolvedGrouping == .combined, minOverlap != 10 { throw ValidationError("--min-overlap applies only to independent designs; combined mode requires 10.") }
            guard let resolvedTerminalGapPolicy = PrimalScheme3TerminalGapPolicy(rawValue: terminalGapPolicy) else {
                throw ValidationError("--terminal-gap-policy must be observed-only or legacy.")
            }
            guard let resolvedPanelMode = PrimalScheme3PanelMode(rawValue: panelMode) else {
                throw ValidationError("--panel-mode must be equal or entropy.")
            }
            guard let resolvedSelectionAlgorithm = PrimalScheme3SelectionAlgorithm(rawValue: selectionAlgorithm) else {
                throw ValidationError("--selection-algorithm must be legacy, coverage, or allele-coverage.")
            }
            let metricName = coverageMetric ?? (resolvedSelectionAlgorithm == .alleleCoverage
                ? PrimalScheme3CoverageMetric.observedAllelePrimerTrimmed.rawValue
                : PrimalScheme3CoverageMetric.fullSpan.rawValue)
            guard let resolvedCoverageMetric = PrimalScheme3CoverageMetric(rawValue: metricName) else {
                throw ValidationError("--coverage-metric must be full-span, primer-trimmed, or observed-allele-primer-trimmed.")
            }
            let resolvedPhaseScheduling: PrimalScheme3PhaseScheduling?
            if let phaseScheduling {
                guard let value = PrimalScheme3PhaseScheduling(rawValue: phaseScheduling) else {
                    throw ValidationError("--phase-scheduling must be serial or reserved.")
                }
                resolvedPhaseScheduling = value
            } else {
                resolvedPhaseScheduling = nil
            }
            let resolvedSearchEffort: PrimalScheme3SearchEffort?
            if let searchEffort {
                guard let value = PrimalScheme3SearchEffort(rawValue: searchEffort) else {
                    throw ValidationError("--search-effort must be standard-v1 or quality-v1.")
                }
                resolvedSearchEffort = value
            } else {
                resolvedSearchEffort = nil
            }
            let resolvedIntendedProductPolicy: PrimalScheme3IntendedProductPolicy?
            if let intendedProductPolicy {
                guard let value = PrimalScheme3IntendedProductPolicy(rawValue: intendedProductPolicy) else {
                    throw ValidationError("--intended-product-policy must be exact-supported or concrete-designated-sites.")
                }
                resolvedIntendedProductPolicy = value
            } else {
                resolvedIntendedProductPolicy = nil
            }
            let resolvedSecondaryProductPolicy: PrimalScheme3SecondaryProductPolicy?
            if let secondaryProductPolicy {
                guard let value = PrimalScheme3SecondaryProductPolicy(rawValue: secondaryProductPolicy) else {
                    throw ValidationError("--secondary-product-policy must be ordered-disjoint-intended-sites, reject-secondary-products/v1, or ordered-disjoint-concrete-designated-sites/v1.")
                }
                resolvedSecondaryProductPolicy = value
            } else {
                resolvedSecondaryProductPolicy = nil
            }
            let alleleOptions = PrimalScheme3AlleleOptions(
                preset: preset, candidateProfiles: candidateProfiles,
                reuseDiscovery: reuseDiscovery.map(URL.init(fileURLWithPath:)),
                variantSelection: variantSelection, searchEffort: resolvedSearchEffort,
                phaseScheduling: resolvedPhaseScheduling,
                intendedProductPolicy: resolvedIntendedProductPolicy,
                alleleWeighting: alleleWeighting,
                discoveryLengthMode: discoveryLengthMode, specificityTerminalK: specificityTerminalK,
                secondaryProductPolicy: resolvedSecondaryProductPolicy, subsetBeamWidth: subsetBeamWidth,
                subsetExpansionLimit: subsetExpansionLimit, exchangeWidth: exchangeWidth,
                salvage: salvage, salvageThresholds: salvageThresholds.isEmpty ? nil : salvageThresholds,
                salvageMaxStages: salvageMaxStages, salvageMaxEdgesPerPool: salvageMaxEdgesPerPool,
                salvageMaxOligosPerPool: salvageMaxOligosPerPool, salvageTimeLimit: salvageTimeLimit,
                primaryTier: primaryTier, workFrontierCandidates: workFrontierCandidates,
                workConstructionCandidateAttempts: workConstructionCandidateAttempts,
                workRepairCandidateProbesPerRound: workRepairCandidateProbesPerRound,
                workRepairNeighborhoodsPerRound: workRepairNeighborhoodsPerRound,
                workRepairTrialsPerRound: workRepairTrialsPerRound,
                workPoolLookaheadCandidates: workPoolLookaheadCandidates,
                workCleanupMovesPerRound: workCleanupMovesPerRound,
                workFamiliesPerRefresh: workFamiliesPerRefresh)
            let resolvedLegacySalvageMode: PrimalScheme3LegacySalvageMode
            if let legacySalvage {
                guard let value = PrimalScheme3LegacySalvageMode(rawValue: legacySalvage) else {
                    throw ValidationError("--legacy-salvage must be off or bounded.")
                }
                resolvedLegacySalvageMode = value
            } else {
                resolvedLegacySalvageMode = .off
            }
            let legacySalvageOptions = PrimalScheme3LegacySalvageOptions(
                mode: resolvedLegacySalvageMode,
                thresholds: legacySalvageThresholds.isEmpty ? nil : legacySalvageThresholds,
                floor: legacySalvageFloor, maxEdgesPerPool: legacySalvageMaxEdgesPerPool,
                maxIncidentSpeciesPerPool: legacySalvageMaxIncidentSpeciesPerPool,
                minReferenceGain: legacySalvageMinReferenceGain,
                maxCandidateEvaluations: legacySalvageMaxCandidateEvaluations)
            let resolvedGapExpansionMode: PrimalScheme3GapExpansionMode
            if let gapExpansion {
                guard let value = PrimalScheme3GapExpansionMode(rawValue: gapExpansion) else {
                    throw ValidationError("--gap-expansion must be off or bounded.")
                }
                resolvedGapExpansionMode = value
            } else {
                resolvedGapExpansionMode = .off
            }
            let gapExpansionOptions = PrimalScheme3GapExpansionOptions(
                mode: resolvedGapExpansionMode, maxAnchorsPerMSA: gapExpansionMaxAnchorsPerMSA,
                maxPairsPerMSA: gapExpansionMaxPairsPerMSA)
            // The GUI always sends both bounds. An omitted CLI bound takes the same
            // default so the fork sees one sizing metric regardless of the caller.
            let defaultBounds = PrimalScheme3DesignOptions.defaultAmpliconSizeBounds(target: ampliconSize)
            let options = PrimalScheme3DesignOptions(ampliconSize: ampliconSize, poolCount: poolCount, minOverlap: minOverlap, minimumBaseFrequency: minimumBaseFrequency, highGC: highGC, coreCount: coreCount, terminalGapPolicy: resolvedTerminalGapPolicy, dimerScore: dimerScore, useMatchDB: !disableMatchDB, backtrack: backtrack, ignoreN: ignoreN, panelMode: resolvedPanelMode, maxAmplicons: maxAmplicons, maxAmpliconsPerMSA: maxAmpliconsPerMSA, ampliconSizeMinimum: ampliconSizeMinimum ?? defaultBounds?.minimum, ampliconSizeMaximum: ampliconSizeMaximum ?? defaultBounds?.maximum, selectionAlgorithm: resolvedSelectionAlgorithm, coverageMetric: resolvedCoverageMetric, coverageTarget: coverageTarget, optimizerSeed: optimizerSeed, optimizerStarts: optimizerStarts, optimizerRepairRounds: optimizerRepairRounds, optimizerTimeLimit: optimizerTimeLimit, misprimingProductSize: misprimingProductSize, alleleOptions: alleleOptions, legacySalvageOptions: legacySalvageOptions, gapCompletionParent: gapCompletionParent.map { URL(fileURLWithPath: $0).standardizedFileURL }, gapExpansionOptions: gapExpansionOptions)
            return (options, resolvedGrouping)
        }

        /// The argv that reproduces `options` through `makeOptions()`. It covers every
        /// control the GUI dialog exposes; allele-coverage tuning stays at its defaults.
        static func arguments(inputs: [URL], output: URL, grouping: PrimerAnalysisGrouping,
                              options: PrimalScheme3DesignOptions) -> [String] {
            func option(_ name: String, _ value: String) -> [String] { ["--\(name)=\(value)"] }
            var args: [String] = []
            for input in inputs { args += option("msa", input.path) }
            args += option("output", output.path)
            args += option("grouping", grouping.rawValue)
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
    }
}
