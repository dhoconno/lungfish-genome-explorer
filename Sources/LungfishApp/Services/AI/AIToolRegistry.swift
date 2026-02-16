// AIToolRegistry.swift - Tool definitions and execution for AI assistant
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os

private let logger = Logger(subsystem: "com.lungfish", category: "AIToolRegistry")

/// Registry of tools available to the AI assistant.
///
/// Each tool has a definition (name, description, parameters) used to tell
/// the LLM what it can call, and an execution function that runs locally
/// to produce results from the app's data.
@MainActor
public final class AIToolRegistry {

    /// The annotation search index providing access to local databases.
    private weak var searchIndex: AnnotationSearchIndex?

    /// Callback to navigate the viewer to a genomic region.
    var navigateToRegion: ((_ chromosome: String, _ start: Int, _ end: Int) -> Void)?

    /// Callback to get the current viewer state.
    var getCurrentViewState: (() -> ViewerState)?

    /// HTTP client used by tools that call external services.
    private let httpClient: HTTPClient

    /// Current viewer state snapshot for context.
    public struct ViewerState: Sendable {
        public let chromosome: String?
        public let start: Int?
        public let end: Int?
        public let organism: String?
        public let assembly: String?
        public let bundleName: String?
        public let chromosomeNames: [String]
        public let annotationTrackCount: Int
        public let variantTrackCount: Int
        public let totalVariantCount: Int
        public let sampleCount: Int
        public let sampleNameExamples: [String]
        public let visibleSampleCount: Int
        public let visibleSampleExamples: [String]
        public let variantTableRowCount: Int
        public let variantTableExamples: [String]
        public let sampleTableRowCount: Int
        public let sampleTableExamples: [String]

        public init(
            chromosome: String? = nil, start: Int? = nil, end: Int? = nil,
            organism: String? = nil, assembly: String? = nil, bundleName: String? = nil,
            chromosomeNames: [String] = [], annotationTrackCount: Int = 0,
            variantTrackCount: Int = 0, totalVariantCount: Int = 0,
            sampleCount: Int = 0, sampleNameExamples: [String] = [],
            visibleSampleCount: Int = 0, visibleSampleExamples: [String] = [],
            variantTableRowCount: Int = 0, variantTableExamples: [String] = [],
            sampleTableRowCount: Int = 0, sampleTableExamples: [String] = []
        ) {
            self.chromosome = chromosome
            self.start = start
            self.end = end
            self.organism = organism
            self.assembly = assembly
            self.bundleName = bundleName
            self.chromosomeNames = chromosomeNames
            self.annotationTrackCount = annotationTrackCount
            self.variantTrackCount = variantTrackCount
            self.totalVariantCount = totalVariantCount
            self.sampleCount = sampleCount
            self.sampleNameExamples = sampleNameExamples
            self.visibleSampleCount = visibleSampleCount
            self.visibleSampleExamples = visibleSampleExamples
            self.variantTableRowCount = variantTableRowCount
            self.variantTableExamples = variantTableExamples
            self.sampleTableRowCount = sampleTableRowCount
            self.sampleTableExamples = sampleTableExamples
        }
    }

    private struct VariantQueryContext: Sendable {
        let variantDBs: [(trackId: String, db: VariantDatabase)]
    }

    public init(searchIndex: AnnotationSearchIndex? = nil, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.searchIndex = searchIndex
        self.httpClient = httpClient
    }

    public func setSearchIndex(_ index: AnnotationSearchIndex) {
        self.searchIndex = index
    }

    // MARK: - Tool Definitions

    /// Returns all tool definitions for the AI provider.
    public var toolDefinitions: [AIToolDefinition] {
        [
            searchGenesDef,
            searchVariantsDef,
            getVariantStatsDef,
            getGeneDetailsDef,
            getCurrentViewDef,
            navigateToGeneDef,
            navigateToRegionDef,
            listChromosomesDef,
            searchPubMedDef,
        ]
    }

    private var searchGenesDef: AIToolDefinition {
        AIToolDefinition(
            name: "search_genes",
            description: "Search for genes and genomic annotations in the loaded genome by name or keyword. Returns matching gene names, types, chromosomal locations, and strand orientation. Use this to find specific genes or discover what genes are present in the loaded data.",
            parameters: [
                AIToolParameter(name: "query", type: .string, description: "Gene name or keyword to search for (case-insensitive, partial match supported). Examples: 'BRCA1', 'kinase', 'LOC', 'HLA'"),
                AIToolParameter(name: "limit", type: .integer, description: "Maximum number of results to return (default 20)", required: false),
            ]
        )
    }

    private var searchVariantsDef: AIToolDefinition {
        AIToolDefinition(
            name: "search_variants",
            description: "Search for genetic variants (SNPs, insertions, deletions, etc.) in the loaded VCF data. Can search by variant ID (e.g., rsID), genomic region, or variant type. Returns variant position, alleles, quality, and type classification.",
            parameters: [
                AIToolParameter(name: "query", type: .string, description: "Variant ID to search for (e.g., 'rs123456'). Leave empty to search by region.", required: false),
                AIToolParameter(name: "chromosome", type: .string, description: "Chromosome name to search within (e.g., 'chr1', '1')", required: false),
                AIToolParameter(name: "start", type: .integer, description: "Start position (0-based) for region search", required: false),
                AIToolParameter(name: "end", type: .integer, description: "End position for region search", required: false),
                AIToolParameter(name: "variant_type", type: .string, description: "Filter by variant type", required: false, enumValues: ["SNP", "INS", "DEL", "MNP", "COMPLEX"]),
                AIToolParameter(name: "limit", type: .integer, description: "Maximum number of results (default 20)", required: false),
            ]
        )
    }

    private var getVariantStatsDef: AIToolDefinition {
        AIToolDefinition(
            name: "get_variant_statistics",
            description: "Get summary statistics about variants in the loaded data. Returns counts by variant type, total variant count, number of samples, and available chromosomes. Useful for getting an overview of the data before diving deeper.",
            parameters: []
        )
    }

    private var getGeneDetailsDef: AIToolDefinition {
        AIToolDefinition(
            name: "get_gene_details",
            description: "Get detailed information about a specific gene annotation, including its exact coordinates, strand, exon structure, and any associated attributes. Also looks for variants within the gene's region.",
            parameters: [
                AIToolParameter(name: "gene_name", type: .string, description: "The exact gene name to look up"),
            ]
        )
    }

    private var getCurrentViewDef: AIToolDefinition {
        AIToolDefinition(
            name: "get_current_view",
            description: "Get information about what the user is currently viewing in the genome browser, including the chromosome, position range, loaded genome assembly, and available data tracks.",
            parameters: []
        )
    }

    private var navigateToGeneDef: AIToolDefinition {
        AIToolDefinition(
            name: "navigate_to_gene",
            description: "Navigate the genome browser to show a specific gene. The view will zoom to the gene's location. Use this after searching for genes to help the user examine a gene of interest.",
            parameters: [
                AIToolParameter(name: "gene_name", type: .string, description: "The gene name to navigate to"),
            ]
        )
    }

    private var navigateToRegionDef: AIToolDefinition {
        AIToolDefinition(
            name: "navigate_to_region",
            description: "Navigate the genome browser to a specific genomic region defined by chromosome, start, and end coordinates.",
            parameters: [
                AIToolParameter(name: "chromosome", type: .string, description: "Chromosome name (e.g., 'chr1', '1')"),
                AIToolParameter(name: "start", type: .integer, description: "Start position (0-based)"),
                AIToolParameter(name: "end", type: .integer, description: "End position"),
            ]
        )
    }

    private var listChromosomesDef: AIToolDefinition {
        AIToolDefinition(
            name: "list_chromosomes",
            description: "List all chromosomes/contigs available in the loaded genome assembly with their sizes.",
            parameters: []
        )
    }

    private var searchPubMedDef: AIToolDefinition {
        AIToolDefinition(
            name: "search_pubmed",
            description: "Search PubMed for scientific literature relevant to a genomics question. Returns article titles, authors, and PMIDs. Use this to find published research about genes, variants, or diseases the user is asking about.",
            parameters: [
                AIToolParameter(name: "query", type: .string, description: "PubMed search query. Use standard PubMed search syntax. For gene-disease associations, try queries like 'BRCA1 breast cancer variants' or 'APP alzheimer genetics'."),
                AIToolParameter(name: "max_results", type: .integer, description: "Maximum number of results (default 5, max 10)", required: false),
            ]
        )
    }

    // MARK: - Tool Execution

    /// Executes a tool call and returns the result.
    public func execute(_ toolCall: AIToolCall) async -> AIToolResult {
        logger.info(
            "Executing tool: \(toolCall.name, privacy: .public) id=\(toolCall.id, privacy: .public) args=\(self.argumentSummary(toolCall.arguments), privacy: .public)"
        )

        do {
            let result: String
            switch toolCall.name {
            case "search_genes":
                result = try await executeSearchGenes(toolCall)
            case "search_variants":
                result = try await executeSearchVariants(toolCall)
            case "get_variant_statistics":
                result = try await executeGetVariantStats(toolCall)
            case "get_gene_details":
                result = try await executeGetGeneDetails(toolCall)
            case "get_current_view":
                result = executeGetCurrentView()
            case "navigate_to_gene":
                result = try await executeNavigateToGene(toolCall)
            case "navigate_to_region":
                result = executeNavigateToRegion(toolCall)
            case "list_chromosomes":
                result = executeListChromosomes()
            case "search_pubmed":
                result = try await executeSearchPubMed(toolCall)
            default:
                return AIToolResult(toolCallId: toolCall.id, content: "Unknown tool: \(toolCall.name)", isError: true)
            }
            logger.info(
                "Tool completed: \(toolCall.name, privacy: .public) id=\(toolCall.id, privacy: .public) chars=\(result.count)"
            )
            return AIToolResult(toolCallId: toolCall.id, content: result)
        } catch {
            logger.error("Tool execution failed: \(toolCall.name) — \(error)")
            return AIToolResult(toolCallId: toolCall.id, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Tool Implementations

    private func snapshotVariantContext() -> VariantQueryContext? {
        guard let searchIndex else { return nil }
        return VariantQueryContext(variantDBs: searchIndex.variantDatabaseHandles)
    }

    private func executeSearchGenes(_ call: AIToolCall) async throws -> String {
        guard let searchIndex else {
            return "No genome data is currently loaded. Please open a .lungfishref bundle first."
        }

        let query = call.string("query") ?? ""
        let limit = call.int("limit") ?? 20

        let results = searchIndex.search(query: query, limit: limit)

        if results.isEmpty {
            return "No genes found matching '\(query)'. Try a different search term or check if annotation data is available."
        }

        var lines: [String] = ["Found \(results.count) result(s) for '\(query)':"]
        for result in results {
            let strand = result.strand == "+" ? "forward" : (result.strand == "-" ? "reverse" : "unknown")
            lines.append("- \(result.name) (\(result.type)) — \(result.chromosome):\(result.start)-\(result.end) (\(strand) strand)")
        }
        return lines.joined(separator: "\n")
    }

    private func executeSearchVariants(_ call: AIToolCall) async throws -> String {
        guard let context = snapshotVariantContext() else {
            return "No genome data is currently loaded."
        }

        if context.variantDBs.isEmpty {
            return "No variant data (VCF) is loaded in the current bundle."
        }

        let query = call.string("query")
        let chromosome = call.string("chromosome")
        let start = call.int("start")
        let end = call.int("end")
        let variantType = call.string("variant_type")
        let limit = call.int("limit") ?? 20

        let allResults = await Task.detached(priority: .userInitiated) { () -> [(trackId: String, records: [VariantDatabaseRecord])] in
            var results: [(trackId: String, records: [VariantDatabaseRecord])] = []
            for (trackId, db) in context.variantDBs {
                let records: [VariantDatabaseRecord]
                if let query, !query.isEmpty {
                    records = db.searchByID(idFilter: query, limit: limit)
                } else if let chromosome, let start, let end {
                    let types: Set<String> = variantType.map { Set([$0]) } ?? []
                    records = db.query(chromosome: chromosome, start: start, end: end, types: types, limit: limit)
                } else if let chromosome {
                    records = db.query(chromosome: chromosome, start: 0, end: 1_000_000, limit: limit)
                } else {
                    let types: Set<String> = variantType.map { Set([$0]) } ?? []
                    records = db.queryForTable(types: types, limit: limit)
                }
                if !records.isEmpty {
                    results.append((trackId, records))
                }
            }
            return results
        }.value

        if allResults.isEmpty {
            var msg = "No variants found"
            if let query { msg += " matching '\(query)'" }
            if let chromosome { msg += " on \(chromosome)" }
            return msg + "."
        }

        var lines: [String] = []
        for (_, records) in allResults {
            lines.append("Found \(records.count) variant(s):")
            for record in records.prefix(limit) {
                let qual = record.quality.map { String(format: "%.1f", $0) } ?? "."
                lines.append("- \(record.variantID) \(record.chromosome):\(record.position + 1) \(record.ref)>\(record.alt) [\(record.variantType)] Q=\(qual) \(record.filter ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func executeGetVariantStats(_ _: AIToolCall) async throws -> String {
        guard let context = snapshotVariantContext() else {
            return "No genome data is currently loaded."
        }

        if context.variantDBs.isEmpty {
            return "No variant data (VCF) is loaded."
        }

        return await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            for (trackId, db) in context.variantDBs {
                let total = db.totalCount()
                let types = db.allTypes()
                let chroms = db.allChromosomes()
                let sampleCount = db.sampleCount()

                lines.append("Variant track '\(trackId)':")
                lines.append("  Total variants: \(total)")
                lines.append("  Samples: \(sampleCount)")
                lines.append("  Variant types: \(types.joined(separator: ", "))")
                lines.append("  Chromosomes: \(chroms.prefix(10).joined(separator: ", "))\(chroms.count > 10 ? " (and \(chroms.count - 10) more)" : "")")

                for type in types {
                    let typeCount = db.queryCountForTable(types: Set([type]))
                    lines.append("  \(type): \(typeCount)")
                }
            }
            return lines.joined(separator: "\n")
        }.value
    }

    private func executeGetGeneDetails(_ call: AIToolCall) async throws -> String {
        guard let searchIndex else {
            return "No genome data is currently loaded."
        }

        guard let geneName = call.string("gene_name") else {
            return "Error: gene_name parameter is required."
        }

        // Search for the gene
        let results = searchIndex.search(query: geneName, limit: 5)

        // Find exact match first, then partial
        let match = results.first { $0.name.caseInsensitiveCompare(geneName) == .orderedSame }
            ?? results.first

        guard let gene = match else {
            return "Gene '\(geneName)' not found in the loaded annotations."
        }

        var lines: [String] = [
            "Gene: \(gene.name)",
            "Type: \(gene.type)",
            "Location: \(gene.chromosome):\(gene.start)-\(gene.end)",
            "Strand: \(gene.strand)",
            "Size: \(gene.end - gene.start) bp",
        ]

        if let context = snapshotVariantContext(), !context.variantDBs.isEmpty {
            let variantSummaries = await Task.detached(priority: .userInitiated) {
                context.variantDBs.compactMap { (_, db) -> (count: Int, variants: [VariantDatabaseRecord])? in
                    let count = db.queryCount(chromosome: gene.chromosome, start: gene.start, end: gene.end)
                    guard count > 0 else { return nil }
                    let variants = db.query(chromosome: gene.chromosome, start: gene.start, end: gene.end, limit: 5)
                    return (count, variants)
                }
            }.value

            for summary in variantSummaries {
                lines.append("Variants in region: \(summary.count)")
                for v in summary.variants {
                    lines.append("  - \(v.variantID) pos:\(v.position + 1) \(v.ref)>\(v.alt) [\(v.variantType)]")
                }
                if summary.count > 5 {
                    lines.append("  ... and \(summary.count - 5) more variants")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func executeGetCurrentView() -> String {
        guard let state = getCurrentViewState?() else {
            return "No genome viewer is currently active."
        }

        var lines: [String] = []
        if let bundle = state.bundleName {
            lines.append("Loaded bundle: \(bundle)")
        }
        if let organism = state.organism {
            lines.append("Organism: \(organism)")
        }
        if let assembly = state.assembly {
            lines.append("Assembly: \(assembly)")
        }
        if let chrom = state.chromosome {
            lines.append("Current chromosome: \(chrom)")
            if let start = state.start, let end = state.end {
                lines.append("Visible region: \(chrom):\(start)-\(end) (\(end - start) bp)")
            }
        }
        lines.append("Chromosomes: \(state.chromosomeNames.count)")
        lines.append("Annotation tracks: \(state.annotationTrackCount)")
        lines.append("Variant tracks: \(state.variantTrackCount)")
        if state.totalVariantCount > 0 {
            lines.append("Total variants: \(state.totalVariantCount)")
        }
        if state.sampleCount > 0 {
            lines.append("Samples: \(state.sampleCount)")
            if !state.sampleNameExamples.isEmpty {
                lines.append("Sample examples: \(state.sampleNameExamples.joined(separator: ", "))")
            }
            lines.append("Visible samples in viewer: \(state.visibleSampleCount)")
            if !state.visibleSampleExamples.isEmpty {
                lines.append("Visible sample examples: \(state.visibleSampleExamples.joined(separator: ", "))")
            }
            if state.sampleTableRowCount > 0 {
                lines.append("Sample table rows: \(state.sampleTableRowCount)")
                if !state.sampleTableExamples.isEmpty {
                    lines.append("Sample table examples: \(state.sampleTableExamples.joined(separator: ", "))")
                }
            }
        }
        if state.variantTableRowCount > 0 {
            lines.append("Variant table rows: \(state.variantTableRowCount)")
            if !state.variantTableExamples.isEmpty {
                lines.append("Variant table examples: \(state.variantTableExamples.joined(separator: " | "))")
            }
        }

        return lines.isEmpty ? "No genome data is currently loaded." : lines.joined(separator: "\n")
    }

    private func executeNavigateToGene(_ call: AIToolCall) async throws -> String {
        guard let searchIndex else {
            return "No genome data is currently loaded."
        }

        guard let geneName = call.string("gene_name") else {
            return "Error: gene_name parameter is required."
        }

        let results = searchIndex.search(query: geneName, limit: 5)
        let match = results.first { $0.name.caseInsensitiveCompare(geneName) == .orderedSame }
            ?? results.first

        guard let gene = match else {
            return "Gene '\(geneName)' not found. Cannot navigate."
        }

        // Add padding around the gene (10% on each side)
        let geneSize = gene.end - gene.start
        let padding = max(geneSize / 10, 100)
        let start = max(0, gene.start - padding)
        let end = gene.end + padding

        navigateToRegion?(gene.chromosome, start, end)
        return "Navigated to \(gene.name) at \(gene.chromosome):\(start)-\(end)"
    }

    private func executeNavigateToRegion(_ call: AIToolCall) -> String {
        guard let chrom = call.string("chromosome") else {
            return "Error: chromosome parameter is required."
        }
        guard let start = call.int("start") else {
            return "Error: start parameter is required."
        }
        guard let end = call.int("end") else {
            return "Error: end parameter is required."
        }

        navigateToRegion?(chrom, start, end)
        return "Navigated to \(chrom):\(start)-\(end)"
    }

    private func executeListChromosomes() -> String {
        guard let state = getCurrentViewState?() else {
            return "No genome data is currently loaded."
        }

        if state.chromosomeNames.isEmpty {
            return "No chromosomes available."
        }

        var lines: [String] = ["Available chromosomes (\(state.chromosomeNames.count)):"]
        for name in state.chromosomeNames.prefix(30) {
            lines.append("- \(name)")
        }
        if state.chromosomeNames.count > 30 {
            lines.append("... and \(state.chromosomeNames.count - 30) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - PubMed Search

    private func executeSearchPubMed(_ call: AIToolCall) async throws -> String {
        guard let query = call.string("query"), !query.isEmpty else {
            return "Error: query parameter is required."
        }
        let maxResults = min(call.int("max_results") ?? 5, 10)
        logger.info("PubMed search start query='\(query, privacy: .public)' maxResults=\(maxResults)")

        let searchURL = try buildPubMedURL(
            path: "esearch.fcgi",
            queryItems: [
                URLQueryItem(name: "db", value: "pubmed"),
                URLQueryItem(name: "retmode", value: "json"),
                URLQueryItem(name: "retmax", value: String(maxResults)),
                URLQueryItem(name: "term", value: query),
            ]
        )
        let searchData = try await fetchData(from: searchURL)

        guard let searchJSON = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let eSearchResult = searchJSON["esearchresult"] as? [String: Any],
              let idList = eSearchResult["idlist"] as? [String],
              !idList.isEmpty else {
            logger.info("PubMed search no results query='\(query, privacy: .public)'")
            return "No PubMed results found for '\(query)'."
        }
        logger.info("PubMed search found \(idList.count) ids for query='\(query, privacy: .public)'")

        let ids = idList.joined(separator: ",")
        let fetchURL = try buildPubMedURL(
            path: "esummary.fcgi",
            queryItems: [
                URLQueryItem(name: "db", value: "pubmed"),
                URLQueryItem(name: "retmode", value: "json"),
                URLQueryItem(name: "id", value: ids),
            ]
        )
        let fetchData = try await fetchData(from: fetchURL)

        guard let fetchJSON = try? JSONSerialization.jsonObject(with: fetchData) as? [String: Any],
              let result = fetchJSON["result"] as? [String: Any] else {
            logger.error("PubMed summary fetch decode failed for query='\(query, privacy: .public)' ids=\(idList.count)")
            return "Found \(idList.count) PubMed result(s) but could not fetch details. PMIDs: \(idList.joined(separator: ", "))"
        }

        var lines: [String] = ["PubMed results for '\(query)' (\(idList.count) found):"]
        for pmid in idList {
            guard let article = result[pmid] as? [String: Any] else { continue }
            let title = article["title"] as? String ?? "Untitled"
            let source = article["source"] as? String ?? ""
            let pubDate = article["pubdate"] as? String ?? ""
            let authors = (article["authors"] as? [[String: Any]])?.prefix(3).compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""

            lines.append("")
            lines.append("PMID: \(pmid)")
            lines.append("Title: \(title)")
            if !authors.isEmpty { lines.append("Authors: \(authors)\(((article["authors"] as? [[String: Any]])?.count ?? 0) > 3 ? " et al." : "")") }
            lines.append("Journal: \(source) (\(pubDate))")
        }

        return lines.joined(separator: "\n")
    }

    private func buildPubMedURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "eutils.ncbi.nlm.nih.gov"
        components.path = "/entrez/eutils/\(path)"
        components.queryItems = queryItems
        guard let url = components.url else {
            throw AIProviderError.invalidResponse("Failed to build PubMed request URL")
        }
        return url
    }

    private func fetchData(from url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        let data: Data
        let response: URLResponse
        do {
            logger.debug("PubMed request \(url.absoluteString, privacy: .public)")
            (data, response) = try await httpClient.data(for: request)
        } catch let urlError as URLError {
            logger.error("PubMed request failed url=\(url.absoluteString, privacy: .public) code=\(urlError.code.rawValue)")
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                throw AIProviderError.networkError("Cannot resolve PubMed host. Check proxy/DNS settings.")
            case .notConnectedToInternet:
                throw AIProviderError.networkError("No internet connection while reaching PubMed.")
            case .timedOut:
                throw AIProviderError.networkError("PubMed request timed out.")
            default:
                throw AIProviderError.networkError("PubMed network error (\(urlError.code.rawValue)).")
            }
        } catch {
            throw AIProviderError.networkError("PubMed request failed: \(error.localizedDescription)")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("PubMed invalid response type url=\(url.absoluteString, privacy: .public)")
            throw AIProviderError.networkError("Invalid HTTP response from PubMed")
        }
        logger.debug(
            "PubMed response status=\(httpResponse.statusCode) bytes=\(data.count) url=\(url.absoluteString, privacy: .public)"
        )
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIProviderError.httpError(statusCode: httpResponse.statusCode, message: "PubMed API error")
        }
        return data
    }

    private func argumentSummary(_ arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        let pairs = arguments
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                let raw = String(describing: value).replacingOccurrences(of: "\n", with: " ")
                let clipped = raw.count > 80 ? String(raw.prefix(80)) + "..." : raw
                return "\(key)=\(clipped)"
            }
        return pairs.joined(separator: ", ")
    }
}
