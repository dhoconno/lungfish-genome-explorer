import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct VarVAMPDesignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "varvamp",
        abstract: "Design single, tiled, or qPCR schemes with varVAMP through the versioned LGE adapter",
        discussion: "The cumulative consensus threshold is passed directly to native -t and is never complemented. Single/tiled bounds become --opt-length and --max-length; qPCR bounds become QAMPLICON_LENGTH. The nominal size is retained for display and provenance.")

    @Option(name: .customLong("msa")) var msaPaths: [String] = []
    @Option(name: .customLong("output")) var outputPath: String
    @Option(name: .customLong("mode"), help: "single, tiled, or qpcr") var mode = "tiled"
    @Option(name: .customLong("grouping"), help: "varVAMP supports independent only") var grouping = "independent"
    @Option(name: .customLong("python-path")) var pythonPath: String?
    @Option(name: .customLong("amplicon-size"), help: "Nominal display/provenance size.") var ampliconSize = 400
    @Option(name: .customLong("amplicon-size-min"), help: "Inclusive minimum span including primer sites; defaults to 90% of nominal.") var ampliconSizeMin: Int?
    @Option(name: .customLong("amplicon-size-max"), help: "Inclusive maximum span including primer sites; defaults to 110% of nominal. qPCR users should supply native-appropriate bounds explicitly.") var ampliconSizeMax: Int?
    @Option(name: .customLong("workers")) var workers = PrimerSchemeDesignOptions.defaultWorkers

    @Option(name: .customLong("consensus-threshold")) var consensusThreshold: Double?
    @Option(name: .customLong("maximum-primer-ambiguities")) var maximumPrimerAmbiguities = 2
    @Option(name: .customLong("maximum-probe-ambiguities")) var maximumProbeAmbiguities: Int?
    @Option(name: .customLong("tiled-overlap")) var tiledOverlap = 25
    @Option(name: .customLong("report-count")) var reportCount: Int?
    @Option(name: .customLong("qpcr-test-count")) var qpcrTestCount = 50
    @Option(name: .customLong("qpcr-delta-g")) var qpcrDeltaG = -3
    @Option(name: .customLong("scheme-name")) var schemeName = "varVAMP"
    @Option(name: .customLong("compatible-primers")) var compatiblePrimersPath: String?
    @Option(name: .customLong("blast-database")) var blastDatabasePath: String?

    @Option(name: .customLong("terminal-masking-threshold")) var terminalMaskingThreshold: Double?
    @Option(name: .customLong("primer-tm-min")) var primerTmMin: Double?
    @Option(name: .customLong("primer-tm-opt")) var primerTmOpt: Double?
    @Option(name: .customLong("primer-tm-max")) var primerTmMax: Double?
    @Option(name: .customLong("primer-gc-min")) var primerGCMin: Double?
    @Option(name: .customLong("primer-gc-opt")) var primerGCOpt: Double?
    @Option(name: .customLong("primer-gc-max")) var primerGCMax: Double?
    @Option(name: .customLong("primer-size-min")) var primerSizeMin: Int?
    @Option(name: .customLong("primer-size-opt")) var primerSizeOpt: Int?
    @Option(name: .customLong("primer-size-max")) var primerSizeMax: Int?
    @Option(name: .customLong("primer-maximum-poly-x")) var primerMaximumPolyX: Int?
    @Option(name: .customLong("primer-maximum-dinucleotide-repeats")) var primerMaximumDinucleotideRepeats: Int?
    @Option(name: .customLong("primer-hairpin")) var primerHairpin: Double?
    @Option(name: .customLong("primer-gc-end-min")) var primerGCEndMin: Int?
    @Option(name: .customLong("primer-gc-end-max")) var primerGCEndMax: Int?
    @Option(name: .customLong("primer-minimum-3-prime-without-ambiguity")) var primerMinimum3PrimeWithoutAmbiguity: Int?
    @Option(name: .customLong("primer-maximum-dimer-temperature")) var primerMaximumDimerTemperature: Double?
    @Option(name: .customLong("primer-maximum-dimer-delta-g")) var primerMaximumDimerDeltaG: Double?
    @Option(name: .customLong("end-overlap")) var endOverlap: Int?

    @Option(name: .customLong("probe-tm-min")) var probeTmMin: Double?
    @Option(name: .customLong("probe-tm-opt")) var probeTmOpt: Double?
    @Option(name: .customLong("probe-tm-max")) var probeTmMax: Double?
    @Option(name: .customLong("probe-size-min")) var probeSizeMin: Int?
    @Option(name: .customLong("probe-size-opt")) var probeSizeOpt: Int?
    @Option(name: .customLong("probe-size-max")) var probeSizeMax: Int?
    @Option(name: .customLong("probe-gc-min")) var probeGCMin: Double?
    @Option(name: .customLong("probe-gc-opt")) var probeGCOpt: Double?
    @Option(name: .customLong("probe-gc-max")) var probeGCMax: Double?
    @Option(name: .customLong("probe-gc-end-min")) var probeGCEndMin: Int?
    @Option(name: .customLong("probe-gc-end-max")) var probeGCEndMax: Int?
    @Option(name: .customLong("qprimer-difference")) var qprimerDifference: Double?
    @Option(name: .customLong("probe-temperature-difference-min")) var probeTemperatureDifferenceMin: Double?
    @Option(name: .customLong("probe-temperature-difference-max")) var probeTemperatureDifferenceMax: Double?
    @Option(name: .customLong("probe-distance-min")) var probeDistanceMin: Int?
    @Option(name: .customLong("probe-distance-max")) var probeDistanceMax: Int?
    @Option(name: .customLong("amplicon-gc-min")) var ampliconGCMin: Double?
    @Option(name: .customLong("amplicon-gc-max")) var ampliconGCMax: Double?
    @Option(name: .customLong("amplicon-deletion-cutoff")) var ampliconDeletionCutoff: Int?
    @Option(name: .customLong("pcr-monovalent-concentration")) var monovalentCationConcentration: Double?
    @Option(name: .customLong("pcr-divalent-concentration")) var divalentCationConcentration: Double?
    @Option(name: .customLong("pcr-dntp-concentration")) var dNTPConcentration: Double?
    @Option(name: .customLong("pcr-dna-concentration")) var DNAConcentration: Double?

    func makeOptions(supplied: Set<String>? = nil) throws -> PrimerSchemeDesignOptions {
        guard let resolvedMode = PrimerSchemeMode(rawValue: mode) else {
            throw ValidationError("--mode must be single, tiled, or qpcr.")
        }
        guard grouping == "independent" else {
            throw ValidationError("varVAMP supports only --grouping independent.")
        }
        let overrides = VarVAMPConfigOverrides(
            terminalMaskingThreshold: terminalMaskingThreshold,
            primerTemperature: try doubleTriplet(primerTmMin, primerTmOpt, primerTmMax, "primer Tm"),
            primerGCRange: try doubleTriplet(primerGCMin, primerGCOpt, primerGCMax, "primer GC"),
            primerSizes: try intTriplet(primerSizeMin, primerSizeOpt, primerSizeMax, "primer size"),
            primerMaximumPolyX: primerMaximumPolyX,
            primerMaximumDinucleotideRepeats: primerMaximumDinucleotideRepeats,
            primerHairpin: primerHairpin,
            primerGCEnd: try intRange(primerGCEndMin, primerGCEndMax, "primer GC end"),
            primerMinimum3PrimeWithoutAmbiguity: primerMinimum3PrimeWithoutAmbiguity,
            primerMaximumDimerTemperature: primerMaximumDimerTemperature,
            primerMaximumDimerDeltaG: primerMaximumDimerDeltaG, endOverlap: endOverlap,
            probeTemperature: try doubleTriplet(probeTmMin, probeTmOpt, probeTmMax, "probe Tm"),
            probeSizes: try intTriplet(probeSizeMin, probeSizeOpt, probeSizeMax, "probe size"),
            probeGCRange: try doubleTriplet(probeGCMin, probeGCOpt, probeGCMax, "probe GC"),
            probeGCEnd: try intRange(probeGCEndMin, probeGCEndMax, "probe GC end"),
            qprimerDifference: qprimerDifference,
            probeTemperatureDifference: try doubleRange(
                probeTemperatureDifferenceMin, probeTemperatureDifferenceMax,
                "probe temperature difference"),
            probeDistance: try intRange(probeDistanceMin, probeDistanceMax, "probe distance"),
            ampliconGCRange: try doubleRange(ampliconGCMin, ampliconGCMax, "amplicon GC"),
            ampliconDeletionCutoff: ampliconDeletionCutoff,
            monovalentCationConcentration: monovalentCationConcentration,
            divalentCationConcentration: divalentCationConcentration,
            dNTPConcentration: dNTPConcentration, DNAConcentration: DNAConcentration)
        var inferred: Set<String> = [
            consensusThreshold != nil ? "cumulativeConsensusThreshold" : nil,
            maximumPrimerAmbiguities != 2 ? "maximumPrimerAmbiguities" : nil,
            maximumProbeAmbiguities != nil ? "maximumProbeAmbiguities" : nil,
            tiledOverlap != 25 ? "tiledOverlap" : nil,
            reportCount != nil ? "reportCount" : nil,
            qpcrTestCount != 50 ? "qpcrTestCount" : nil,
            qpcrDeltaG != -3 ? "qpcrDeltaG" : nil,
            schemeName != "varVAMP" ? "schemeName" : nil,
            compatiblePrimersPath != nil ? "compatiblePrimersPath" : nil,
            blastDatabasePath != nil ? "blastDatabasePath" : nil,
        ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        if [terminalMaskingThreshold, primerTmMin, primerTmOpt, primerTmMax,
            primerGCMin, primerGCOpt, primerGCMax, primerHairpin,
            primerMaximumDimerTemperature, primerMaximumDimerDeltaG,
            probeTmMin, probeTmOpt, probeTmMax, probeGCMin, probeGCOpt, probeGCMax,
            qprimerDifference, probeTemperatureDifferenceMin, probeTemperatureDifferenceMax,
            ampliconGCMin, ampliconGCMax, monovalentCationConcentration,
            divalentCationConcentration, dNTPConcentration, DNAConcentration]
            .contains(where: { $0 != nil })
            || [primerSizeMin, primerSizeOpt, primerSizeMax, primerMaximumPolyX,
                primerMaximumDinucleotideRepeats, primerGCEndMin, primerGCEndMax,
                primerMinimum3PrimeWithoutAmbiguity, endOverlap, probeSizeMin,
                probeSizeOpt, probeSizeMax, probeGCEndMin, probeGCEndMax,
                probeDistanceMin, probeDistanceMax, ampliconDeletionCutoff]
                .contains(where: { $0 != nil }) {
            inferred.insert("configOverrides")
        }
        if mode != "tiled" { inferred.insert("mode") }
        if grouping != "independent" { inferred.insert("grouping") }
        if ampliconSize != 400 { inferred.insert("nominalAmpliconLength") }
        if ampliconSizeMin != nil {
            inferred.formUnion(["minimumAmpliconLength", "requestedMinimumAmpliconLength"])
        }
        if ampliconSizeMax != nil {
            inferred.formUnion(["maximumAmpliconLength", "requestedMaximumAmpliconLength"])
        }
        if workers != PrimerSchemeDesignOptions.defaultWorkers { inferred.insert("workers") }
        var allSupplied = supplied ?? inferred
        allSupplied.insert("engine")
        let native = VarVAMPDesignOptions(
            cumulativeConsensusThreshold: consensusThreshold,
            maximumPrimerAmbiguities: maximumPrimerAmbiguities,
            maximumProbeAmbiguities: maximumProbeAmbiguities,
            tiledOverlap: tiledOverlap, reportCount: reportCount,
            qpcrTestCount: qpcrTestCount, qpcrDeltaG: qpcrDeltaG,
            schemeName: schemeName, compatiblePrimersPath: compatiblePrimersPath,
            blastDatabasePath: blastDatabasePath, configOverrides: overrides,
            suppliedOptionNames: allSupplied)
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: resolvedMode, grouping: .independent,
            nominalAmpliconLength: ampliconSize,
            minimumAmpliconLength: ampliconSizeMin ?? defaultMinimum(for: ampliconSize),
            maximumAmpliconLength: ampliconSizeMax ?? defaultMaximum(for: ampliconSize),
            requestedMinimumAmpliconLength: ampliconSizeMin,
            requestedMaximumAmpliconLength: ampliconSizeMax,
            workers: workers, suppliedOptionNames: allSupplied, varvamp: native)
        try options.validate()
        return options
    }

    func makeOptions(argv: [String]) throws -> PrimerSchemeDesignOptions {
        try makeOptions(supplied: suppliedNames(argv))
    }

    func run() async throws {
        let output = try await execute(argv: CommandLine.arguments)
        print("varVAMP primer analysis written to \(output.path)")
        for line in Self.advisoryLines(analysisURL: output) { print(line) }
    }

    /// The same coverage explanations the GUI shows on each saved target.
    static func advisoryLines(analysisURL: URL) -> [String] {
        let url = analysisURL.appendingPathComponent(PrimerSchemeResultsDocument.storedRelativePath)
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(PrimerSchemeResultsDocument.self, from: data) else { return [] }
        return document.results.flatMap(\.targets).flatMap { target in
            document.varVAMPCoverageAdvisories(for: target).map { advisory in
                "[\(advisory.severity.rawValue)] \(target.label): \(advisory.message)"
            }
        }
    }

    private func execute(argv: [String]) async throws -> URL {
        let inputs = try primerSchemeInputs(msaPaths)
        let options = try makeOptions(argv: argv)
        var checksums: [URL: String] = [:]
        for input in inputs {
            checksums[input] = try await Primer3DesignPipeline.inspectInput(at: input).checksumSHA256
        }
        let invocation = PrimerAnalysisWrapperInvocation(
            argv: argv, callerVersion: LungfishAppVersion.cliToolVersion,
            explicitOptions: options.provenanceOptions,
            runtimeIdentity: .init(executablePath: argv.first ?? CLICommandIdentity.executableName))
        return try await PrimerSchemeDesignPipeline().run(request: .init(
            inputURLs: inputs, destinationURL: URL(fileURLWithPath: outputPath),
            options: options, invocation: invocation, expectedInputChecksums: checksums,
            executableURL: pythonPath.map(URL.init(fileURLWithPath:))))
    }

    private func suppliedNames(_ argv: [String]) -> Set<String> {
        let mapping: [String: Set<String>] = [
            "--mode": ["mode"], "--grouping": ["grouping"],
            "--amplicon-size": ["nominalAmpliconLength"],
            "--amplicon-size-min": ["minimumAmpliconLength", "requestedMinimumAmpliconLength"],
            "--amplicon-size-max": ["maximumAmpliconLength", "requestedMaximumAmpliconLength"],
            "--workers": ["workers"],
            "--consensus-threshold": ["cumulativeConsensusThreshold"],
            "--maximum-primer-ambiguities": ["maximumPrimerAmbiguities"],
            "--maximum-probe-ambiguities": ["maximumProbeAmbiguities"],
            "--tiled-overlap": ["tiledOverlap"], "--report-count": ["reportCount"],
            "--qpcr-test-count": ["qpcrTestCount"], "--qpcr-delta-g": ["qpcrDeltaG"],
            "--scheme-name": ["schemeName"], "--compatible-primers": ["compatiblePrimersPath"],
            "--blast-database": ["blastDatabasePath"],
        ]
        let configPrefixes = ["--terminal-", "--primer-", "--probe-", "--qprimer-",
                              "--amplicon-gc-", "--amplicon-deletion-", "--pcr-"]
        return primerSchemeSuppliedOptionNames(
            argv, mapping: mapping, prefixes: configPrefixes)
    }

    private func doubleTriplet(_ min: Double?, _ opt: Double?, _ max: Double?, _ name: String)
        throws -> PrimerSchemeDoubleTriplet? {
        guard min != nil || opt != nil || max != nil else { return nil }
        guard let min, let opt, let max else { throw ValidationError("Supply all minimum, optimum, and maximum values for \(name).") }
        return .init(minimum: min, maximum: max, optimum: opt)
    }
    private func intTriplet(_ min: Int?, _ opt: Int?, _ max: Int?, _ name: String)
        throws -> PrimerSchemeIntTriplet? {
        guard min != nil || opt != nil || max != nil else { return nil }
        guard let min, let opt, let max else { throw ValidationError("Supply all minimum, optimum, and maximum values for \(name).") }
        return .init(minimum: min, maximum: max, optimum: opt)
    }
    private func doubleRange(_ min: Double?, _ max: Double?, _ name: String)
        throws -> PrimerSchemeDoubleRange? {
        guard min != nil || max != nil else { return nil }
        guard let min, let max else { throw ValidationError("Supply both minimum and maximum values for \(name).") }
        return .init(minimum: min, maximum: max)
    }
    private func intRange(_ min: Int?, _ max: Int?, _ name: String)
        throws -> PrimerSchemeIntRange? {
        guard min != nil || max != nil else { return nil }
        guard let min, let max else { throw ValidationError("Supply both minimum and maximum values for \(name).") }
        return .init(minimum: min, maximum: max)
    }
}
