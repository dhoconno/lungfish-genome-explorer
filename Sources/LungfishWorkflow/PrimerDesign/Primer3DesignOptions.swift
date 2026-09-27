import Foundation

/// The assay a Primer3 design is for. The GUI "Assay" picker and the CLI
/// `--assay` flag select the same shared preset so both interfaces send
/// Primer3 identical input for the same choice.
public enum Primer3AssayMode: String, Codable, CaseIterable, Sendable {
    case pcr
    case qpcrDye = "qpcr-dye"
    case qpcrProbe = "qpcr-probe"

    /// Hydrolysis-probe assays ask Primer3 for an internal oligo with each pair.
    public var picksInternalOligo: Bool { self == .qpcrProbe }
}

/// The internal-oligo rules for a hydrolysis (TaqMan-style) probe. Every member
/// maps onto a PRIMER_INTERNAL_* setting. The whole group is optional, so PCR and
/// intercalating-dye designs emit no PRIMER_INTERNAL_* line at all.
///
/// A hydrolysis probe must melt above the primers so it is already bound when
/// polymerase reaches it and can be cleaved; 5 to 10 C above the primer Tm is the
/// standard figure (Applied Biosystems Primer Express design guidelines; Bustin
/// et al. 2009, MIQE, Clin Chem, doi:10.1373/clinchem.2008.112797; Thornton and
/// Basu 2011, Biochem Mol Biol Educ, doi:10.1002/bmb.20461). The values match
/// LGE's varVAMP probe defaults so both engines design the same kind of probe.
public struct Primer3ProbeDefaults: Codable, Equatable, Sendable {
    /// PRIMER_INTERNAL_MIN_TM / OPT_TM / MAX_TM.
    public let probeMinTm: Double
    public let probeOptTm: Double
    public let probeMaxTm: Double
    /// PRIMER_INTERNAL_MIN_SIZE / OPT_SIZE / MAX_SIZE.
    public let probeMinSize: Int
    public let probeOptSize: Int
    public let probeMaxSize: Int
    /// PRIMER_INTERNAL_MIN_GC / OPT_GC_PERCENT / MAX_GC.
    public let probeMinGC: Double
    public let probeOptGC: Double
    public let probeMaxGC: Double
    /// PRIMER_INTERNAL_MAX_POLY_X.
    public let probeMaxPolyX: Int
    /// PRIMER_INTERNAL_MUST_MATCH_FIVE_PRIME. `h` is A, C or T, so this forbids a
    /// 5' G, which quenches a reporter dye on the adjacent base. Verified accepted
    /// by the bundled libprimer3 2.6.1.
    public let probeMustMatchFivePrime: String?

    public init(
        probeMinTm: Double, probeOptTm: Double, probeMaxTm: Double,
        probeMinSize: Int, probeOptSize: Int, probeMaxSize: Int,
        probeMinGC: Double, probeOptGC: Double, probeMaxGC: Double,
        probeMaxPolyX: Int, probeMustMatchFivePrime: String?
    ) {
        self.probeMinTm = probeMinTm
        self.probeOptTm = probeOptTm
        self.probeMaxTm = probeMaxTm
        self.probeMinSize = probeMinSize
        self.probeOptSize = probeOptSize
        self.probeMaxSize = probeMaxSize
        self.probeMinGC = probeMinGC
        self.probeOptGC = probeOptGC
        self.probeMaxGC = probeMaxGC
        self.probeMaxPolyX = probeMaxPolyX
        self.probeMustMatchFivePrime = probeMustMatchFivePrime
    }

    /// Probe Tm 64/67/70 C sits 5 to 10 C above the 58/60/62 C primer window.
    /// Sizes 20/25/30 nt and GC 40/60/80 percent mirror LGE's varVAMP probe
    /// defaults.
    ///
    /// Runs are capped at 3 identical bases rather than the primers' 4. A
    /// probe is GC-rich by design, so a 4-base cap readily admits GGGG; a G
    /// run stacks into a guanine quadruplex that both quenches the reporter
    /// dye and resists denaturation, so the probe reports poorly even when its
    /// Tm and GC look right.
    public static let hydrolysisProbe = Primer3ProbeDefaults(
        probeMinTm: 64, probeOptTm: 67, probeMaxTm: 70,
        probeMinSize: 20, probeOptSize: 25, probeMaxSize: 30,
        probeMinGC: 40, probeOptGC: 60, probeMaxGC: 80,
        probeMaxPolyX: 3, probeMustMatchFivePrime: "hnnnn")
}

/// The per-assay starting values. Optional members map onto Primer3 settings
/// LGE leaves at Primer3's own defaults for ordinary PCR; `nil` omits the
/// line from the Boulder input so PCR designs are byte-for-byte unchanged.
public struct Primer3AssayDefaults: Equatable, Sendable {
    public let productSizeMin: Int
    public let productSizeMax: Int
    public let primerMinSize: Int
    public let primerOptSize: Int
    public let primerMaxSize: Int
    public let primerMinTm: Double
    public let primerOptTm: Double
    public let primerMaxTm: Double
    public let primerMinGC: Double
    public let primerMaxGC: Double
    public let pairMaxTmDifference: Double?
    public let primerMaxEndGC: Int?
    public let primerGCClamp: Int?
    public let primerMaxPolyX: Int?
    public let primerMaxSelfAnyTh: Double?
    public let primerMaxSelfEndTh: Double?
    public let pairMaxComplAnyTh: Double?
    public let pairMaxComplEndTh: Double?
    /// The PRIMER_INTERNAL_* rules, for assays that pick an internal oligo.
    /// `nil` emits no PRIMER_INTERNAL_* line.
    public let probe: Primer3ProbeDefaults?

    public init(
        productSizeMin: Int, productSizeMax: Int,
        primerMinSize: Int, primerOptSize: Int, primerMaxSize: Int,
        primerMinTm: Double, primerOptTm: Double, primerMaxTm: Double,
        primerMinGC: Double, primerMaxGC: Double,
        pairMaxTmDifference: Double?, primerMaxEndGC: Int?,
        primerGCClamp: Int?, primerMaxPolyX: Int?,
        primerMaxSelfAnyTh: Double?, primerMaxSelfEndTh: Double?,
        pairMaxComplAnyTh: Double?, pairMaxComplEndTh: Double?,
        probe: Primer3ProbeDefaults? = nil,
        fixedOligos: Primer3FixedOligos = .none,
        probeMinTmOffsetOverPrimers: Double? = Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers
    ) {
        self.productSizeMin = productSizeMin
        self.productSizeMax = productSizeMax
        self.primerMinSize = primerMinSize
        self.primerOptSize = primerOptSize
        self.primerMaxSize = primerMaxSize
        self.primerMinTm = primerMinTm
        self.primerOptTm = primerOptTm
        self.primerMaxTm = primerMaxTm
        self.primerMinGC = primerMinGC
        self.primerMaxGC = primerMaxGC
        self.pairMaxTmDifference = pairMaxTmDifference
        self.primerMaxEndGC = primerMaxEndGC
        self.primerGCClamp = primerGCClamp
        self.primerMaxPolyX = primerMaxPolyX
        self.primerMaxSelfAnyTh = primerMaxSelfAnyTh
        self.primerMaxSelfEndTh = primerMaxSelfEndTh
        self.pairMaxComplAnyTh = pairMaxComplAnyTh
        self.pairMaxComplEndTh = pairMaxComplEndTh
        self.probe = probe
    }

    /// LGE's historical PCR defaults. Every optional rule stays at Primer3's
    /// own default (PRIMER_PAIR_MAX_DIFF_TM 100, PRIMER_MAX_END_GC 5,
    /// PRIMER_GC_CLAMP 0, PRIMER_MAX_POLY_X 5, *_ANY_TH 45, *_END_TH 35).
    public static let pcr = Primer3AssayDefaults(
        productSizeMin: 100, productSizeMax: 400,
        primerMinSize: 18, primerOptSize: 20, primerMaxSize: 27,
        primerMinTm: 57, primerOptTm: 60, primerMaxTm: 63,
        primerMinGC: 20, primerMaxGC: 80,
        pairMaxTmDifference: nil, primerMaxEndGC: nil, primerGCClamp: nil, primerMaxPolyX: nil,
        primerMaxSelfAnyTh: nil, primerMaxSelfEndTh: nil, pairMaxComplAnyTh: nil, pairMaxComplEndTh: nil)

    /// Intercalating-dye (SYBR Green style) qPCR rules. Sources: Bustin et al.
    /// 2009, MIQE guidelines, Clin Chem, doi:10.1373/clinchem.2008.112797;
    /// Thornton and Basu 2011, Biochem Mol Biol Educ, doi:10.1002/bmb.20461.
    /// - 70 to 150 bp products amplify efficiently and melt as one peak.
    /// - Tm 58/60/62 C with at most 1 C between the two primers keeps both
    ///   primers annealing at the single 60 C two-step cycling temperature.
    /// - 40 to 60 percent GC, 18 to 24 nt (optimum 20).
    /// - At most 2 G or C in the last five 3' bases and a GC clamp of 1 so the
    ///   3' end anchors without mispriming from a GC-rich end.
    /// - Runs of at most 4 identical bases.
    /// - Stricter complementarity than Primer3's defaults because a dye
    ///   reports every double-stranded product, including primer-dimers. The
    ///   thresholds are duplex melting temperatures in C. The 3'-end duplexes
    ///   (SELF_END, PAIR_COMPL_END) are the ones polymerase can extend, so they
    ///   drop from Primer3's 35 to 30. The any-position duplexes drop from 45
    ///   to 40 so a stable internal duplex cannot seed a dimer at 60 C either.
    public static let qpcrDye = Primer3AssayDefaults(
        productSizeMin: 70, productSizeMax: 150,
        primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
        primerMinTm: 58, primerOptTm: 60, primerMaxTm: 62,
        primerMinGC: 40, primerMaxGC: 60,
        pairMaxTmDifference: 1, primerMaxEndGC: 2, primerGCClamp: 1, primerMaxPolyX: 4,
        primerMaxSelfAnyTh: 40, primerMaxSelfEndTh: 30, pairMaxComplAnyTh: 40, pairMaxComplEndTh: 30)

    /// Hydrolysis-probe (TaqMan-style) qPCR rules. The primer rules are the
    /// intercalating-dye ones, because both run the same 60 C two-step cycling and
    /// want the same short, efficient product; a probe assay does not need the dye
    /// preset's dimer strictness for specificity, but keeping it costs nothing and
    /// dimers still waste reagent. What a probe assay adds is the internal oligo:
    /// see `Primer3ProbeDefaults` for the probe window and its sources. Without
    /// these, Primer3 picks a probe at its own 60 C internal default, level with
    /// the primers, and the probe is not reliably bound before extension reaches it.
    public static let qpcrProbe = Primer3AssayDefaults(
        productSizeMin: 70, productSizeMax: 150,
        primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
        primerMinTm: 58, primerOptTm: 60, primerMaxTm: 62,
        primerMinGC: 40, primerMaxGC: 60,
        pairMaxTmDifference: 1, primerMaxEndGC: 2, primerGCClamp: 1, primerMaxPolyX: 4,
        primerMaxSelfAnyTh: 40, primerMaxSelfEndTh: 30, pairMaxComplAnyTh: 40, pairMaxComplEndTh: 30,
        probe: .hydrolysisProbe)

    public static func defaults(for mode: Primer3AssayMode) -> Primer3AssayDefaults {
        switch mode {
        case .pcr: .pcr
        case .qpcrDye: .qpcrDye
        case .qpcrProbe: .qpcrProbe
        }
    }
}

public struct Primer3DesignOptions: Codable, Equatable, Sendable {
    public let assayMode: Primer3AssayMode
    public let productSizeMin: Int
    public let productSizeMax: Int
    public let targetStart: Int?
    public let targetEnd: Int?
    public let pairCount: Int
    public let primerMinSize: Int
    public let primerOptSize: Int
    public let primerMaxSize: Int
    public let primerMinTm: Double
    public let primerOptTm: Double
    public let primerMaxTm: Double
    public let primerMinGC: Double
    public let primerMaxGC: Double
    public let pickInternalOligo: Bool
    /// PRIMER_PAIR_MAX_DIFF_TM. `nil` leaves Primer3's default.
    public let pairMaxTmDifference: Double?
    /// PRIMER_MAX_END_GC. `nil` leaves Primer3's default.
    public let primerMaxEndGC: Int?
    /// PRIMER_GC_CLAMP. `nil` leaves Primer3's default.
    public let primerGCClamp: Int?
    /// PRIMER_MAX_POLY_X. `nil` leaves Primer3's default.
    public let primerMaxPolyX: Int?
    /// PRIMER_MAX_SELF_ANY_TH. `nil` leaves Primer3's default.
    public let primerMaxSelfAnyTh: Double?
    /// PRIMER_MAX_SELF_END_TH. `nil` leaves Primer3's default.
    public let primerMaxSelfEndTh: Double?
    /// PRIMER_PAIR_MAX_COMPL_ANY_TH. `nil` leaves Primer3's default.
    public let pairMaxComplAnyTh: Double?
    /// PRIMER_PAIR_MAX_COMPL_END_TH. `nil` leaves Primer3's default.
    public let pairMaxComplEndTh: Double?
    /// The PRIMER_INTERNAL_* probe rules. `nil` emits no PRIMER_INTERNAL_* line, so
    /// PCR and intercalating-dye Boulder input is unchanged.
    public let probe: Primer3ProbeDefaults?
    /// Oligos the caller fixed, so Primer3 designs their partners.
    public let fixedOligos: Primer3FixedOligos
    /// How far above the highest primer Tm the probe must melt, in C. LGE
    /// raises PRIMER_INTERNAL_MIN_TM to `primerMaxTm + offset` when the preset
    /// would otherwise allow a smaller gap. `nil` disables the adjustment and
    /// leaves the probe window exactly as configured.
    public let probeMinTmOffsetOverPrimers: Double?

    public init(
        assayMode: Primer3AssayMode = .pcr,
        productSizeMin: Int,
        productSizeMax: Int,
        targetStart: Int?,
        targetEnd: Int?,
        pairCount: Int,
        primerMinSize: Int,
        primerOptSize: Int,
        primerMaxSize: Int,
        primerMinTm: Double,
        primerOptTm: Double,
        primerMaxTm: Double,
        primerMinGC: Double,
        primerMaxGC: Double,
        pickInternalOligo: Bool,
        pairMaxTmDifference: Double? = nil,
        primerMaxEndGC: Int? = nil,
        primerGCClamp: Int? = nil,
        primerMaxPolyX: Int? = nil,
        primerMaxSelfAnyTh: Double? = nil,
        primerMaxSelfEndTh: Double? = nil,
        pairMaxComplAnyTh: Double? = nil,
        pairMaxComplEndTh: Double? = nil,
        probe: Primer3ProbeDefaults? = nil,
        fixedOligos: Primer3FixedOligos = .none,
        probeMinTmOffsetOverPrimers: Double? = Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers
    ) {
        self.assayMode = assayMode
        self.productSizeMin = productSizeMin
        self.productSizeMax = productSizeMax
        self.targetStart = targetStart
        self.targetEnd = targetEnd
        self.pairCount = pairCount
        self.primerMinSize = primerMinSize
        self.primerOptSize = primerOptSize
        self.primerMaxSize = primerMaxSize
        self.primerMinTm = primerMinTm
        self.primerOptTm = primerOptTm
        self.primerMaxTm = primerMaxTm
        self.primerMinGC = primerMinGC
        self.primerMaxGC = primerMaxGC
        self.pickInternalOligo = pickInternalOligo
        self.pairMaxTmDifference = pairMaxTmDifference
        self.primerMaxEndGC = primerMaxEndGC
        self.primerGCClamp = primerGCClamp
        self.primerMaxPolyX = primerMaxPolyX
        self.primerMaxSelfAnyTh = primerMaxSelfAnyTh
        self.primerMaxSelfEndTh = primerMaxSelfEndTh
        self.pairMaxComplAnyTh = pairMaxComplAnyTh
        self.pairMaxComplEndTh = pairMaxComplEndTh
        self.probe = probe
        self.fixedOligos = fixedOligos
        self.probeMinTmOffsetOverPrimers = probeMinTmOffsetOverPrimers
    }

    /// varVAMP's QPROBE_TEMP_DIFF lower bound, and the standard figure for a
    /// hydrolysis probe: the probe must already be bound when polymerase
    /// reaches it, so it melts 5 to 10 C above the primers.
    public static let defaultProbeMinTmOffsetOverPrimers: Double = 5

    /// The options a fresh dialog or a bare CLI invocation produces for `mode`.
    public static func preset(_ mode: Primer3AssayMode, targetStart: Int? = nil, targetEnd: Int? = nil,
                              pairCount: Int = 5, fixedOligos: Primer3FixedOligos = .none,
                              probeMinTmOffsetOverPrimers: Double? = Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers)
    -> Primer3DesignOptions {
        let defaults = Primer3AssayDefaults.defaults(for: mode)
        return Primer3DesignOptions(
            assayMode: mode, productSizeMin: defaults.productSizeMin, productSizeMax: defaults.productSizeMax,
            targetStart: targetStart, targetEnd: targetEnd, pairCount: pairCount,
            primerMinSize: defaults.primerMinSize, primerOptSize: defaults.primerOptSize, primerMaxSize: defaults.primerMaxSize,
            primerMinTm: defaults.primerMinTm, primerOptTm: defaults.primerOptTm, primerMaxTm: defaults.primerMaxTm,
            primerMinGC: defaults.primerMinGC, primerMaxGC: defaults.primerMaxGC,
            pickInternalOligo: mode.picksInternalOligo,
            pairMaxTmDifference: defaults.pairMaxTmDifference, primerMaxEndGC: defaults.primerMaxEndGC,
            primerGCClamp: defaults.primerGCClamp, primerMaxPolyX: defaults.primerMaxPolyX,
            primerMaxSelfAnyTh: defaults.primerMaxSelfAnyTh, primerMaxSelfEndTh: defaults.primerMaxSelfEndTh,
            pairMaxComplAnyTh: defaults.pairMaxComplAnyTh, pairMaxComplEndTh: defaults.pairMaxComplEndTh,
            probe: defaults.probe, fixedOligos: fixedOligos,
            probeMinTmOffsetOverPrimers: probeMinTmOffsetOverPrimers)
    }

    private enum CodingKeys: String, CodingKey {
        case assayMode, productSizeMin, productSizeMax, targetStart, targetEnd, pairCount
        case primerMinSize, primerOptSize, primerMaxSize, primerMinTm, primerOptTm, primerMaxTm
        case primerMinGC, primerMaxGC, pickInternalOligo
        case pairMaxTmDifference, primerMaxEndGC, primerGCClamp, primerMaxPolyX
        case primerMaxSelfAnyTh, primerMaxSelfEndTh, pairMaxComplAnyTh, pairMaxComplEndTh
        case probe, fixedOligos, probeMinTmOffsetOverPrimers
    }

    /// Records written before the assay mode existed decode as ordinary PCR.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            assayMode: try c.decodeIfPresent(Primer3AssayMode.self, forKey: .assayMode) ?? .pcr,
            productSizeMin: try c.decode(Int.self, forKey: .productSizeMin),
            productSizeMax: try c.decode(Int.self, forKey: .productSizeMax),
            targetStart: try c.decodeIfPresent(Int.self, forKey: .targetStart),
            targetEnd: try c.decodeIfPresent(Int.self, forKey: .targetEnd),
            pairCount: try c.decode(Int.self, forKey: .pairCount),
            primerMinSize: try c.decode(Int.self, forKey: .primerMinSize),
            primerOptSize: try c.decode(Int.self, forKey: .primerOptSize),
            primerMaxSize: try c.decode(Int.self, forKey: .primerMaxSize),
            primerMinTm: try c.decode(Double.self, forKey: .primerMinTm),
            primerOptTm: try c.decode(Double.self, forKey: .primerOptTm),
            primerMaxTm: try c.decode(Double.self, forKey: .primerMaxTm),
            primerMinGC: try c.decode(Double.self, forKey: .primerMinGC),
            primerMaxGC: try c.decode(Double.self, forKey: .primerMaxGC),
            pickInternalOligo: try c.decode(Bool.self, forKey: .pickInternalOligo),
            pairMaxTmDifference: try c.decodeIfPresent(Double.self, forKey: .pairMaxTmDifference),
            primerMaxEndGC: try c.decodeIfPresent(Int.self, forKey: .primerMaxEndGC),
            primerGCClamp: try c.decodeIfPresent(Int.self, forKey: .primerGCClamp),
            primerMaxPolyX: try c.decodeIfPresent(Int.self, forKey: .primerMaxPolyX),
            primerMaxSelfAnyTh: try c.decodeIfPresent(Double.self, forKey: .primerMaxSelfAnyTh),
            primerMaxSelfEndTh: try c.decodeIfPresent(Double.self, forKey: .primerMaxSelfEndTh),
            pairMaxComplAnyTh: try c.decodeIfPresent(Double.self, forKey: .pairMaxComplAnyTh),
            pairMaxComplEndTh: try c.decodeIfPresent(Double.self, forKey: .pairMaxComplEndTh),
            probe: try c.decodeIfPresent(Primer3ProbeDefaults.self, forKey: .probe),
            fixedOligos: try c.decodeIfPresent(Primer3FixedOligos.self, forKey: .fixedOligos) ?? .none,
            // Records written before the offset existed decode with it absent,
            // which preserves their original probe window exactly.
            probeMinTmOffsetOverPrimers: try c.decodeIfPresent(Double.self, forKey: .probeMinTmOffsetOverPrimers))
    }

    /// The probe window actually sent to Primer3.
    ///
    /// The qpcr-probe preset allows primers up to 62 C and probes from 64 C, a
    /// 2 C gap. That is too small: a hydrolysis probe must already be bound
    /// when polymerase reaches it, so it needs to melt 5 to 10 C above the
    /// primers (varVAMP's QPROBE_TEMP_DIFF uses 5 C as its lower bound). When
    /// `probeMinTmOffsetOverPrimers` is set, the probe minimum is raised to
    /// `primerMaxTm + offset` if the configured minimum sits below it, and the
    /// optimum and maximum are carried up with it so the window stays ordered
    /// and non-empty. Lowering a probe minimum is never done here, so a caller
    /// who deliberately asked for a hotter probe keeps it.
    public var effectiveProbe: Primer3ProbeDefaults? {
        guard let probe else { return nil }
        guard let offset = probeMinTmOffsetOverPrimers else { return probe }
        let required = primerMaxTm + offset
        guard probe.probeMinTm < required else { return probe }
        return Primer3ProbeDefaults(
            probeMinTm: required,
            probeOptTm: max(probe.probeOptTm, required),
            probeMaxTm: max(probe.probeMaxTm, max(probe.probeOptTm, required)),
            probeMinSize: probe.probeMinSize, probeOptSize: probe.probeOptSize, probeMaxSize: probe.probeMaxSize,
            probeMinGC: probe.probeMinGC, probeOptGC: probe.probeOptGC, probeMaxGC: probe.probeMaxGC,
            probeMaxPolyX: probe.probeMaxPolyX,
            probeMustMatchFivePrime: probe.probeMustMatchFivePrime)
    }

    /// The optional Primer3 settings this design pins, as Boulder `KEY=value`
    /// lines, in a fixed order. Empty for ordinary PCR.
    public var additionalBoulderSettings: [(key: String, value: String)] {
        var lines: [(key: String, value: String)] = []
        if let value = pairMaxTmDifference { lines.append(("PRIMER_PAIR_MAX_DIFF_TM", String(value))) }
        if let value = primerMaxEndGC { lines.append(("PRIMER_MAX_END_GC", String(value))) }
        if let value = primerGCClamp { lines.append(("PRIMER_GC_CLAMP", String(value))) }
        if let value = primerMaxPolyX { lines.append(("PRIMER_MAX_POLY_X", String(value))) }
        if let value = primerMaxSelfAnyTh { lines.append(("PRIMER_MAX_SELF_ANY_TH", String(value))) }
        if let value = primerMaxSelfEndTh { lines.append(("PRIMER_MAX_SELF_END_TH", String(value))) }
        if let value = pairMaxComplAnyTh { lines.append(("PRIMER_PAIR_MAX_COMPL_ANY_TH", String(value))) }
        if let value = pairMaxComplEndTh { lines.append(("PRIMER_PAIR_MAX_COMPL_END_TH", String(value))) }
        if let probe = effectiveProbe {
            lines += [
                ("PRIMER_INTERNAL_MIN_TM", String(probe.probeMinTm)),
                ("PRIMER_INTERNAL_OPT_TM", String(probe.probeOptTm)),
                ("PRIMER_INTERNAL_MAX_TM", String(probe.probeMaxTm)),
                ("PRIMER_INTERNAL_MIN_SIZE", String(probe.probeMinSize)),
                ("PRIMER_INTERNAL_OPT_SIZE", String(probe.probeOptSize)),
                ("PRIMER_INTERNAL_MAX_SIZE", String(probe.probeMaxSize)),
                ("PRIMER_INTERNAL_MIN_GC", String(probe.probeMinGC)),
                ("PRIMER_INTERNAL_OPT_GC_PERCENT", String(probe.probeOptGC)),
                ("PRIMER_INTERNAL_MAX_GC", String(probe.probeMaxGC)),
                ("PRIMER_INTERNAL_MAX_POLY_X", String(probe.probeMaxPolyX)),
            ]
            if let mustMatch = probe.probeMustMatchFivePrime {
                lines.append(("PRIMER_INTERNAL_MUST_MATCH_FIVE_PRIME", mustMatch))
            }
        }
        return lines
    }
}

/// Oligos the caller fixes, so Primer3 designs the rest of the assay around
/// them instead of searching the whole template.
///
/// This is what lets a designer act on a discriminating column: pin an oligo
/// that covers it, or force a primer's 3' end onto it, and let Primer3 pick the
/// partners. Each sequence maps onto a SEQUENCE_* tag, all verified accepted by
/// the bundled libprimer3 2.6.1:
///   - `leftPrimer`    -> SEQUENCE_PRIMER
///   - `rightPrimer`   -> SEQUENCE_PRIMER_REVCOMP
///   - `probe`         -> SEQUENCE_INTERNAL_OLIGO
///   - `forceLeftEnd`  -> SEQUENCE_FORCE_LEFT_END
///   - `forceRightEnd` -> SEQUENCE_FORCE_RIGHT_END
public struct Primer3FixedOligos: Codable, Equatable, Sendable {
    /// The forward primer, 5'->3', as it would be ordered.
    public let leftPrimer: String?
    /// The reverse primer, 5'->3' as it would be ordered. Primer3 expects this
    /// orientation for SEQUENCE_PRIMER_REVCOMP, so it is not reverse
    /// complemented before being written; its reverse complement is what must
    /// occur in the template.
    public let rightPrimer: String?
    /// The hydrolysis probe, 5'->3'.
    public let probe: String?
    /// 1-based template position a left primer's 3' end must land on.
    public let forceLeftEnd: Int?
    /// 1-based template position a right primer's 3' end must land on.
    public let forceRightEnd: Int?

    public var isEmpty: Bool {
        leftPrimer == nil && rightPrimer == nil && probe == nil
            && forceLeftEnd == nil && forceRightEnd == nil
    }

    public init(
        leftPrimer: String? = nil,
        rightPrimer: String? = nil,
        probe: String? = nil,
        forceLeftEnd: Int? = nil,
        forceRightEnd: Int? = nil
    ) {
        self.leftPrimer = Self.normalized(leftPrimer)
        self.rightPrimer = Self.normalized(rightPrimer)
        self.probe = Self.normalized(probe)
        self.forceLeftEnd = forceLeftEnd
        self.forceRightEnd = forceRightEnd
    }

    /// Uppercases and trims, and treats an empty field as absent so a blank GUI
    /// field or `--left-primer ""` does not emit a tag Primer3 would reject.
    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static let none = Primer3FixedOligos()
}

public enum Primer3BindingSitePolicy: String, Codable, Equatable, Sendable {
    case templateOnly
    case excludeVariableAndGappedColumns
}

public enum Primer3TemplateSelection: Sendable {
    case fastaRecord(inputURL: URL, recordIndex: Int)
    case msaTemplate(inputURL: URL, rowIndex: Int, bindingSitePolicy: Primer3BindingSitePolicy)

    public var inputURL: URL {
        switch self {
        case .fastaRecord(let inputURL, _), .msaTemplate(let inputURL, _, _): inputURL
        }
    }
}

public struct Primer3DesignRequest: Sendable {
    public let inputURLs: [URL]
    public let selections: [Primer3TemplateSelection]
    public let destinationURL: URL
    public let options: Primer3DesignOptions
    public let invocation: PrimerAnalysisWrapperInvocation
    public let executableURL: URL?
    public let expectedInputChecksums: [URL: String]

    public init(
        inputURLs: [URL],
        selections: [Primer3TemplateSelection],
        destinationURL: URL,
        options: Primer3DesignOptions,
        invocation: PrimerAnalysisWrapperInvocation,
        executableURL: URL? = nil,
        expectedInputChecksums: [URL: String] = [:]
    ) {
        self.inputURLs = inputURLs
        self.selections = selections
        self.destinationURL = destinationURL
        self.options = options
        self.executableURL = executableURL
        self.invocation = invocation
        self.expectedInputChecksums = expectedInputChecksums
    }
}
