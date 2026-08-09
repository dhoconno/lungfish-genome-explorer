// BlastService+Parsing.swift - NCBI BLAST URL API client
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// Logger for BLAST service operations.
private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastService")

// MARK: - JSON2 Result Parsing

extension BlastService {

    /// Parses BLAST JSON2 results into search result models.
    ///
    /// The JSON2 format has this structure:
    /// ```json
    /// {
    ///   "BlastOutput2": [
    ///     {
    ///       "report": {
    ///         "results": {
    ///           "search": {
    ///             "query_title": "read1",
    ///             "query_len": 150,
    ///             "hits": [...]
    ///           }
    ///         }
    ///       }
    ///     }
    ///   ]
    /// }
    /// ```
    ///
    /// - Parameter data: Raw JSON data
    /// - Returns: Array of parsed search results
    /// - Throws: ``BlastServiceError/resultParsingFailed`` on parse failure
    nonisolated func parseJSON2Results(_ data: Data) throws -> [BlastSearchResult] {
        // The BLAST API sometimes wraps JSON inside HTML. Try to extract
        // the JSON portion if the data starts with HTML.
        let jsonData = try extractJSONFromResponse(data)

        // Try parsing directly first, then log the specific error
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            let preview = String(data: jsonData.prefix(300), encoding: .utf8) ?? "(non-UTF8)"
            logger.error("parseJSON2Results: JSONSerialization failed: \(error.localizedDescription, privacy: .public)")
            logger.error("parseJSON2Results: first 300 chars: \(preview, privacy: .public)")
            throw BlastServiceError.resultParsingFailed(message: "\(error.localizedDescription)")
        }

        guard let json = jsonObject as? [String: Any] else {
            throw BlastServiceError.resultParsingFailed(message: "Response is not a JSON object")
        }

        guard let blastOutput2 = json["BlastOutput2"] as? [[String: Any]] else {
            // Log available keys for debugging
            let keys = json.keys.sorted().joined(separator: ", ")
            logger.error("parseJSON2Results: Missing BlastOutput2 array. Available keys: \(keys, privacy: .public)")
            throw BlastServiceError.resultParsingFailed(message: "Missing BlastOutput2 array (keys: \(keys))")
        }

        return try blastOutput2.compactMap { entry in
            try parseBlastOutput2Entry(entry)
        }
    }

    /// Parses a single BlastOutput2 entry.
    private nonisolated func parseBlastOutput2Entry(_ entry: [String: Any]) throws -> BlastSearchResult? {
        guard let report = entry["report"] as? [String: Any],
              let results = report["results"] as? [String: Any],
              let search = results["search"] as? [String: Any] else {
            return nil
        }

        let queryTitle = search["query_title"] as? String ?? "unknown"
        let queryLen = search["query_len"] as? Int ?? 0
        let hitsArray = search["hits"] as? [[String: Any]] ?? []

        let hits: [BlastHit] = hitsArray.compactMap { hitDict in
            parseHit(hitDict)
        }

        return BlastSearchResult(queryId: queryTitle, queryLength: queryLen, hits: hits)
    }

    /// Parses a single hit from the JSON2 hits array.
    private nonisolated func parseHit(_ hitDict: [String: Any]) -> BlastHit? {
        let descriptions = hitDict["description"] as? [[String: Any]] ?? []
        guard let firstDesc = descriptions.first else { return nil }

        let accession = firstDesc["accession"] as? String ?? ""
        let title = firstDesc["title"] as? String ?? ""
        let organism = firstDesc["sciname"] as? String
        let taxId = firstDesc["taxid"] as? Int

        let hspsArray = hitDict["hsps"] as? [[String: Any]] ?? []
        let hsps: [BlastHSP] = hspsArray.compactMap { hspDict in
            parseHSP(hspDict)
        }

        guard !hsps.isEmpty else { return nil }

        return BlastHit(accession: accession, title: title, organism: organism, taxId: taxId, hsps: hsps)
    }

    /// Parses a single HSP from the JSON2 hsps array.
    private nonisolated func parseHSP(_ hspDict: [String: Any]) -> BlastHSP? {
        guard let bitScore = hspDict["bit_score"] as? Double,
              let evalue = hspDict["evalue"] as? Double,
              let identity = hspDict["identity"] as? Int,
              let alignLen = hspDict["align_len"] as? Int,
              let queryFrom = hspDict["query_from"] as? Int,
              let queryTo = hspDict["query_to"] as? Int else {
            return nil
        }

        return BlastHSP(
            bitScore: bitScore,
            evalue: evalue,
            identity: identity,
            alignLength: alignLen,
            queryFrom: queryFrom,
            queryTo: queryTo
        )
    }

    /// Extracts JSON from a response that may be wrapped in HTML.
    ///
    /// The BLAST API sometimes returns JSON inside an HTML wrapper.
    /// This method tries direct JSON parsing first, then falls back to
    /// extracting JSON content from HTML.
    ///
    /// - Parameter data: Raw response data
    /// - Returns: JSON data suitable for parsing
    private nonisolated func extractJSONFromResponse(_ data: Data) throws -> Data {
        // NCBI responses sometimes contain Latin-1 characters (accented organism
        // names, non-ASCII descriptions). Try UTF-8 first, fall back to Latin-1.
        guard var body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw BlastServiceError.resultParsingFailed(message: "Non-UTF8 response (\(data.count) bytes)")
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it starts with '{' or '[', it's already JSON
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let result = trimmed.data(using: .utf8) {
                return result
            }
        }

        // NCBI sometimes returns HTML with JSON inside <PRE> tags.
        // Extract content between <PRE>...</PRE> (case-insensitive).
        if let preRange = body.range(of: "<PRE>", options: .caseInsensitive),
           let preEndRange = body.range(of: "</PRE>", options: .caseInsensitive, range: preRange.upperBound..<body.endIndex) {
            let preContent = String(body[preRange.upperBound..<preEndRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if preContent.hasPrefix("{"), let result = preContent.data(using: .utf8) {
                // Recurse to handle any additional unwrapping
                return try extractJSONFromResponse(result)
            }
        }

        // NCBI sometimes HTML-entity-encodes quotes in the response.
        // Decode common entities before searching for JSON markers.
        if body.contains("&quot;") || body.contains("&amp;") {
            body = body
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
        }

        // Look for "BlastOutput2" and walk backwards to find the opening brace.
        // This handles both compact ({"BlastOutput2") and pretty-printed
        // ({\n  "BlastOutput2") JSON embedded in HTML.
        if let jsonData = extractBalancedJSON(from: body, marker: "\"BlastOutput2\"") {
            return jsonData
        }

        // Last resort: try to find any top-level JSON object with "report" key
        // (some NCBI responses use a slightly different wrapper)
        if let jsonData = extractBalancedJSON(from: body, marker: "\"report\"") {
            return jsonData
        }

        throw BlastServiceError.resultParsingFailed(
            message: "Could not find JSON in response (\(data.count) bytes, first 200: \(String(trimmed.prefix(200))))"
        )
    }

    /// Extracts a balanced JSON object from a string, searching backwards from a marker.
    private nonisolated func extractBalancedJSON(from body: String, marker: String) -> Data? {
        guard let markerRange = body.range(of: marker) else { return nil }

        // Walk backwards from the marker to find the opening '{'
        var openBraceIndex = markerRange.lowerBound
        var found = false
        while openBraceIndex > body.startIndex {
            openBraceIndex = body.index(before: openBraceIndex)
            if body[openBraceIndex] == "{" {
                found = true
                break
            }
        }
        guard found else { return nil }

        // Walk forward from the opening brace to find the balanced closing brace.
        // Tracks whether the scan is inside a quoted JSON string literal (toggling on
        // an unescaped '"', skipping the character after a backslash) so that a brace
        // character appearing inside a BLAST hit description/title/organism name
        // (NCBI titles can legitimately contain '{' or '}') does not desynchronize the
        // depth counter -- matching the quote/escape handling DelimitedLineParser.fields
        // uses for the analogous CSV-quoting problem, though JSON's backslash-escape
        // convention (not CSV's doubled-quote convention) is the correct one here
        // (R3-R3ML-12).
        let substring = body[openBraceIndex...]
        var depth = 0
        var endIndex = substring.startIndex
        var insideString = false
        var index = substring.startIndex
        while index < substring.endIndex {
            let ch = substring[index]
            if insideString {
                if ch == "\\" {
                    // Skip the escaped character entirely (handles \" and \\ alike);
                    // if this is the last character, the loop's increment below ends
                    // iteration safely.
                    index = substring.index(after: index)
                    if index < substring.endIndex {
                        index = substring.index(after: index)
                    }
                    continue
                } else if ch == "\"" {
                    insideString = false
                }
            } else if ch == "\"" {
                insideString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = substring.index(after: index)
                    break
                }
            }
            index = substring.index(after: index)
        }
        let jsonString = String(substring[substring.startIndex..<endIndex])
        return jsonString.data(using: .utf8)
    }
}
