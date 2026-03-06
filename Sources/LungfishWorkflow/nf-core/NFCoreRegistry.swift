// NFCoreRegistry.swift - nf-core pipeline registry client
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log

// MARK: - NFCoreRegistry

/// Actor for accessing the nf-core pipeline registry.
///
/// This registry provides access to the collection of community-curated
/// nf-core Nextflow pipelines, allowing discovery, search, and metadata
/// retrieval.
///
/// ## Example
///
/// ```swift
/// let registry = NFCoreRegistry()
///
/// // List all pipelines
/// let pipelines = try await registry.listPipelines()
/// print("Found \(pipelines.count) nf-core pipelines")
///
/// // Search for specific pipelines
/// let results = try await registry.search(query: "rna-seq")
/// for pipeline in results {
///     print("\(pipeline.name): \(pipeline.description)")
/// }
///
/// // Get pipeline details
/// let rnaseq = try await registry.getPipeline(name: "rnaseq")
/// print("Latest version: \(rnaseq.latestVersion ?? "N/A")")
/// ```
public actor NFCoreRegistry {

    // MARK: - Properties

    private static let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "NFCoreRegistry"
    )

    /// Base URL for the nf-core API.
    private let apiBaseURL = URL(string: "https://nf-co.re/pipelines.json")!

    /// GitHub API base URL for additional data.
    private let githubAPIURL = URL(string: "https://api.github.com")!

    /// Cached list of pipelines.
    private var cachedPipelines: [NFCorePipeline]?

    /// Cache timestamp.
    private var cacheTimestamp: Date?

    /// Cache duration (1 hour).
    private let cacheDuration: TimeInterval = 3600

    /// HTTP session for requests.
    private let session: URLSession

    // MARK: - Initialization

    /// Creates a new nf-core registry client.
    ///
    /// - Parameter session: URL session for HTTP requests (defaults to shared)
    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public Methods

    /// Lists all available nf-core pipelines.
    ///
    /// Results are cached for performance. Use `refresh()` to force
    /// a cache refresh.
    ///
    /// - Returns: Array of nf-core pipelines
    /// - Throws: `NFCoreRegistryError` if the request fails
    public func listPipelines() async throws -> [NFCorePipeline] {
        Self.logger.info("Listing nf-core pipelines")

        // Check cache
        if let cached = cachedPipelines,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheDuration {
            Self.logger.debug("Returning cached pipelines (\(cached.count) items)")
            return cached
        }

        // Fetch from API
        let pipelines = try await fetchPipelines()

        // Update cache
        cachedPipelines = pipelines
        cacheTimestamp = Date()

        Self.logger.info("Fetched \(pipelines.count) pipelines from nf-core")
        return pipelines
    }

    /// Searches for pipelines matching a query.
    ///
    /// Searches pipeline names, descriptions, and topics.
    ///
    /// - Parameter query: Search query string
    /// - Returns: Array of matching pipelines
    /// - Throws: `NFCoreRegistryError` if the request fails
    public func search(query: String) async throws -> [NFCorePipeline] {
        Self.logger.info("Searching nf-core pipelines for: \(query)")

        let allPipelines = try await listPipelines()
        let lowercasedQuery = query.lowercased()

        let results = allPipelines.filter { pipeline in
            pipeline.name.lowercased().contains(lowercasedQuery) ||
            pipeline.description.lowercased().contains(lowercasedQuery) ||
            pipeline.topics.contains { $0.lowercased().contains(lowercasedQuery) }
        }

        Self.logger.info("Found \(results.count) matching pipelines")
        return results
    }

    /// Gets a specific pipeline by name.
    ///
    /// - Parameter name: Pipeline name (e.g., "rnaseq")
    /// - Returns: The pipeline details
    /// - Throws: `NFCoreRegistryError` if not found or request fails
    public func getPipeline(name: String) async throws -> NFCorePipeline {
        Self.logger.info("Getting pipeline: \(name)")

        let allPipelines = try await listPipelines()

        guard let pipeline = allPipelines.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw NFCoreRegistryError.pipelineNotFound(name)
        }

        return pipeline
    }

    /// Lists pipelines by category.
    ///
    /// - Parameter category: The category to filter by
    /// - Returns: Array of pipelines in the category
    public func listPipelines(category: NFCorePipelineCategory) async throws -> [NFCorePipeline] {
        Self.logger.info("Listing pipelines in category: \(category.displayName)")

        let allPipelines = try await listPipelines()

        return allPipelines.filter { pipeline in
            NFCorePipelineCategory.categorize(pipeline) == category
        }
    }

    /// Gets the schema for a pipeline.
    ///
    /// - Parameters:
    ///   - name: Pipeline name
    ///   - version: Optional version (defaults to latest)
    /// - Returns: URL to the schema file
    public func getSchemaURL(
        for name: String,
        version: String? = nil
    ) async throws -> URL {
        let pipeline = try await getPipeline(name: name)
        let targetVersion = version ?? pipeline.latestVersion ?? "main"

        return URL(string: "https://raw.githubusercontent.com/nf-core/\(name)/\(targetVersion)/nextflow_schema.json")!
    }

    /// Downloads and parses the schema for a pipeline.
    ///
    /// - Parameters:
    ///   - name: Pipeline name
    ///   - version: Optional version (defaults to latest)
    /// - Returns: Parsed workflow schema
    public func getSchema(
        for name: String,
        version: String? = nil
    ) async throws -> UnifiedWorkflowSchema {
        let schemaURL = try await getSchemaURL(for: name, version: version)

        Self.logger.info("Fetching schema from: \(schemaURL.absoluteString)")

        // Download schema
        var request = URLRequest(url: schemaURL)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NFCoreRegistryError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw NFCoreRegistryError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Save to temp file and parse
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_schema.json")
        try data.write(to: tempURL)

        let parser = NextflowSchemaParser()
        return try await parser.parse(from: tempURL)
    }

    /// Refreshes the pipeline cache.
    public func refresh() async throws {
        Self.logger.info("Refreshing pipeline cache")
        cachedPipelines = nil
        cacheTimestamp = nil
        _ = try await listPipelines()
    }

    /// Gets the list of available versions for a pipeline.
    ///
    /// - Parameter name: Pipeline name
    /// - Returns: Array of version strings
    public func getVersions(for name: String) async throws -> [String] {
        let pipeline = try await getPipeline(name: name)
        return pipeline.versions
    }

    // MARK: - Private Methods

    /// Fetches pipelines from the nf-core API.
    private func fetchPipelines() async throws -> [NFCorePipeline] {
        var request = URLRequest(url: apiBaseURL)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Network request failed: \(error.localizedDescription)")
            throw NFCoreRegistryError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NFCoreRegistryError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw NFCoreRegistryError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Parse response
        let rawPipelines: RawPipelinesResponse
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rawPipelines = try decoder.decode(RawPipelinesResponse.self, from: data)
        } catch {
            Self.logger.error("JSON parsing failed: \(error.localizedDescription)")
            throw NFCoreRegistryError.parseError(error.localizedDescription)
        }

        // Convert to our model
        return rawPipelines.pipelines.compactMap { raw in
            convertToPipeline(raw)
        }
    }

    /// Converts a raw API response to our pipeline model.
    private func convertToPipeline(_ raw: RawPipeline) -> NFCorePipeline? {
        guard let repoURL = URL(string: "https://github.com/nf-core/\(raw.name)") else {
            return nil
        }

        let schemaURL = raw.latestRelease.flatMap { version in
            URL(string: "https://raw.githubusercontent.com/nf-core/\(raw.name)/\(version)/nextflow_schema.json")
        }

        let docsURL = URL(string: "https://nf-co.re/\(raw.name)")

        let logoURL = URL(string: "https://raw.githubusercontent.com/nf-core/\(raw.name)/master/docs/images/nf-core-\(raw.name)_logo_light.png")

        return NFCorePipeline(
            name: raw.name,
            description: raw.description ?? "",
            tagline: raw.tagline,
            topics: raw.topics ?? [],
            latestVersion: raw.latestRelease,
            versions: raw.releases?.map { $0.tag } ?? [],
            stargazersCount: raw.stargazersCount,
            schemaURL: schemaURL,
            repositoryURL: repoURL,
            documentationURL: docsURL,
            logoURL: logoURL,
            isArchived: raw.archived ?? false,
            isReleased: raw.latestRelease != nil,
            updatedAt: raw.updatedAt,
            maintainers: raw.maintainers ?? []
        )
    }
}

// MARK: - NFCoreRegistryError

/// Errors that can occur when accessing the nf-core registry.
public enum NFCoreRegistryError: Error, LocalizedError, Sendable {
    case networkError(String)
    case parseError(String)
    case pipelineNotFound(String)
    case schemaNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .pipelineNotFound(let name):
            return "Pipeline not found: \(name)"
        case .schemaNotFound(let name):
            return "Schema not found for pipeline: \(name)"
        }
    }
}

// MARK: - Raw API Response Types

/// Raw response from the nf-core pipelines API.
private struct RawPipelinesResponse: Decodable {
    let pipelines: [RawPipeline]

    enum CodingKeys: String, CodingKey {
        case pipelines = "remote_workflows"
    }
}

/// Raw pipeline data from the API.
private struct RawPipeline: Decodable {
    let name: String
    let description: String?
    let tagline: String?
    let topics: [String]?
    let latestRelease: String?
    let releases: [RawRelease]?
    let stargazersCount: Int?
    let archived: Bool?
    let updatedAt: Date?
    let maintainers: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case tagline
        case topics
        case latestRelease = "latest_release"
        case releases
        case stargazersCount = "stargazers_count"
        case archived
        case updatedAt = "updated_at"
        case maintainers
    }
}

/// Raw release data from the API.
private struct RawRelease: Decodable {
    let tag: String
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case publishedAt = "published_at"
    }
}
