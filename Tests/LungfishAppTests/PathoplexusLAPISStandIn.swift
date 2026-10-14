// PathoplexusLAPISStandIn.swift - The loopback Pathoplexus that the Pathoplexus rows and fetch pathoplexus read in tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport

/// A loopback stand-in for Pathoplexus's LAPIS (Phase 2.10 lane A45 M2, panel decision G5). It answers
/// `/<organism>/sample/details` with one metadata record and `/<organism>/sample/unalignedNucleotideSequences`
/// with one FASTA record for an accession it holds, and finds nothing for any other. A run reaches it only
/// through `PathoplexusServiceEndpoints.standInOriginVariable`, which a debug build reads. Pathoplexus takes
/// no key, so the stand-in holds no secret.
///
/// Four records cover the Pathoplexus row's four ways. The first has an INSDC accession that the NCBI
/// stand-in serves (`NCBIDownloadPinFixtures.genBankAccession`), the second has none, the third is
/// restricted, and the fourth names an INSDC accession that NCBI does not serve.
enum PathoplexusLAPISStandIn {
    static let organism = "stand-in-virus"

    static let openWithINSDC = "PP_000001"
    static let openNoINSDC = "PP_000002"
    static let restricted = "PP_000003"
    static let openINSDCUnavailable = "PP_000004"
    static let unavailableINSDCAccession = "ZZ000099.1"

    /// One record the stand-in holds. The version is `1` for every record.
    struct Entry {
        let accession: String
        let insdc: String?
        let terms: String
        let sequence: String

        var accessionVersion: String { accession + ".1" }

        var metadata: [String: Any] {
            var fields: [String: Any] = [
                "accession": accession,
                "accessionVersion": accessionVersion,
                "organism": "Stand-in virus",
                "displayName": "Stand-in/\(accession)",
                "dataUseTerms": terms,
                "versionStatus": "LATEST_VERSION",
                "length": sequence.count,
                "geoLocCountry": "Nowhere",
                "sampleCollectionDate": "2024-01-02",
                "releasedDate": "2024-02-03",
                "authors": "Stand-in Author",
                "groupName": "Stand-in group",
            ]
            if let insdc { fields["insdcAccessionFull"] = insdc }
            return fields
        }
    }

    static let sequence = String(repeating: "ACGTTGCA", count: 15)

    static let entries: [Entry] = [
        Entry(accession: openWithINSDC, insdc: NCBIDownloadPinFixtures.genBankAccession, terms: "OPEN", sequence: sequence),
        Entry(accession: openNoINSDC, insdc: nil, terms: "OPEN", sequence: sequence),
        Entry(accession: restricted, insdc: nil, terms: "RESTRICTED", sequence: sequence),
        Entry(accession: openINSDCUnavailable, insdc: unavailableINSDCAccession, terms: "OPEN", sequence: sequence),
    ]

    /// The FASTA the stand-in serves for `entry`, as LAPIS writes it.
    static func fasta(of entry: Entry) -> String {
        ">\(entry.accessionVersion)\n\(entry.sequence)\n"
    }

    static func start() throws -> LoopbackHTTPStandIn {
        try LoopbackHTTPStandIn.start { request in
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 3, parts[0] == organism, parts[1] == "sample" else { return .notFound }
            let wanted = request.queryItems.first { $0.name == "accession" }?.value ?? ""
            let entry = entries.first { $0.accession == wanted || $0.accessionVersion == wanted }
            switch parts[2] {
            case "details":
                let object: [String: Any] = ["data": entry.map { [$0.metadata] } ?? []]
                guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                    return LoopbackHTTPResponse(status: 500)
                }
                return LoopbackHTTPResponse(contentType: "application/json", body: body)
            case "unalignedNucleotideSequences":
                return .text(entry.map(fasta(of:)) ?? "")
            default:
                return .notFound
            }
        }
    }
}
