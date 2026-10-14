// PathoplexusServiceEndpoints.swift - Where PathoplexusService sends its LAPIS, backend and authentication requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where a ``PathoplexusService`` sends its requests.
///
/// A release build always sends them to Pathoplexus. A debug build reads one variable,
/// ``standInOriginVariable``, from the environment dictionary the service's init takes, so a test can
/// point both parity sides of a Pathoplexus download at a loopback stand-in, the app in process and
/// `lungfish-cli` through the child's environment (Phase 2.10 decision G5, lane A45 M2). It follows
/// the terms of review ruling Q2a for NCBI (`NCBIServiceEndpoints`). No option, project file,
/// defaults key or downloaded field can set it.
///
/// The variable accepts only `http://127.0.0.1:<port>` or `http://[::1]:<port>`, with an explicit
/// port and no path, user, query or fragment. Any other value sends every request to a loopback
/// port that nothing answers, so it never falls back to the Pathoplexus hosts. It moves the LAPIS,
/// backend and authentication bases onto that origin and nothing else. Pathoplexus takes no API key.
package struct PathoplexusServiceEndpoints: Sendable, Equatable {
    /// The variable a debug build reads.
    package static let standInOriginVariable = "LUNGFISH_PATHOPLEXUS_STAND_IN_ORIGIN"

    /// Pathoplexus's own hosts.
    package static let pathoplexus = PathoplexusServiceEndpoints(
        baseURL: URL(string: "https://lapis.pathoplexus.org/")!,
        backendURL: URL(string: "https://backend.pathoplexus.org/")!,
        authURL: URL(string: "https://authentication.pathoplexus.org/")!,
        isStandIn: false
    )

    /// The LAPIS base, with its trailing slash.
    package let baseURL: URL
    /// The backend base, with its trailing slash.
    package let backendURL: URL
    /// The authentication base, with its trailing slash.
    package let authURL: URL
    /// True when a debug build's environment named a stand-in origin, valid or not.
    package let isStandIn: Bool

    private init(baseURL: URL, backendURL: URL, authURL: URL, isStandIn: Bool) {
        self.baseURL = baseURL
        self.backendURL = backendURL
        self.authURL = authURL
        self.isStandIn = isStandIn
    }

    /// The endpoints `environment` names. A release build reads nothing from it, and an empty
    /// value counts as no value.
    package init(environment: [String: String]) {
        #if DEBUG
        if let value = environment[Self.standInOriginVariable], !value.isEmpty {
            let origin = NCBIServiceEndpoints.loopbackOrigin(value) ?? NCBIServiceEndpoints.unansweredOrigin
            let base = URL(string: origin + "/")!
            self.init(baseURL: base, backendURL: base, authURL: base, isStandIn: true)
            return
        }
        #endif
        self = .pathoplexus
    }
}
