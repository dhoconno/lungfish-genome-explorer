// TwelveSSpeciesLinks.swift — external reference URLs for a 12S species
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds external reference URLs for a matched 12S species, opened in the
/// browser by the viewport's right-click "Learn More" / "View Photo" actions.
///
/// Pure and unit-tested; the builders never trap — if a URL fails to construct
/// they fall back to a Google search so the menu action always does something.
enum TwelveSSpeciesLinks {

    /// NCBI Taxonomy page for the species: by taxid when available, otherwise a
    /// name search.
    static func ncbiTaxonomyURL(taxid: String?, scientificName: String) -> URL {
        let trimmedTaxid = taxid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTaxid.isEmpty {
            if let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(trimmedTaxid)/") {
                return url
            }
        }
        let term = scientificName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scientificName
        return URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=\(term)")
            ?? fallbackSearch(scientificName)
    }

    /// Wikipedia article for the species (carries the lead image).
    static func wikipediaURL(scientificName: String) -> URL {
        let underscored = scientificName.replacingOccurrences(of: " ", with: "_")
        // `.urlPathAllowed` leaves "/" unescaped, which would create a spurious
        // path segment for names like "X/Y"; encode it explicitly.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let path = underscored.addingPercentEncoding(withAllowedCharacters: allowed) ?? underscored
        return URL(string: "https://en.wikipedia.org/wiki/\(path)") ?? fallbackSearch(scientificName)
    }

    private static func fallbackSearch(_ query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.google.com/search?q=\(q)")
            ?? URL(string: "https://www.google.com")!
    }
}
