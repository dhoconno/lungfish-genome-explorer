import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct PrimerDesignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "design",
        abstract: "Design primers from explicitly selected sequence inputs",
        subcommands: [Primer3Subcommand.self, PrimalScheme3Subcommand.self]
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
        @Option(name: .customLong("product-size-min")) var productSizeMin = 100
        @Option(name: .customLong("product-size-max")) var productSizeMax = 400
        @Option(name: .customLong("target-start"), help: "Optional 1-based inclusive target start; requires --target-end.") var targetStart: Int?
        @Option(name: .customLong("target-end"), help: "Optional 1-based inclusive target end; requires --target-start.") var targetEnd: Int?
        @Option(name: .customLong("pair-count")) var pairCount = 5
        @Option(name: .customLong("primer-min-size")) var primerMinSize = 18
        @Option(name: .customLong("primer-opt-size")) var primerOptSize = 20
        @Option(name: .customLong("primer-max-size")) var primerMaxSize = 27
        @Option(name: .customLong("primer-min-tm")) var primerMinTm = 57.0
        @Option(name: .customLong("primer-opt-tm")) var primerOptTm = 60.0
        @Option(name: .customLong("primer-max-tm")) var primerMaxTm = 63.0
        @Option(name: .customLong("primer-min-gc")) var primerMinGC = 20.0
        @Option(name: .customLong("primer-max-gc")) var primerMaxGC = 80.0
        @Flag(name: .customLong("pick-internal-oligo"), help: "Ask Primer3 for an ordinary internal oligo.") var pickInternalOligo = false

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
            let options = Primer3DesignOptions(productSizeMin: productSizeMin, productSizeMax: productSizeMax, targetStart: targetStart, targetEnd: targetEnd, pairCount: pairCount, primerMinSize: primerMinSize, primerOptSize: primerOptSize, primerMaxSize: primerMaxSize, primerMinTm: primerMinTm, primerOptTm: primerOptTm, primerMaxTm: primerMaxTm, primerMinGC: primerMinGC, primerMaxGC: primerMaxGC, pickInternalOligo: pickInternalOligo)
            let explicit = Self.explicitOptions(options, selections: selections)
            let invocation = PrimerAnalysisWrapperInvocation(argv: argv, callerVersion: LungfishAppVersion.cliToolVersion, explicitOptions: explicit, runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: argv.first ?? CLICommandIdentity.executableName))
            return try await Primer3DesignPipeline().run(request: .init(inputURLs: inputs, selections: selections, destinationURL: URL(fileURLWithPath: outputPath), options: options, invocation: invocation, executableURL: executablePath.map(URL.init(fileURLWithPath:)), expectedInputChecksums: checksums))
        }

        private static func explicitOptions(_ options: Primer3DesignOptions, selections: [Primer3TemplateSelection]) -> [String: ParameterValue] {
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
        @Option(name: .customLong("amplicon-size-min"), help: "Inclusive minimum reference amplicon span, including primer sites. Supplying either bound enables reference-span sizing.") var ampliconSizeMinimum: Int?
        @Option(name: .customLong("amplicon-size-max"), help: "Inclusive maximum reference amplicon span, including primer sites.") var ampliconSizeMaximum: Int?
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
        @Option(name: .customLong("optimizer-starts")) var optimizerStarts = 4
        @Option(name: .customLong("optimizer-repair-rounds")) var optimizerRepairRounds = 2
        @Option(name: .customLong("optimizer-time-limit")) var optimizerTimeLimit = 120.0
        @Option(name: .customLong("mispriming-product-size")) var misprimingProductSize: Int?
        @Option(name: .customLong("preset")) var preset: String?
        @Option(name: .customLong("candidate-profiles")) var candidateProfiles: String?
        @Option(name: .customLong("reuse-discovery")) var reuseDiscovery: String?
        @Option(name: .customLong("variant-selection")) var variantSelection: String?
        @Option(name: .customLong("allele-weighting")) var alleleWeighting: String?
        @Option(name: .customLong("discovery-length-mode")) var discoveryLengthMode: String?
        @Option(name: .customLong("specificity-terminal-k")) var specificityTerminalK: Int?
        @Option(name: .customLong("secondary-product-policy")) var secondaryProductPolicy: String?
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
            let resolvedGrouping: PrimerAnalysisGrouping
            switch grouping { case "independent": resolvedGrouping = .independent; case "combined": resolvedGrouping = .combined; default: throw ValidationError("--grouping must be independent or combined.") }
            if resolvedGrouping == .combined, minOverlap != 10 { throw ValidationError("--min-overlap applies only to independent designs; combined mode requires 10.") }
            var checksums: [URL: String] = [:]
            for input in inputs { checksums[input] = try await Primer3DesignPipeline.inspectInput(at: input).checksumSHA256 }
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
            let alleleOptions = PrimalScheme3AlleleOptions(
                preset: preset, candidateProfiles: candidateProfiles,
                reuseDiscovery: reuseDiscovery.map(URL.init(fileURLWithPath:)),
                variantSelection: variantSelection, alleleWeighting: alleleWeighting,
                discoveryLengthMode: discoveryLengthMode, specificityTerminalK: specificityTerminalK,
                secondaryProductPolicy: secondaryProductPolicy, subsetBeamWidth: subsetBeamWidth,
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
            let options = PrimalScheme3DesignOptions(ampliconSize: ampliconSize, poolCount: poolCount, minOverlap: minOverlap, minimumBaseFrequency: minimumBaseFrequency, highGC: highGC, coreCount: coreCount, terminalGapPolicy: resolvedTerminalGapPolicy, dimerScore: dimerScore, useMatchDB: !disableMatchDB, backtrack: backtrack, ignoreN: ignoreN, panelMode: resolvedPanelMode, maxAmplicons: maxAmplicons, maxAmpliconsPerMSA: maxAmpliconsPerMSA, ampliconSizeMinimum: ampliconSizeMinimum, ampliconSizeMaximum: ampliconSizeMaximum, selectionAlgorithm: resolvedSelectionAlgorithm, coverageMetric: resolvedCoverageMetric, coverageTarget: coverageTarget, optimizerSeed: optimizerSeed, optimizerStarts: optimizerStarts, optimizerRepairRounds: optimizerRepairRounds, optimizerTimeLimit: optimizerTimeLimit, misprimingProductSize: misprimingProductSize, alleleOptions: alleleOptions)
            let explicit = options.provenanceOptions.merging(["grouping": .string(resolvedGrouping.rawValue), "inputCount": .integer(inputs.count)]) { _, new in new }
            let invocation = PrimerAnalysisWrapperInvocation(argv: argv, callerVersion: LungfishAppVersion.cliToolVersion, explicitOptions: explicit, runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: argv.first ?? CLICommandIdentity.executableName))
            return try await PrimalScheme3DesignPipeline().run(request: .init(inputURLs: inputs, destinationURL: URL(fileURLWithPath: outputPath), options: options, grouping: resolvedGrouping, invocation: invocation, executableURL: executablePath.map(URL.init(fileURLWithPath:)), expectedInputChecksums: checksums))
        }
    }
}
