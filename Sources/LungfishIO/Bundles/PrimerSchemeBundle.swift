import Foundation

public struct PrimerSchemeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let name: String
    public let displayName: String
    public let description: String?
    public let organism: String?
    public let referenceAccessions: [ReferenceAccession]
    public let primerCount: Int
    public let ampliconCount: Int
    public let source: String?
    public let sourceURL: String?
    public let version: String?
    public let created: Date?
    public let imported: Date?
    public let attachments: [AttachmentEntry]?

    public var canonicalAccession: String {
        referenceAccessions.first(where: \.canonical)?.accession
            ?? referenceAccessions.first?.accession
            ?? ""
    }

    public var equivalentAccessions: [String] {
        referenceAccessions.filter { !$0.canonical }.map(\.accession)
    }

    public struct ReferenceAccession: Codable, Sendable, Equatable {
        public let accession: String
        public var canonical: Bool = false
        public var equivalent: Bool = false

        private enum CodingKeys: String, CodingKey {
            case accession
            case canonical
            case equivalent
        }

        public init(accession: String, canonical: Bool = false, equivalent: Bool = false) {
            self.accession = accession
            self.canonical = canonical
            self.equivalent = equivalent
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.accession = try container.decode(String.self, forKey: .accession)
            self.canonical = try container.decodeIfPresent(Bool.self, forKey: .canonical) ?? false
            self.equivalent = try container.decodeIfPresent(Bool.self, forKey: .equivalent) ?? false
        }
    }

    public struct AttachmentEntry: Codable, Sendable, Equatable {
        public let path: String
        public let description: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name
        case displayName = "display_name"
        case description
        case organism
        case referenceAccessions = "reference_accessions"
        case primerCount = "primer_count"
        case ampliconCount = "amplicon_count"
        case source
        case sourceURL = "source_url"
        case version
        case created
        case imported
        case attachments
    }
}

public struct PrimerSchemeBundle: Sendable {
    public let url: URL
    public let manifest: PrimerSchemeManifest
    public let bedURL: URL
    public let fastaURL: URL?
    public let provenanceURL: URL

    public enum LoadError: Error, LocalizedError {
        case missingManifest
        case missingBED
        case missingProvenance
        case invalidManifest(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .missingManifest: return "Bundle is missing manifest.json."
            case .missingBED: return "Bundle is missing primers.bed."
            case .missingProvenance: return "Bundle is missing PROVENANCE.md."
            case .invalidManifest(let underlying):
                return "manifest.json is invalid: \(underlying.localizedDescription)"
            }
        }
    }

    public static func load(from url: URL) throws -> PrimerSchemeBundle {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        let bedURL = url.appendingPathComponent("primers.bed")
        let fastaURL = url.appendingPathComponent("primers.fasta")
        let provenanceURL = url.appendingPathComponent("PROVENANCE.md")

        guard fm.fileExists(atPath: manifestURL.path) else { throw LoadError.missingManifest }
        guard fm.fileExists(atPath: bedURL.path) else { throw LoadError.missingBED }
        guard fm.fileExists(atPath: provenanceURL.path) else { throw LoadError.missingProvenance }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PrimerSchemeManifest
        do {
            manifest = try decoder.decode(PrimerSchemeManifest.self, from: data)
        } catch {
            throw LoadError.invalidManifest(underlying: error)
        }

        return PrimerSchemeBundle(
            url: url,
            manifest: manifest,
            bedURL: bedURL,
            fastaURL: fm.fileExists(atPath: fastaURL.path) ? fastaURL : nil,
            provenanceURL: provenanceURL
        )
    }
}
