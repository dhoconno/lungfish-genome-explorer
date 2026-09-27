import Foundation
import LungfishIO

/// The sequencing platform a long-read variant caller is told to expect.
///
/// Medaka calls from Oxford Nanopore reads only. Clair3 takes the platform
/// as `--platform` and needs a model trained for it, so the value here
/// decides both the flag and which shipped model directory is the default.
public enum VariantCallingPlatform: String, Sendable, Codable, CaseIterable, Equatable {
    /// Oxford Nanopore. Clair3 `--platform=ont`.
    case ont
    /// PacBio HiFi (CCS). Clair3 `--platform=hifi`.
    case hifi
    /// Illumina short reads. Clair3 `--platform=ilmn`.
    case ilmn

    public var displayName: String {
        switch self {
        case .ont: return "Oxford Nanopore"
        case .hifi: return "PacBio HiFi"
        case .ilmn: return "Illumina"
        }
    }

    /// The value handed to `run_clair3.sh --platform`.
    public var clair3Value: String { rawValue }

    /// The name of the generic model directory Clair3 ships for the
    /// platform (`models/ont`, `models/hifi`, `models/ilmn`).
    public var clair3DefaultModelName: String { rawValue }

    /// Parses a command-line spelling, accepting the Clair3 names and the
    /// plain-English aliases a user is likely to type.
    public init?(cliValue: String) {
        switch cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ont", "nanopore", "oxford-nanopore", "oxford_nanopore":
            self = .ont
        case "hifi", "pacbio", "pacbio-hifi", "pacbio_hifi", "ccs":
            self = .hifi
        case "ilmn", "illumina":
            self = .ilmn
        default:
            return nil
        }
    }

    /// Maps a SAM `@RG PL:` value onto a platform. `PACBIO` is treated as
    /// HiFi because Clair3 has no CLR model. Returns `nil` for values that
    /// name no supported platform (`ASSEMBLY`, `CDNA`, `IONTORRENT`...).
    public init?(readGroupPlatform: String) {
        let normalized = readGroupPlatform.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "ONT" || normalized.contains("NANOPORE") || normalized.contains("OXFORD") {
            self = .ont
        } else if normalized.contains("PACBIO") || normalized == "HIFI" {
            self = .hifi
        } else if normalized.contains("ILLUMINA") {
            self = .ilmn
        } else {
            return nil
        }
    }

    /// The platform every read group in a BAM header agrees on, or `nil`
    /// when the header has no read group with a recognisable `PL:` value
    /// or when its read groups disagree.
    public static func detect(fromBAMHeader headerText: String) -> VariantCallingPlatform? {
        let platforms = Set(
            SAMParser.parseReadGroups(from: headerText)
                .compactMap { $0.platform }
                .compactMap { VariantCallingPlatform(readGroupPlatform: $0) }
        )
        guard platforms.count == 1 else { return nil }
        return platforms.first
    }

    /// The `PL:` values the header carries, for error messages.
    public static func readGroupPlatformValues(fromBAMHeader headerText: String) -> [String] {
        Array(Set(SAMParser.parseReadGroups(from: headerText).compactMap { $0.platform })).sorted()
    }
}

/// Picks the Clair3 model directory for a run.
///
/// Clair3 wants `--model_path` to be a directory holding `pileup.pt` and
/// `full_alignment.pt`. The bioconda package ships those directories under
/// `bin/models/` next to `run_clair3.sh`, one per chemistry plus a generic
/// `ont`, `hifi` and `ilmn`. The resolver accepts a shipped name, an
/// absolute directory path, or nothing, in which case it prefers the model
/// named by a dorado `basecall_model=` read-group description and falls
/// back to the platform's generic directory.
public enum Clair3ModelResolver {
    public enum ResolutionError: Error, LocalizedError, Equatable {
        case unknownModel(requested: String, platform: VariantCallingPlatform, available: [String])
        case noModelForPlatform(VariantCallingPlatform, available: [String])
        case modelDirectoryMissingWeights(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let requested, let platform, let available):
                return "Clair3 has no model named '\(requested)'. Give the full path of a model folder, or one of the models shipped for \(platform.displayName): \(available.joined(separator: ", "))."
            case .noModelForPlatform(let platform, let available):
                return "Clair3 ships no model for \(platform.displayName) reads in this installation. Available models: \(available.joined(separator: ", ")). Pass a model folder path or a different --platform."
            case .modelDirectoryMissingWeights(let path):
                return "Clair3 model folder \(path) does not contain pileup.pt and full_alignment.pt."
            }
        }
    }

    /// Weight files every Clair3 model directory must hold.
    public static let requiredWeightFiles = ["pileup.pt", "full_alignment.pt"]

    /// Resolves the model directory. `availableModels` are the entry names of
    /// `modelsDirectory`; `directoryExists` answers whether an arbitrary
    /// path is a directory with both weight files, so the pure logic can be
    /// tested without a Clair3 installation.
    public static func resolve(
        requestedModel: String?,
        platform: VariantCallingPlatform,
        readGroupDescriptions: [String] = [],
        modelsDirectory: URL,
        availableModels: [String],
        directoryHoldsWeights: (URL) -> Bool
    ) throws -> URL {
        let shippedForPlatform = availableModels
            .filter { modelName(matches: $0, platform: platform) }
            .sorted()

        if let requested = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if requested.hasPrefix("/") || requested.hasPrefix("~") {
                let expanded = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath, isDirectory: true)
                guard directoryHoldsWeights(expanded) else {
                    throw ResolutionError.modelDirectoryMissingWeights(expanded.path)
                }
                return expanded
            }
            if availableModels.contains(requested) {
                let shipped = modelsDirectory.appendingPathComponent(requested, isDirectory: true)
                guard directoryHoldsWeights(shipped) else {
                    throw ResolutionError.modelDirectoryMissingWeights(shipped.path)
                }
                return shipped
            }
            throw ResolutionError.unknownModel(
                requested: requested,
                platform: platform,
                available: shippedForPlatform
            )
        }

        if platform == .ont,
           let basecallerModel = basecallerModelName(fromReadGroupDescriptions: readGroupDescriptions),
           availableModels.contains(basecallerModel) {
            let matched = modelsDirectory.appendingPathComponent(basecallerModel, isDirectory: true)
            if directoryHoldsWeights(matched) {
                return matched
            }
        }

        let generic = modelsDirectory.appendingPathComponent(platform.clair3DefaultModelName, isDirectory: true)
        guard availableModels.contains(platform.clair3DefaultModelName), directoryHoldsWeights(generic) else {
            throw ResolutionError.noModelForPlatform(platform, available: availableModels.sorted())
        }
        return generic
    }

    /// Whether a shipped model name belongs to a platform, by Clair3's own
    /// naming: `ont*`, `r941_*`, `r1041_*` are nanopore; `hifi*` is HiFi;
    /// `ilmn*` is Illumina.
    public static func modelName(matches name: String, platform: VariantCallingPlatform) -> Bool {
        let lower = name.lowercased()
        switch platform {
        case .ont:
            return lower.hasPrefix("ont") || lower.hasPrefix("r941") || lower.hasPrefix("r1041") || lower.hasPrefix("r104")
        case .hifi:
            return lower.hasPrefix("hifi")
        case .ilmn:
            return lower.hasPrefix("ilmn")
        }
    }

    /// Turns a dorado read-group description such as
    /// `basecall_model=dna_r10.4.1_e8.2_400bps_sup@v5.0.0` into Clair3's
    /// `r1041_e82_400bps_sup_v500`. Returns `nil` when no description names
    /// a basecall model in that form.
    public static func basecallerModelName(fromReadGroupDescriptions descriptions: [String]) -> String? {
        let pattern = /basecall_model=dna_r(\d+)\.(\d+)\.(\d+)_e(\d+)\.(\d+)_(\d+bps)_(fast|hac|sup)@v(\d+)\.(\d+)\.(\d+)/
        for description in descriptions {
            guard let match = description.firstMatch(of: pattern) else { continue }
            let pore = "r\(match.1)\(match.2)\(match.3)"
            let enzyme = "e\(match.4)\(match.5)"
            let speed = String(match.6)
            let accuracy = String(match.7)
            let version = "v\(match.8)\(match.9)\(match.10)"
            return "\(pore)_\(enzyme)_\(speed)_\(accuracy)_\(version)"
        }
        return nil
    }
}
