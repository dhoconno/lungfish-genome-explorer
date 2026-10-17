// BlastServiceEndpoints.swift - Where BlastService sends its NCBI BLAST URL API requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a ``BlastService`` sends its BLAST URL API requests.
///
/// A release build always sends them to NCBI. A debug build reads one variable,
/// ``standInOriginVariable``, from the environment the service's init takes, so a test can point
/// both parity sides of a BLAST search at a loopback stand-in server, the app in process and
/// `lungfish-cli blast submit` through the child's environment (Phase 2.10 decision G5, Phase 2.11
/// lane A65). No option, project file, defaults key or downloaded field can set it. The variable
/// accepts the loopback origins ``NCBIServiceEndpoints`` accepts, and any other value sends every
/// request to a loopback port that nothing answers, so it never falls back to NCBI.
package struct BlastServiceEndpoints: Sendable, Equatable {
    /// The variable a debug build reads.
    package static let standInOriginVariable = "LUNGFISH_BLAST_STAND_IN_ORIGIN"

    /// The path of the BLAST CGI under its origin.
    package static let cgiPath = "/blast/Blast.cgi"

    /// NCBI's own BLAST CGI.
    package static let ncbi = BlastServiceEndpoints(
        blastURL: URL(string: "https://blast.ncbi.nlm.nih.gov" + cgiPath)!,
        isStandIn: false
    )

    /// The URL every submission, status poll and result fetch goes to.
    package let blastURL: URL
    /// True when a debug build's environment named a stand-in origin, valid or not. A stand-in
    /// reaches no NCBI host, so a service that talks to one spends none of NCBI's hourly budget.
    package let isStandIn: Bool

    private init(blastURL: URL, isStandIn: Bool) {
        self.blastURL = blastURL
        self.isStandIn = isStandIn
    }

    /// The endpoints `environment` names. A release build reads nothing from it, and an empty
    /// value counts as no value.
    package init(environment: [String: String]) {
        #if DEBUG
        if let value = environment[Self.standInOriginVariable], !value.isEmpty {
            let origin = NCBIServiceEndpoints.loopbackOrigin(value) ?? NCBIServiceEndpoints.unansweredOrigin
            self.init(blastURL: URL(string: origin + Self.cgiPath)!, isStandIn: true)
            return
        }
        #endif
        self = .ncbi
    }
}
