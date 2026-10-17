import Foundation

/// The Olivar and varVAMP builders of ``PrimerDesignCLIArguments``.
extension PrimerDesignCLIArguments {

    /// The arguments of `primers design olivar` or `primers design varvamp` for `options`, or
    /// nil when `options` holds no block for its engine. Every value the dialog controls is
    /// named, so the command never falls back to an engine config the dialog did not send.
    /// A control that does not apply to the mode stays unnamed, since the command refuses it.
    public static func primerScheme(inputs: [URL], output: URL, options: PrimerSchemeDesignOptions) -> [String]? {
        var args = inputs.map { "--msa=\($0.path)" }
        args += ["--output=\(output.path)", "--grouping=\(options.grouping.rawValue)"]
        switch options.engine {
        case .olivar:
            guard let olivar = options.olivar else { return nil }
            args += sizeArguments(options)
            args.append("--workers=\(options.workers)")
            return args + olivarArguments(olivar)
        case .varvamp:
            guard let varvamp = options.varvamp else { return nil }
            args.append("--mode=\(options.mode.rawValue)")
            args += sizeArguments(options)
            args.append("--workers=\(options.workers)")
            return args + varvampArguments(varvamp, mode: options.mode)
        }
    }

    /// The nominal size, and the bounds when the command's own derivation would not give them.
    /// The command derives 90 and 110 percent of the nominal size, and for varVAMP qPCR with no
    /// nominal size it takes 135 with bounds 70 and 200.
    private static func sizeArguments(_ options: PrimerSchemeDesignOptions) -> [String] {
        let nominal = options.nominalAmpliconLength
        let derivedMinimum = Int((Double(nominal) * 0.9).rounded())
        let derivedMaximum = Int((Double(nominal) * 1.1).rounded())
        let qpcrOwnBounds = options.engine == .varvamp && options.mode == .qpcr && nominal == 135
            && options.minimumAmpliconLength == 70 && options.maximumAmpliconLength == 200
        var args: [String] = []
        if !(qpcrOwnBounds && options.requestedMinimumAmpliconLength == nil
            && options.requestedMaximumAmpliconLength == nil) {
            args.append("--amplicon-size=\(nominal)")
            if options.requestedMinimumAmpliconLength != nil || options.minimumAmpliconLength != derivedMinimum {
                args.append("--amplicon-size-min=\(options.minimumAmpliconLength)")
            }
            if options.requestedMaximumAmpliconLength != nil || options.maximumAmpliconLength != derivedMaximum {
                args.append("--amplicon-size-max=\(options.maximumAmpliconLength)")
            }
        }
        return args
    }

    private static func olivarArguments(_ olivar: OlivarDesignOptions) -> [String] {
        var args = [
            "--minimum-variant-frequency=\(number(olivar.minimumVariantFrequency))",
            "--temperature-c=\(number(olivar.temperatureC))", "--salinity-m=\(number(olivar.salinityM))",
            "--maximum-dimer-delta-g=\(number(olivar.maximumDimerDeltaG))",
            "--minimum-gc=\(number(olivar.minimumGC))", "--maximum-gc=\(number(olivar.maximumGC))",
            "--minimum-complexity=\(number(olivar.minimumComplexity))",
            "--maximum-primer-length=\(olivar.maximumPrimerLength)",
            "--seed=\(olivar.seed)", "--effort=\(olivar.effort)",
        ]
        if olivar.degenerate { args.append("--degenerate") }
        if olivar.checkVariants { args.append("--check-variants") }
        if !olivar.forwardPrefix.isEmpty { args.append("--forward-prefix=\(olivar.forwardPrefix)") }
        if !olivar.reversePrefix.isEmpty { args.append("--reverse-prefix=\(olivar.reversePrefix)") }
        if let path = olivar.blastDatabasePath { args.append("--blast-database=\(path)") }
        for source in olivar.screeningSourcePaths { args.append("--screen-against=\(source)") }
        let risk = olivar.riskWeights
        args += [
            "--risk-extreme-gc=\(number(risk.extremeGC))", "--risk-low-complexity=\(number(risk.lowComplexity))",
            "--risk-non-specificity=\(number(risk.nonSpecificity))", "--risk-variation=\(number(risk.variation))",
            "--risk-sensitivity=\(number(risk.sensitivity))", "--risk-combination=\(number(risk.combination))",
        ]
        return args
    }

    private static func varvampArguments(_ varvamp: VarVAMPDesignOptions, mode: PrimerSchemeMode) -> [String] {
        var args = [
            "--maximum-primer-ambiguities=\(varvamp.maximumPrimerAmbiguities)",
            "--scheme-name=\(varvamp.schemeName)",
        ]
        if let threshold = varvamp.cumulativeConsensusThreshold {
            args.append("--consensus-threshold=\(number(threshold))")
        }
        if mode == .tiled { args.append("--tiled-overlap=\(varvamp.tiledOverlap)") }
        if let count = varvamp.reportCount { args.append("--report-count=\(count)") }
        if mode == .qpcr {
            args += ["--qpcr-test-count=\(varvamp.qpcrTestCount)", "--qpcr-delta-g=\(varvamp.qpcrDeltaG)"]
            if let ambiguities = varvamp.maximumProbeAmbiguities {
                args.append("--maximum-probe-ambiguities=\(ambiguities)")
            }
        }
        if let path = varvamp.compatiblePrimersPath { args.append("--compatible-primers=\(path)") }
        if let path = varvamp.blastDatabasePath { args.append("--blast-database=\(path)") }
        for source in varvamp.screeningSourcePaths { args.append("--screen-against=\(source)") }
        let config = varvamp.configOverrides
        args += scalar("terminal-masking-threshold", config.terminalMaskingThreshold)
        args += doubleTriplet("primer-tm", config.primerTemperature)
        args += doubleTriplet("primer-gc", config.primerGCRange)
        args += intTriplet("primer-size", config.primerSizes)
        args += scalar("primer-maximum-poly-x", config.primerMaximumPolyX)
        args += scalar("primer-maximum-dinucleotide-repeats", config.primerMaximumDinucleotideRepeats)
        args += scalar("primer-hairpin", config.primerHairpin)
        args += intRange("primer-gc-end", config.primerGCEnd)
        args += scalar("primer-minimum-3-prime-without-ambiguity", config.primerMinimum3PrimeWithoutAmbiguity)
        args += scalar("primer-maximum-dimer-temperature", config.primerMaximumDimerTemperature)
        args += scalar("primer-maximum-dimer-delta-g", config.primerMaximumDimerDeltaG)
        args += scalar("end-overlap", config.endOverlap)
        args += doubleTriplet("probe-tm", config.probeTemperature)
        args += intTriplet("probe-size", config.probeSizes)
        args += doubleTriplet("probe-gc", config.probeGCRange)
        args += intRange("probe-gc-end", config.probeGCEnd)
        args += scalar("qprimer-difference", config.qprimerDifference)
        args += doubleRange("probe-temperature-difference", config.probeTemperatureDifference)
        args += intRange("probe-distance", config.probeDistance)
        args += doubleRange("amplicon-gc", config.ampliconGCRange)
        args += scalar("amplicon-deletion-cutoff", config.ampliconDeletionCutoff)
        args += scalar("pcr-monovalent-concentration", config.monovalentCationConcentration)
        args += scalar("pcr-divalent-concentration", config.divalentCationConcentration)
        args += scalar("pcr-dntp-concentration", config.dNTPConcentration)
        args += scalar("pcr-dna-concentration", config.DNAConcentration)
        return args
    }

    private static func scalar(_ name: String, _ value: Double?) -> [String] {
        value.map { ["--\(name)=\(number($0))"] } ?? []
    }

    private static func scalar(_ name: String, _ value: Int?) -> [String] {
        value.map { ["--\(name)=\($0)"] } ?? []
    }

    private static func doubleTriplet(_ name: String, _ value: PrimerSchemeDoubleTriplet?) -> [String] {
        guard let value else { return [] }
        return ["--\(name)-min=\(number(value.minimum))", "--\(name)-opt=\(number(value.optimum))",
                "--\(name)-max=\(number(value.maximum))"]
    }

    private static func intTriplet(_ name: String, _ value: PrimerSchemeIntTriplet?) -> [String] {
        guard let value else { return [] }
        return ["--\(name)-min=\(value.minimum)", "--\(name)-opt=\(value.optimum)", "--\(name)-max=\(value.maximum)"]
    }

    private static func doubleRange(_ name: String, _ value: PrimerSchemeDoubleRange?) -> [String] {
        guard let value else { return [] }
        return ["--\(name)-min=\(number(value.minimum))", "--\(name)-max=\(number(value.maximum))"]
    }

    private static func intRange(_ name: String, _ value: PrimerSchemeIntRange?) -> [String] {
        guard let value else { return [] }
        return ["--\(name)-min=\(value.minimum)", "--\(name)-max=\(value.maximum)"]
    }
}
