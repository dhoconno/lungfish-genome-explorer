// NCBIGenomeStandIn.swift - The loopback NCBI that lungfish-cli fetch genome reads in tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// The loopback stand-in for NCBI that `fetch genome` reads in the CLI pins, the genome parity
/// class and the event transcripts (Phase 2.10 lane A44, panel decision G5). It answers the
/// assembly's ESearch, by accession or by name, its ESummary, FTP files and assembly report, and
/// the GenBank record's EFetch answers, from `NCBIDownloadPinFixtures`, and the same for a second
/// assembly by accession that differs only
/// in its accession, uid and name, and for a second record with no GFF3 that differs only in its
/// accession (`recordWithoutGFF3Accession`). An ESearch for any other term finds nothing, and an
/// EFetch for any other id is not found, so a test can make an accession fail. It holds no secret,
/// and a run reaches it only through `NCBIServiceEndpoints.standInOriginVariable`, which makes the
/// service send no key.
enum NCBIGenomeStandIn {
    static let assemblyAccession = "GCF_000000001.1"
    /// A second assembly, the first under another accession, uid and name, for a batch of two.
    static let secondAssemblyAccession = "GCF_000000002.1"
    static let secondAssemblyUID = "9900002"
    static let unknownAccession = "GCF_000000009.9"
    /// The part of an ESearch term that finds the first assembly by its name, as the variant-only
    /// reference download searches when a VCF names an assembly but no accession (lane A44 M3).
    static let assemblyNameTerm = "StandInAsm1[Assembly Name]"
    /// A second GenBank record, the first under another accession, for which NCBI serves no GFF3,
    /// so only the record's FEATURES describe its features (BIO on lane A44 M3-2, outside the table).
    static let recordWithoutGFF3Accession = "ZZ000002.1"

    /// `text` about the first assembly, made about the second. Its FTP folder keeps the first's
    /// parent folder, which the JSON answers spell with escaped slashes.
    static func aboutSecondAssembly(_ text: String) -> String {
        text.replacingOccurrences(of: assemblyAccession, with: secondAssemblyAccession)
            .replacingOccurrences(of: "GCA_000000001.1", with: "GCA_000000002.1")
            .replacingOccurrences(of: "StandInAsm1", with: "StandInAsm2")
            .replacingOccurrences(of: "9900001", with: secondAssemblyUID)
    }

    /// `text` about the GenBank record, made about the record NCBI serves no GFF3 for.
    static func aboutRecordWithoutGFF3(_ text: String) -> String {
        text.replacingOccurrences(of: "ZZ000001", with: "ZZ000002")
    }

    /// The FTP path of the assembly's genomic FASTA.
    static let assemblyFASTAPath = NCBIDownloadPinFixtures.assemblyFTPPath + "/"
        + NCBIDownloadPinFixtures.assemblyDirectory + "_genomic.fna.gz"

    /// Starts the stand-in. `served` is a scratch folder for the gzip files it serves. With `hold`,
    /// a GET of an assembly's genomic FASTA waits until the test releases it, so a test can cancel
    /// a run while it downloads.
    static func start(servingIn served: URL, holding hold: StandInHold? = nil) async throws -> LoopbackHTTPStandIn {
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        let folder = NCBIDownloadPinFixtures.assemblyFTPPath + "/" + NCBIDownloadPinFixtures.assemblyDirectory
        let fasta = try await gzipped(NCBIDownloadPinFixtures.assemblyFASTA, as: "genomic.fna", in: served)
        let gff = try await gzipped(NCBIDownloadPinFixtures.assemblyGFF3, as: "genomic.gff", in: served)
        var routes: [String: LoopbackHTTPResponse] = [:]
        let assemblies: [(String) -> String] = [{ $0 }, aboutSecondAssembly]
        for about in assemblies {
            routes[about(folder) + "_genomic.fna.gz"] = fasta
            routes[about(folder) + "_genomic.gff.gz"] = gff
            routes[about(folder) + "_assembly_report.txt"] = .text(about(NCBIDownloadPinFixtures.assemblyReport))
        }
        let summary = StandInText()
        let server = try LoopbackHTTPStandIn.start { [routes] request in
            func value(_ name: String) -> String? { request.queryItems.first { $0.name == name }?.value }
            switch request.path {
            case "/entrez/eutils/esearch.fcgi":
                let term = value("term") ?? ""
                if term.contains(assemblyAccession) || term.contains(assemblyNameTerm) {
                    return .text(NCBIDownloadPinFixtures.assemblyESearchJSON)
                }
                if term.contains(secondAssemblyAccession) {
                    return .text(aboutSecondAssembly(NCBIDownloadPinFixtures.assemblyESearchJSON))
                }
                return .text(#"{"esearchresult":{"count":"0","retmax":"0","retstart":"0","idlist":[]}}"#)
            case "/entrez/eutils/esummary.fcgi":
                return .text(value("id") == secondAssemblyUID ? aboutSecondAssembly(summary.value) : summary.value)
            case "/entrez/eutils/efetch.fcgi":
                // A record's GFF3 is the slow step of `fetch ncbi --bundle` (lane A45), so a test
                // that holds the stand-in cancels the run there.
                if let hold, value("rettype") == "gff3" {
                    hold.waitForRelease()
                }
                switch (value("id"), value("rettype")) {
                case (NCBIDownloadPinFixtures.genBankAccession, "gb"): return .text(NCBIDownloadPinFixtures.genBankRecord)
                case (NCBIDownloadPinFixtures.genBankAccession, "fasta"): return .text(NCBIDownloadPinFixtures.genBankFASTA)
                case (NCBIDownloadPinFixtures.genBankAccession, "gff3"): return .text(NCBIDownloadPinFixtures.genBankGFF3)
                case (recordWithoutGFF3Accession, "gb"): return .text(aboutRecordWithoutGFF3(NCBIDownloadPinFixtures.genBankRecord))
                case (recordWithoutGFF3Accession, "fasta"): return .text(aboutRecordWithoutGFF3(NCBIDownloadPinFixtures.genBankFASTA))
                default: return .notFound
                }
            default:
                if let hold, request.method == "GET", request.path.hasSuffix("_genomic.fna.gz") {
                    hold.waitForRelease()
                }
                return routes[request.path] ?? .notFound
            }
        }
        summary.value = try NCBIDownloadPinFixtures.assemblyESummaryJSON(ftpBase: server.baseURL.absoluteString)
        return server
    }

    /// The gzip bytes NCBI's FTP folder serves for `text`, as the genome pins make them.
    static func gzipped(_ text: String, as name: String, in directory: URL) async throws -> LoopbackHTTPResponse {
        let plain = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: plain)
        let result = try await NativeToolRunner.shared.bgzipCompress(inputPath: plain, keepOriginal: false)
        XCTAssertTrue(result.isSuccess, result.combinedOutput)
        let compressed = try Data(contentsOf: plain.appendingPathExtension("gz"))
        return LoopbackHTTPResponse(contentType: "application/x-gzip", body: compressed)
    }
}

/// Holds the stand-in's answer to a genomic FASTA until the test releases it, or for 30 seconds.
final class StandInHold: Sendable {
    private let released = DispatchSemaphore(value: 0)

    func waitForRelease() {
        if released.wait(timeout: .now() + 30) == .success {
            released.signal() // The next held request passes too.
        }
    }

    func release() {
        released.signal()
    }
}

/// The esummary answer, which names the stand-in's own port and so is set once it started.
private final class StandInText: Sendable {
    private let text = Mutex("")

    var value: String {
        get { text.withLock { $0 } }
        set { text.withLock { $0 = newValue } }
    }
}
