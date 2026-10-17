// BlastSiteRequestBytesPinTests.swift - The bytes each in-app BLAST site sends to NCBI today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Phase 2.11 lane A65 M1, step 2 (plan decision C1, Q-A1 with Q-B5's lineage). Seven viewer sites
/// BLAST in the app with no command. Before `blast submit` carries them, this pins the request each
/// site's `BlastVerificationRequest` makes `BlastService.verify` send, byte for byte, so the parity
/// class of each site in M2 and M3 can hold the leaf to the same bytes. It passes at the base, where
/// the sites still call the service in process.
///
/// Each row builds the request with the parameters its site passes today. The sites differ only in
/// the Entrez filter (NAO-MGS restricts the search to the taxon's subtree) and the label and taxon
/// id, which reach the record and not the request. Every request goes to a recording client, so no
/// test reaches NCBI.
final class BlastSiteRequestBytesPinTests: XCTestCase {
    /// Two reads in a fixed order, the query every row sends.
    static let reads: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTAC"),
        (id: "read_2", sequence: "GGCCTTAAGG"),
    ]

    struct Site {
        let gapID: String
        let request: BlastVerificationRequest
        /// The form-encoded `ENTREZ_QUERY` value the site adds, nil when it adds none.
        let encodedEntrezQuery: String?
    }

    /// One row per `cli-parity-gap: blast-*` marker, with the parameters of its site at the base.
    static var sites: [Site] {
        let coreNT = BlastDatabaseID.coreNT.rawValue
        let clade: Set<Int> = [11320, 114727]
        return [
            // ViewerViewController+NaoMgs.swift, the request after the mixed subsample.
            Site(gapID: "blast-nao-mgs", request: BlastVerificationRequest(
                taxonName: "Influenza A virus", taxId: 11320, sequences: reads,
                database: coreNT, entrezQuery: "txid11320[Organism:exp]"
            ), encodedEntrezQuery: "txid11320%5BOrganism%3Aexp%5D"),
            // ViewerViewController.swift, the FASTA selection's request.
            Site(gapID: "blast-fasta-selection", request: BlastVerificationRequest(
                taxonName: "2 selected sequences", taxId: 0, sequences: reads, database: coreNT, entrezQuery: nil
            ), encodedEntrezQuery: nil),
            // ViewerViewController+Assembly.swift, a contig selection with no taxon.
            Site(gapID: "blast-assembly", request: BlastVerificationRequest(
                taxonName: "contig_7", taxId: 0, sequences: reads, database: coreNT, entrezQuery: nil
            ), encodedEntrezQuery: nil),
            // ViewerViewController+TwelveS.swift, the unresolved 12S sequences.
            Site(gapID: "blast-12s-unresolved", request: BlastVerificationRequest(
                taxonName: "12S unresolved sequences", taxId: 0, sequences: reads, database: coreNT, entrezQuery: nil
            ), encodedEntrezQuery: nil),
            // ViralDetection+BlastVerification.swift (LungfishIO), which the EsViritu viewer calls.
            Site(gapID: "blast-esviritu", request: BlastVerificationRequest(
                taxonName: "Influenza A virus", taxId: 11320, sequences: reads, database: coreNT, entrezQuery: nil,
                acceptedTaxIds: clade, acceptedTaxonNames: ["Influenza A virus"]
            ), encodedEntrezQuery: nil),
            // TaxTriageOrganism+BlastVerification.swift (LungfishIO), which the TaxTriage viewer calls.
            Site(gapID: "blast-taxtriage", request: BlastVerificationRequest(
                taxonName: "Influenza A virus", taxId: 11320, sequences: reads, database: coreNT, entrezQuery: nil,
                acceptedTaxIds: clade, acceptedTaxonNames: ["Influenza A virus"]
            ), encodedEntrezQuery: nil),
            // NvdBlastHit+BlastVerification.swift (LungfishIO), which the NVD viewer calls for a contig.
            Site(gapID: "blast-nvd", request: BlastVerificationRequest(
                taxonName: "NODE_1_length_900", taxId: 11320, sequences: reads, database: coreNT, entrezQuery: nil,
                acceptedTaxIds: clade, acceptedTaxonNames: ["Influenza A virus"]
            ), encodedEntrezQuery: nil),
        ]
    }

    /// The `CMD=Put` body every site sends, in the service's parameter order, with the site's Entrez
    /// filter last when it has one.
    static func expectedPutBody(encodedEntrezQuery: String?) -> String {
        var body = "CMD=Put&PROGRAM=blastn&DATABASE=core_nt"
            + "&QUERY=%3Eread_1%0AACGTACGTAC%0A%3Eread_2%0AGGCCTTAAGG"
            + "&EXPECT=1e-10&HITLIST_SIZE=5&MAX_NUM_SEQ=5&FORMAT_TYPE=JSON2&WORD_SIZE=28"
            + "&TOOL=lungfish&EMAIL=lungfish-app%40users.noreply.github.com&MEGABLAST=on"
        if let encodedEntrezQuery { body += "&ENTREZ_QUERY=\(encodedEntrezQuery)" }
        return body
    }

    func testEachSiteSendsTodaysPutBytes() async throws {
        XCTAssertEqual(Self.sites.map(\.gapID).count, 7)
        for site in Self.sites {
            let sent = try await Self.firstRequest(sentBy: site.request)
            XCTAssertEqual(sent.method, "POST", site.gapID)
            XCTAssertEqual(sent.url, "https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi", site.gapID)
            XCTAssertEqual(sent.contentType, "application/x-www-form-urlencoded", site.gapID)
            XCTAssertEqual(
                sent.body, Self.expectedPutBody(encodedEntrezQuery: site.encodedEntrezQuery),
                "\(site.gapID) sends other bytes than it did at the base"
            )
        }
    }

    func testStatusAndResultRequestsCarryTheRIDOnly() async throws {
        let client = BlastRecordingClient()
        let service = BlastService(httpClient: client)
        _ = try? await service.checkStatus(rid: "PIN123")
        _ = try? await service.getResults(rid: "PIN123")
        let sent = await client.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.map(\.method), ["GET", "GET"])
        XCTAssertEqual(sent.map(\.queryItems), [
            [
                URLQueryItem(name: "CMD", value: "Get"), URLQueryItem(name: "RID", value: "PIN123"),
                URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo"), URLQueryItem(name: "TOOL", value: "lungfish"),
                URLQueryItem(name: "EMAIL", value: "lungfish-app@users.noreply.github.com"),
            ],
            [
                URLQueryItem(name: "CMD", value: "Get"), URLQueryItem(name: "RID", value: "PIN123"),
                URLQueryItem(name: "FORMAT_TYPE", value: "JSON2"), URLQueryItem(name: "FORMAT_OBJECT", value: "Alignment"),
                URLQueryItem(name: "TOOL", value: "lungfish"),
                URLQueryItem(name: "EMAIL", value: "lungfish-app@users.noreply.github.com"),
            ],
        ])
    }

    /// Runs `verify` on a fresh service until its submission reaches the recording client, then
    /// cancels it in the first poll wait and returns what it sent.
    static func firstRequest(sentBy request: BlastVerificationRequest) async throws -> BlastRecordedRequest {
        let client = BlastRecordingClient()
        let service = BlastService(httpClient: client)
        let run = Task { try await service.verify(request: request) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await client.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        run.cancel()
        _ = try? await run.value
        let first = await client.requests.first
        return try XCTUnwrap(first, "verify sent nothing within 5 seconds")
    }
}

/// One request the recording client read.
struct BlastRecordedRequest: Sendable, Equatable {
    let method: String
    let url: String
    let contentType: String?
    let body: String
    let queryItems: [URLQueryItem]
}

/// Answers a submission with an RID and every other request with a waiting status, and keeps each request.
actor BlastRecordingClient: HTTPClient {
    private(set) var requests: [BlastRecordedRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        requests.append(BlastRecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url.absoluteString.components(separatedBy: "?")[0],
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: String(decoding: request.httpBody ?? Data(), as: UTF8.self),
            queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        ))
        let answer = request.httpMethod == "POST"
            ? "<!--QBlastInfoBegin\n    RID = PIN123\n    RTOE = 30\nQBlastInfoEnd-->"
            : "<!--QBlastInfoBegin\n    Status=WAITING\nQBlastInfoEnd-->"
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(answer.utf8), response)
    }
}
