// BlastHTTPClient.swift - BLAST's own sessions, which keep no cookie or reply and name only what LGE chose
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The HTTP client of every BLAST contact.
///
/// `URLSession.shared` would hold on to NCBI's session cookie and send it back, so that all of this Mac's searches read
/// as one session, could answer a status check from its cache, and names this Mac's system and languages. These sessions
/// do none of that (ARCH-BLAST-RESILIENCE section 9).
///
/// Checks and fetches wait for a connection, since a check that waits is no news (section 5). A POST does not wait,
/// since a POST that waited and timed out would read as one that may have been sent, when it never left this Mac.
public struct BlastHTTPClient: HTTPClient {
    /// All that a request says of its sender. NCBI gets LGE's name as `tool` as well.
    package static let userAgent = "lungfish"
    package static let acceptLanguage = "en"

    private static let waiting = URLSession(configuration: configuration(waitsForConnectivity: true))
    private static let notWaiting = URLSession(configuration: configuration(waitsForConnectivity: false))

    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session(for: request).data(for: request)
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session(for: request).download(for: request)
    }

    private func session(for request: URLRequest) -> URLSession {
        request.httpMethod == "POST" ? Self.notWaiting : Self.waiting
    }

    private static func configuration(waitsForConnectivity: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": acceptLanguage]
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.timeoutIntervalForResource = BlastSearchPolicy.contactResourceLimit
        return configuration
    }
}
