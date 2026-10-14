// ENAServiceEndpoints.swift - Where ENAService sends its Browser and Portal requests and fetches a run's files from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where an ``ENAService`` sends its requests, and where the files of a run its records name are
/// fetched from.
///
/// A release build always uses ENA's own hosts. A debug build reads one variable,
/// ``standInOriginVariable``, from the environment dictionary the service's init takes, so a test can
/// point both parity sides of an SRA run download at a loopback stand-in, the app in process and
/// `lungfish-cli` through the child's environment (Phase 2.10 decision G5, lane A45 M3c). It follows
/// the terms of review ruling Q2a for NCBI (`NCBIServiceEndpoints`). No option, project file,
/// defaults key or downloaded field can set it.
///
/// The variable accepts only `http://127.0.0.1:<port>` or `http://[::1]:<port>`, with an explicit
/// port and no path, user, query or fragment. Any other value sends every request to a loopback
/// port that nothing answers, so it never falls back to the ENA hosts. It moves the Browser and
/// Portal bases and the mirror the records' file paths are served from onto that origin and nothing
/// else. ENA takes no API key.
package struct ENAServiceEndpoints: Sendable, Equatable {
    /// The variable a debug build reads.
    package static let standInOriginVariable = "LUNGFISH_ENA_STAND_IN_ORIGIN"

    /// ENA's own hosts. Each record's file paths name their own mirror host.
    package static let ena = ENAServiceEndpoints(
        browserBase: URL(string: "https://www.ebi.ac.uk/ena/browser/api/")!,
        portalBase: URL(string: "https://www.ebi.ac.uk/ena/portal/api/")!,
        mirrorOrigin: nil,
        isStandIn: false
    )

    /// The Browser API base, with its trailing slash.
    package let browserBase: URL
    /// The Portal API base, with its trailing slash.
    package let portalBase: URL
    /// The scheme, host and port the files of a run are served from, with no trailing slash, or nil
    /// when each record's paths name the host.
    package let mirrorOrigin: String?
    /// True when a debug build's environment named a stand-in origin, valid or not.
    package let isStandIn: Bool

    private init(browserBase: URL, portalBase: URL, mirrorOrigin: String?, isStandIn: Bool) {
        self.browserBase = browserBase
        self.portalBase = portalBase
        self.mirrorOrigin = mirrorOrigin
        self.isStandIn = isStandIn
    }

    /// The endpoints `environment` names. A release build reads nothing from it, and an empty
    /// value counts as no value.
    package init(environment: [String: String]) {
        #if DEBUG
        if let value = environment[Self.standInOriginVariable], !value.isEmpty {
            let origin = NCBIServiceEndpoints.loopbackOrigin(value) ?? NCBIServiceEndpoints.unansweredOrigin
            self.init(
                browserBase: URL(string: origin + "/ena/browser/api/")!,
                portalBase: URL(string: origin + "/ena/portal/api/")!,
                mirrorOrigin: origin,
                isStandIn: true
            )
            return
        }
        #endif
        self = .ena
    }
}

extension ENAReadRecord {
    /// The URL string a record's file path is fetched from: `https://<path>` for ENA's own mirror, and
    /// `<origin>/<path without its host>` for a stand-in, whatever host the path names, so a record
    /// served to a stand-in never reaches a host outside loopback.
    static func fileURLString(_ ftpPath: String, mirrorOrigin: String?) -> String {
        #if DEBUG
        if let origin = mirrorOrigin {
            guard let slash = ftpPath.firstIndex(of: "/") else { return origin + "/" + ftpPath }
            return origin + ftpPath[slash...]
        }
        #endif
        return "https://\(ftpPath)"
    }
}
