import Foundation
import LungfishCore

/// Genotype ploidy passed to `bcftools call --ploidy`.
///
/// bcftools is the one caller in the Call Variants dialog that emits
/// genotypes rather than allele fractions, so it is the only caller whose
/// result depends on this. Viral and bacterial genomes are haploid; a human
/// or macaque autosome is diploid, and calling it haploid silently drops most
/// heterozygous sites and writes every genotype as `1`.
public enum VariantCallingPloidy: Int, Sendable, Codable, CaseIterable, Equatable {
    case haploid = 1
    case diploid = 2

    public var displayName: String {
        switch self {
        case .haploid:
            return "Haploid"
        case .diploid:
            return "Diploid"
        }
    }

    /// The literal handed to `bcftools call --ploidy`.
    public var commandLineValue: String {
        String(rawValue)
    }

    /// The user-facing message shown when `--ploidy` turns up in Extra
    /// arguments for a bcftools run. Ploidy has its own control, and letting
    /// two sources set it made the dialog's value silently lose (the audit
    /// regression that motivated the control), so the conflict is rejected
    /// rather than resolved by argument order.
    public static let reservedExtraArgumentMessage =
        "Extra arguments must not include --ploidy for bcftools. Use the Ploidy setting instead (--ploidy on the command line)."

    /// Whether `arguments` contains a bcftools ploidy flag in any of the
    /// spellings bcftools accepts (`--ploidy 2`, `--ploidy=2`, `--ploidy-file`).
    public static func extraArgumentsSetPloidy(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument == "--ploidy" || argument.hasPrefix("--ploidy=") || argument.hasPrefix("--ploidy-file")
        }
    }
}

/// The ploidy LGE picks for a bundle when the user has not chosen one, and
/// the evidence it used, so the dialog and provenance can both say why.
public struct VariantCallingPloidyInference: Sendable, Equatable {
    public enum Basis: String, Sendable, Codable, Equatable {
        /// A "Ploidy" / "Default Ploidy" note in the bundle's metadata groups,
        /// the same note the variant browser's Auto ploidy mode honours.
        case metadataPloidyNote
        /// The bundle carries a "Virus" metadata group written by an NCBI
        /// Virus download.
        case virusMetadata
        /// A GenBank LOCUS division code (VRL, PHG, BCT, PRI, MAM, ...) in the
        /// bundle's "Record" metadata.
        case genbankDivision
        /// The source organism name (or an "Organism" metadata item) matched
        /// a known viral, bacterial, or eukaryotic name.
        case organismName
        /// The assembly or bundle name carries a well-known eukaryotic
        /// assembly token such as GRCh38, hg38, CHM13, GRCm39 or Mmul_10.
        case assemblyName
        /// No organism signal; the reference is at least 10 Mb, which no
        /// viral genome and almost no bacterial genome reaches.
        case genomeLength
        /// No usable signal at all; the viral default applies.
        case unknown
    }

    public let ploidy: VariantCallingPloidy
    public let basis: Basis
    /// A short human-readable statement of the evidence, e.g.
    /// `organism "Homo sapiens"`, for the dialog caption.
    public let evidence: String

    public init(ploidy: VariantCallingPloidy, basis: Basis, evidence: String) {
        self.ploidy = ploidy
        self.basis = basis
        self.evidence = evidence
    }

    /// The dialog caption under the Ploidy control.
    public var summary: String {
        switch basis {
        case .unknown:
            return "Default for this bundle: \(ploidy.displayName). No organism could be determined, so the viral default applies. Choose Diploid for a human or other eukaryotic reference."
        default:
            return "Default for this bundle: \(ploidy.displayName), from \(evidence)."
        }
    }
}

/// Pure rules for deriving a bcftools ploidy from a bundle manifest.
///
/// The rules run in order of how direct the evidence is: an explicit ploidy
/// note, then the record's own taxonomy (Virus group, GenBank division), then
/// name matching on the organism and assembly, then the 10 Mb length rule
/// the variant browser already uses. Anything unresolved keeps the viral
/// default of haploid, which is the case the SCI-04 audit fixed.
public enum VariantCallingPloidyDefaults {

    /// The genome length at or above which a reference with no organism
    /// signal is assumed eukaryotic. Mirrors `isLikelyHaploidOrganism` in the
    /// variant browser.
    public static let eukaryoticGenomeLengthThreshold: Int64 = 10_000_000

    public static func defaultPloidy(for manifest: BundleManifest) -> VariantCallingPloidy {
        infer(for: manifest).ploidy
    }

    public static func infer(for manifest: BundleManifest) -> VariantCallingPloidyInference {
        let groups = manifest.metadata ?? []

        if let note = ploidyNote(in: groups) {
            return note
        }

        if groups.contains(where: { $0.name.caseInsensitiveCompare("Virus") == .orderedSame }) {
            return VariantCallingPloidyInference(
                ploidy: .haploid,
                basis: .virusMetadata,
                evidence: "the bundle's NCBI Virus record"
            )
        }

        if let division = genbankDivision(in: groups) {
            return division
        }

        var organismCandidates = [manifest.source.organism]
        if let commonName = manifest.source.commonName {
            organismCandidates.append(commonName)
        }
        for group in groups {
            for item in group.items where item.label.caseInsensitiveCompare("Organism") == .orderedSame
                || item.label.caseInsensitiveCompare("Species") == .orderedSame {
                organismCandidates.append(item.value)
            }
        }
        for candidate in organismCandidates {
            if let match = organismNameMatch(candidate) {
                return match
            }
        }

        let assemblyCandidates = [manifest.source.assembly, manifest.name, manifest.source.organism]
            + (manifest.source.assemblyAccession.map { [$0] } ?? [])
        for candidate in assemblyCandidates {
            if let token = eukaryoticAssemblyToken(in: candidate) {
                return VariantCallingPloidyInference(
                    ploidy: .diploid,
                    basis: .assemblyName,
                    evidence: "assembly name \"\(candidate)\" (\(token))"
                )
            }
        }

        if let length = manifest.genome?.totalLength, length > 0 {
            if length >= eukaryoticGenomeLengthThreshold {
                return VariantCallingPloidyInference(
                    ploidy: .diploid,
                    basis: .genomeLength,
                    evidence: "a reference of \(formattedLength(length)), larger than any viral or typical bacterial genome"
                )
            }
            return VariantCallingPloidyInference(
                ploidy: .haploid,
                basis: .unknown,
                evidence: "a reference of \(formattedLength(length)) with no organism recorded"
            )
        }

        return VariantCallingPloidyInference(ploidy: .haploid, basis: .unknown, evidence: "no organism recorded")
    }

    // MARK: - Rules

    private static func ploidyNote(in groups: [MetadataGroup]) -> VariantCallingPloidyInference? {
        for group in groups {
            for item in group.items {
                let label = item.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard label == "ploidy" || label == "default ploidy" || label == "default_ploidy" else { continue }
                let value = item.value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if value.contains("haploid") || value == "1" {
                    return VariantCallingPloidyInference(
                        ploidy: .haploid,
                        basis: .metadataPloidyNote,
                        evidence: "the bundle's \"\(item.label)\" note (\(item.value))"
                    )
                }
                if value.contains("diploid") || value == "2" {
                    return VariantCallingPloidyInference(
                        ploidy: .diploid,
                        basis: .metadataPloidyNote,
                        evidence: "the bundle's \"\(item.label)\" note (\(item.value))"
                    )
                }
            }
        }
        return nil
    }

    /// GenBank LOCUS division codes. Viral (VRL), phage (PHG) and bacterial
    /// (BCT) records are haploid; the eukaryotic divisions are diploid.
    /// Structural divisions (CON, PAT, SYN, UNA, ENV, EST, ...) say nothing
    /// about ploidy and fall through.
    private static let haploidDivisions: Set<String> = ["VRL", "PHG", "BCT"]
    private static let diploidDivisions: Set<String> = ["PRI", "ROD", "MAM", "VRT", "INV", "PLN"]

    private static func genbankDivision(in groups: [MetadataGroup]) -> VariantCallingPloidyInference? {
        for group in groups {
            for item in group.items where item.label.caseInsensitiveCompare("Division") == .orderedSame {
                let code = item.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if haploidDivisions.contains(code) {
                    return VariantCallingPloidyInference(
                        ploidy: .haploid,
                        basis: .genbankDivision,
                        evidence: "GenBank division \(code)"
                    )
                }
                if diploidDivisions.contains(code) {
                    return VariantCallingPloidyInference(
                        ploidy: .diploid,
                        basis: .genbankDivision,
                        evidence: "GenBank division \(code)"
                    )
                }
            }
        }
        return nil
    }

    /// Substrings that mark a viral organism name.
    private static let viralNameFragments: [String] = [
        "virus", "viridae", "virales", "virinae", "phage", "viroid",
        "sars-cov", "mers-cov", "hiv-1", "hiv-2",
    ]

    /// Substrings that mark a bacterial or archaeal organism name.
    private static let bacterialNameFragments: [String] = [
        "bacter", "bacillus", "coccus", "escherichia", "salmonella", "shigella",
        "klebsiella", "pseudomonas", "mycobacterium", "mycoplasma", "clostridi",
        "listeria", "vibrio", "streptomyces", "neisseria", "haemophilus",
        "legionella", "bordetella", "yersinia", "borrelia", "treponema",
        "chlamydia", "rickettsia", "archae",
    ]

    /// Genera and common names of eukaryotes LGE users call diploid
    /// genotypes on. Matched against the first word of the organism name and
    /// against the whole lowercased string for common names.
    private static let eukaryoticGenera: Set<String> = [
        "homo", "macaca", "pan", "gorilla", "pongo", "papio", "chlorocebus",
        "callithrix", "saimiri", "mus", "rattus", "cricetulus", "mesocricetus",
        "oryctolagus", "cavia", "bos", "sus", "ovis", "capra", "canis", "felis",
        "equus", "gallus", "meleagris", "anas", "danio", "oryzias", "xenopus",
        "drosophila", "anopheles", "aedes", "caenorhabditis", "arabidopsis",
        "oryza", "zea", "triticum", "solanum", "saccharomyces", "schizosaccharomyces",
        "candida", "cryptococcus", "aspergillus", "plasmodium", "toxoplasma",
        "trypanosoma", "leishmania",
    ]

    private static let eukaryoticCommonNames: [String] = [
        "human", "rhesus", "macaque", "cynomolgus", "marmoset", "baboon",
        "chimpanzee", "mouse", "rat", "hamster", "rabbit", "cattle", "cow",
        "pig", "sheep", "goat", "dog", "cat", "horse", "chicken", "zebrafish",
        "yeast",
    ]

    private static func organismNameMatch(_ rawName: String) -> VariantCallingPloidyInference? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let lowered = name.lowercased()

        if viralNameFragments.contains(where: { lowered.contains($0) }) {
            return VariantCallingPloidyInference(
                ploidy: .haploid,
                basis: .organismName,
                evidence: "organism \"\(name)\" (viral)"
            )
        }
        if bacterialNameFragments.contains(where: { lowered.contains($0) }) {
            return VariantCallingPloidyInference(
                ploidy: .haploid,
                basis: .organismName,
                evidence: "organism \"\(name)\" (bacterial)"
            )
        }

        let words = lowered
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        if let genus = words.first, eukaryoticGenera.contains(genus) {
            return VariantCallingPloidyInference(
                ploidy: .diploid,
                basis: .organismName,
                evidence: "organism \"\(name)\""
            )
        }
        if words.contains(where: { eukaryoticCommonNames.contains($0) }) {
            return VariantCallingPloidyInference(
                ploidy: .diploid,
                basis: .organismName,
                evidence: "organism \"\(name)\""
            )
        }
        return nil
    }

    /// Lowercased tokens that only appear in eukaryotic assembly names.
    /// Matched as substrings of the lowercased candidate so a FASTA slice
    /// imported as `GRCh38.chr20.10.0-10.5Mb` still resolves.
    private static let eukaryoticAssemblyTokens: [String] = [
        "grch3", "grch4", "hg19", "hg38", "hg002", "hg001", "chm13", "t2t-",
        "grcm3", "grcm4", "mm10", "mm39", "mmul", "rhemac", "macfas", "pantro",
        "gorgor", "ponabe", "canfam", "felcat", "bostau", "susscr", "galgal",
        "danrer", "danio", "dm6", "ce11", "tair10", "saccer",
    ]

    private static func eukaryoticAssemblyToken(in candidate: String) -> String? {
        let lowered = candidate.lowercased()
        return eukaryoticAssemblyTokens.first { lowered.contains($0) }
    }

    private static func formattedLength(_ length: Int64) -> String {
        if length >= 1_000_000_000 {
            return String(format: "%.1f Gb", Double(length) / 1_000_000_000)
        }
        if length >= 1_000_000 {
            return String(format: "%.1f Mb", Double(length) / 1_000_000)
        }
        if length >= 1_000 {
            return String(format: "%.1f kb", Double(length) / 1_000)
        }
        return "\(length) bp"
    }
}
