// MockHTTPClient.swift - Mock HTTP client for testing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCore

/// Mock HTTP client for testing network services without actual network calls.
public actor MockHTTPClient: HTTPClient {

    /// Recorded requests
    public private(set) var requests: [URLRequest] = []

    /// Responses to return for specific URL patterns
    private var responses: [(pattern: String, response: MockResponse)] = []

    /// Ordered responses to return for specific URL patterns.
    private var sequencedResponses: [(pattern: String, responses: [MockResponse])] = []

    /// Default response when no pattern matches
    private var defaultResponse: MockResponse?

    public struct MockResponse: Sendable {
        public let data: Data
        public let statusCode: Int
        public let headers: [String: String]

        public init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
        }

        public static func json(_ object: Any, statusCode: Int = 200) -> MockResponse {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return MockResponse(data: data, statusCode: statusCode, headers: ["Content-Type": "application/json"])
        }

        public static func text(_ string: String, statusCode: Int = 200) -> MockResponse {
            return MockResponse(data: string.data(using: .utf8)!, statusCode: statusCode)
        }

        public static func error(statusCode: Int, message: String = "Error") -> MockResponse {
            return MockResponse(data: message.data(using: .utf8)!, statusCode: statusCode)
        }
    }

    public init() {}

    /// Registers a response for a URL pattern.
    public func register(pattern: String, response: MockResponse) {
        responses.append((pattern, response))
    }

    /// Registers ordered responses for a URL pattern.
    public func registerSequence(pattern: String, responses: [MockResponse]) {
        sequencedResponses.append((pattern, responses))
    }

    /// Sets the default response.
    public func setDefault(response: MockResponse) {
        defaultResponse = response
    }

    /// Clears all recorded requests.
    public func clearRequests() {
        requests.removeAll()
    }

    /// Clears all registered responses.
    public func clearResponses() {
        responses.removeAll()
        sequencedResponses.removeAll()
        defaultResponse = nil
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)

        let urlString = request.url?.absoluteString ?? ""

        for index in sequencedResponses.indices {
            if urlString.contains(sequencedResponses[index].pattern),
               !sequencedResponses[index].responses.isEmpty {
                let response = sequencedResponses[index].responses.removeFirst()
                return makeResponse(response, for: request)
            }
        }

        // Find matching response
        for (pattern, response) in responses {
            if urlString.contains(pattern) {
                return makeResponse(response, for: request)
            }
        }

        // Use default response
        if let response = defaultResponse {
            return makeResponse(response, for: request)
        }

        // No response configured - throw error
        throw URLError(.cannotFindHost)
    }

    private func makeResponse(_ mock: MockResponse, for request: URLRequest) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: mock.headers
        )!
        return (mock.data, response)
    }
}

// MARK: - Convenience Extensions

extension MockHTTPClient {

    /// Registers a NCBI esearch response (JSON format).
    public func registerNCBISearch(ids: [String]) {
        let response: [String: Any] = [
            "esearchresult": [
                "count": String(ids.count),
                "retmax": String(ids.count),
                "retstart": "0",
                "idlist": ids
            ]
        ]
        register(pattern: "esearch.fcgi", response: .json(response))
    }

    /// Registers a NCBI efetch FASTA response.
    public func registerNCBIFetch(fasta: String) {
        register(pattern: "efetch.fcgi", response: .text(fasta))
    }

    /// Registers an ENA FASTA response.
    public func registerENAFasta(fasta: String) {
        register(pattern: "/fasta/", response: .text(fasta))
    }

    /// Registers a Pathoplexus aggregated count response.
    public func registerPathoplexusCount(_ count: Int) {
        // LAPIS returns {"data": [{"count": N}]}
        register(pattern: "/aggregated", response: .json(["data": [["count": count]]]))
    }

    /// Registers a Pathoplexus metadata response.
    public func registerPathoplexusMetadata(_ records: [[String: Any]]) {
        register(pattern: "/details", response: .json(["data": records]))
    }

    /// Registers a Keycloak token response.
    public func registerKeycloakToken(accessToken: String = "test-access-token",
                                       refreshToken: String = "test-refresh-token",
                                       expiresIn: Int = 36000) {
        let response: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_in": expiresIn,
            "refresh_expires_in": expiresIn * 2,
            "token_type": "Bearer"
        ]
        register(pattern: "openid-connect/token", response: .json(response))
    }

    /// Registers a Pathoplexus submission response.
    public func registerPathoplexusSubmission(submissionId: String, status: String = "SUBMITTED") {
        let response: [String: Any] = [
            "submissionId": submissionId,
            "sequenceCount": 1,
            "status": status,
            "warnings": []
        ]
        register(pattern: "/submit", response: .json(response))
    }
}
