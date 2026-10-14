// NCBIServiceEndpoints.swift - Where NCBIService sends its EUtils and Datasets requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where an ``NCBIService`` sends its EUtils and Datasets requests.
///
/// A release build always sends them to NCBI. A debug build reads one variable,
/// ``standInOriginVariable``, from the environment dictionary the service's init takes, so a test
/// can point both parity sides of a download at a loopback stand-in server, the app in process and
/// `lungfish-cli` through the child's environment (Phase 2.10 decision G5, review ruling Q2a). No
/// option, project file, defaults key or downloaded field can set it.
///
/// The variable accepts only `http://127.0.0.1:<port>` or `http://[::1]:<port>`, with an explicit
/// port and no path, user, query or fragment. Any other value sends every request to a loopback
/// port that nothing answers, so it never falls back to the NCBI hosts. While the variable is set
/// the service resolves no API key, so no key reaches a stand-in, its recorded requests or a log.
/// It moves the EUtils base and the Datasets origin and nothing else. A download from an assembly's
/// FTP folder keeps following the path its summary names.
package struct NCBIServiceEndpoints: Sendable, Equatable {
    /// The variable a debug build reads.
    package static let standInOriginVariable = "LUNGFISH_NCBI_STAND_IN_ORIGIN"

    /// NCBI's own hosts.
    package static let ncbi = NCBIServiceEndpoints(
        eutilsBase: URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/")!,
        datasetsOrigin: "https://api.ncbi.nlm.nih.gov",
        isStandIn: false
    )

    /// The EUtils base, with its trailing slash.
    package let eutilsBase: URL
    /// The scheme, host and port the Datasets API paths go under, with no trailing slash.
    package let datasetsOrigin: String
    /// True when a debug build's environment named a stand-in origin, valid or not.
    package let isStandIn: Bool

    private init(eutilsBase: URL, datasetsOrigin: String, isStandIn: Bool) {
        self.eutilsBase = eutilsBase
        self.datasetsOrigin = datasetsOrigin
        self.isStandIn = isStandIn
    }

    /// The endpoints `environment` names. A release build reads nothing from it, and an empty
    /// value counts as no value.
    package init(environment: [String: String]) {
        #if DEBUG
        if let value = environment[Self.standInOriginVariable], !value.isEmpty {
            let origin = Self.loopbackOrigin(value) ?? Self.unansweredOrigin
            self.init(eutilsBase: URL(string: origin + "/entrez/eutils/")!, datasetsOrigin: origin, isStandIn: true)
            return
        }
        #endif
        self = .ncbi
    }

    #if DEBUG
    /// The origin every request goes to when the variable holds a value that is not a loopback
    /// origin. Nothing listens on port 0, so each request fails on loopback.
    static let unansweredOrigin = "http://127.0.0.1:0"

    /// `value` as `http://127.0.0.1:<port>` or `http://[::1]:<port>`, or nil when it is anything else.
    static func loopbackOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              let host = components.host,
              let port = components.port, (1...65_535).contains(port),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil
        else { return nil }
        switch host {
        case "127.0.0.1": return "http://127.0.0.1:\(port)"
        case "::1", "[::1]": return "http://[::1]:\(port)"
        default: return nil
        }
    }
    #endif
}
