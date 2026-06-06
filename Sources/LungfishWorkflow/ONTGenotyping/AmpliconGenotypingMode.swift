import Foundation

public enum AmpliconGenotypingMode: String, Codable, Sendable, CaseIterable, Equatable {
    case auto
    case ontBarcodeDemux = "ont-barcode-demux"
    case ontSampleBundles = "ont-sample-bundles"
    case illuminaPaired = "illumina-paired"

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .ontBarcodeDemux:
            return "ONT barcode demux"
        case .ontSampleBundles:
            return "ONT sample bundles"
        case .illuminaPaired:
            return "Illumina sample bundles"
        }
    }

    public var cliArgument: String { rawValue }

    public init?(cliArgument: String) {
        let normalized = cliArgument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "auto":
            self = .auto
        case "ont", "ont-barcode", "ont-barcode-demux", "ont_barcode_demux":
            self = .ontBarcodeDemux
        case "ont-sample-bundles", "ont-sample-bundle", "ont_sample_bundles", "ont-samples":
            self = .ontSampleBundles
        case "illumina", "illumina-paired", "illumina-pe", "illumina_paired":
            self = .illuminaPaired
        default:
            return nil
        }
    }
}

public enum AmpliconGenotypingReadType: String, Codable, Sendable, CaseIterable, Equatable {
    case auto
    case ont
    case illumina

    public var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .ont:
            return "ONT"
        case .illumina:
            return "Illumina"
        }
    }

    public var cliArgument: String { rawValue }

    public init?(cliArgument: String) {
        let normalized = cliArgument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "auto":
            self = .auto
        case "ont", "nanopore", "oxford-nanopore", "oxford_nanopore":
            self = .ont
        case "illumina", "illumina-short-reads", "illumina_short_reads", "short-read", "short-reads":
            self = .illumina
        default:
            return nil
        }
    }
}
