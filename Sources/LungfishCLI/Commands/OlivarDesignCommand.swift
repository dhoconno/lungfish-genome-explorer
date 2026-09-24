import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct OlivarDesignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "olivar",
        abstract: "Design tiled schemes with OliVar through the versioned LGE adapter",
        discussion: "Amplicon bounds are inclusive reference spans including primer sites. The nominal size is retained for display and provenance; OliVar uses the minimum and maximum bounds.")

    @Option(name: .customLong("msa"), help: "Equal-length native MSA, one-sequence reference, or aligned nucleotide FASTA. Repeatable.")
    var msaPaths: [String] = []
    @Option(name: .customLong("output"), help: "New .lungfishprimeranalysis destination.")
    var outputPath: String
    @Option(name: .customLong("grouping"), help: "independent or combined")
    var grouping = "independent"
    @Option(name: .customLong("python-path"), help: "Optional exact Python executable; the adapter still verifies pinned OliVar source and conda identity.")
    var pythonPath: String?
    @Option(name: .customLong("amplicon-size"), help: "Nominal display/provenance size.")
    var ampliconSize = 400
    @Option(name: .customLong("amplicon-size-min"), help: "Inclusive minimum span including primer sites.")
    var ampliconSizeMin: Int?
    @Option(name: .customLong("amplicon-size-max"), help: "Inclusive maximum span including primer sites.")
    var ampliconSizeMax: Int?
    @Option(name: .customLong("workers")) var workers = PrimerSchemeDesignOptions.defaultWorkers

    @Option(name: .customLong("minimum-variant-frequency")) var minimumVariantFrequency = 0.01
    @Flag(name: .customLong("degenerate")) var degenerate = false
    @Option(name: .customLong("temperature-c")) var temperatureC = 60.0
    @Option(name: .customLong("salinity-m")) var salinityM = 0.18
    @Option(name: .customLong("maximum-dimer-delta-g")) var maximumDimerDeltaG = -11.8
    @Option(name: .customLong("minimum-gc")) var minimumGC = 0.2
    @Option(name: .customLong("maximum-gc")) var maximumGC = 0.75
    @Option(name: .customLong("minimum-complexity")) var minimumComplexity = 0.4
    @Option(name: .customLong("maximum-primer-length")) var maximumPrimerLength = 36
    @Flag(name: .customLong("check-variants")) var checkVariants = false
    @Option(name: .customLong("seed")) var seed = 10
    @Option(name: .customLong("effort")) var effort = 1
    @Option(name: .customLong("forward-prefix")) var forwardPrefix = ""
    @Option(name: .customLong("reverse-prefix")) var reversePrefix = ""
    @Option(name: .customLong("blast-database"), help: "BLAST nucleotide database prefix; all concrete component files are snapshotted.")
    var blastDatabasePath: String?
    @Option(name: .customLong("risk-extreme-gc")) var riskExtremeGC = 1.0
    @Option(name: .customLong("risk-low-complexity")) var riskLowComplexity = 1.0
    @Option(name: .customLong("risk-non-specificity")) var riskNonSpecificity = 1.0
    @Option(name: .customLong("risk-variation")) var riskVariation = 1.0
    @Option(name: .customLong("risk-sensitivity")) var riskSensitivity = 1.0
    @Option(name: .customLong("risk-combination")) var riskCombination = 1.0

    func makeOptions(supplied: Set<String>? = nil) throws -> PrimerSchemeDesignOptions {
        let resolvedGrouping: PrimerAnalysisGrouping
        switch grouping {
        case "independent": resolvedGrouping = .independent
        case "combined": resolvedGrouping = .combined
        default: throw ValidationError("--grouping must be independent or combined.")
        }
        var inferred: Set<String> = [
            minimumVariantFrequency != 0.01 ? "minimumVariantFrequency" : nil,
            degenerate ? "degenerate" : nil,
            temperatureC != 60 ? "temperatureC" : nil,
            salinityM != 0.18 ? "salinityM" : nil,
            maximumDimerDeltaG != -11.8 ? "maximumDimerDeltaG" : nil,
            minimumGC != 0.2 ? "minimumGC" : nil,
            maximumGC != 0.75 ? "maximumGC" : nil,
            minimumComplexity != 0.4 ? "minimumComplexity" : nil,
            maximumPrimerLength != 36 ? "maximumPrimerLength" : nil,
            checkVariants ? "checkVariants" : nil, seed != 10 ? "seed" : nil,
            effort != 1 ? "effort" : nil, !forwardPrefix.isEmpty ? "forwardPrefix" : nil,
            !reversePrefix.isEmpty ? "reversePrefix" : nil,
            blastDatabasePath != nil ? "blastDatabasePath" : nil,
            [riskExtremeGC, riskLowComplexity, riskNonSpecificity, riskVariation,
             riskSensitivity, riskCombination].contains(where: { $0 != 1 }) ? "riskWeights" : nil,
        ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
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
        let olivar = OlivarDesignOptions(
            minimumVariantFrequency: minimumVariantFrequency, degenerate: degenerate,
            align: false, temperatureC: temperatureC, salinityM: salinityM,
            maximumDimerDeltaG: maximumDimerDeltaG, minimumGC: minimumGC,
            maximumGC: maximumGC, minimumComplexity: minimumComplexity,
            maximumPrimerLength: maximumPrimerLength, checkVariants: checkVariants,
            seed: seed, effort: effort, forwardPrefix: forwardPrefix,
            reversePrefix: reversePrefix, blastDatabasePath: blastDatabasePath,
            riskWeights: .init(
                extremeGC: riskExtremeGC, lowComplexity: riskLowComplexity,
                nonSpecificity: riskNonSpecificity, variation: riskVariation,
                sensitivity: riskSensitivity, combination: riskCombination),
            suppliedOptionNames: allSupplied)
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: resolvedGrouping,
            nominalAmpliconLength: ampliconSize,
            minimumAmpliconLength: ampliconSizeMin ?? defaultMinimum(for: ampliconSize),
            maximumAmpliconLength: ampliconSizeMax ?? defaultMaximum(for: ampliconSize),
            requestedMinimumAmpliconLength: ampliconSizeMin,
            requestedMaximumAmpliconLength: ampliconSizeMax,
            workers: workers, suppliedOptionNames: allSupplied, olivar: olivar)
        try options.validate()
        return options
    }

    func makeOptions(argv: [String]) throws -> PrimerSchemeDesignOptions {
        try makeOptions(supplied: suppliedNames(argv))
    }

    func run() async throws {
        let output = try await execute(argv: CommandLine.arguments)
        print("OliVar primer analysis written to \(output.path)")
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
            "--grouping": ["grouping"], "--amplicon-size": ["nominalAmpliconLength"],
            "--amplicon-size-min": ["minimumAmpliconLength", "requestedMinimumAmpliconLength"],
            "--amplicon-size-max": ["maximumAmpliconLength", "requestedMaximumAmpliconLength"],
            "--workers": ["workers"],
            "--minimum-variant-frequency": ["minimumVariantFrequency"], "--degenerate": ["degenerate"],
            "--temperature-c": ["temperatureC"], "--salinity-m": ["salinityM"],
            "--maximum-dimer-delta-g": ["maximumDimerDeltaG"], "--minimum-gc": ["minimumGC"],
            "--maximum-gc": ["maximumGC"], "--minimum-complexity": ["minimumComplexity"],
            "--maximum-primer-length": ["maximumPrimerLength"], "--check-variants": ["checkVariants"],
            "--seed": ["seed"], "--effort": ["effort"], "--forward-prefix": ["forwardPrefix"],
            "--reverse-prefix": ["reversePrefix"], "--blast-database": ["blastDatabasePath"],
            "--risk-extreme-gc": ["riskWeights"], "--risk-low-complexity": ["riskWeights"],
            "--risk-non-specificity": ["riskWeights"], "--risk-variation": ["riskWeights"],
            "--risk-sensitivity": ["riskWeights"], "--risk-combination": ["riskWeights"],
        ]
        return primerSchemeSuppliedOptionNames(argv, mapping: mapping)
    }
}

func primerSchemeSuppliedOptionNames(
    _ argv: [String], mapping: [String: Set<String>], prefixes: [String] = []
) -> Set<String> {
    let flags = argv.compactMap { argument -> String? in
        guard argument.hasPrefix("--") else { return nil }
        return String(argument.split(separator: "=", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0])
    }
    var supplied = flags.reduce(into: Set<String>()) { result, flag in
        result.formUnion(mapping[flag] ?? [])
    }
    if flags.contains(where: { flag in prefixes.contains(where: flag.hasPrefix) }) {
        supplied.insert("configOverrides")
    }
    return supplied
}

func defaultMinimum(for nominal: Int) -> Int {
    Int((Double(nominal) * 0.9).rounded())
}

func defaultMaximum(for nominal: Int) -> Int {
    Int((Double(nominal) * 1.1).rounded())
}

func primerSchemeInputs(_ paths: [String]) throws -> [URL] {
    guard !paths.isEmpty else { throw ValidationError("Provide at least one --msa input.") }
    return try paths.map {
        let url = URL(fileURLWithPath: $0)
        guard PrimalScheme3DesignPipeline.supportsInput(at: url) else {
            throw ValidationError("--msa accepts native .lungfishmsa, .lungfishref, or uncompressed aligned nucleotide FASTA.")
        }
        return url
    }
}
