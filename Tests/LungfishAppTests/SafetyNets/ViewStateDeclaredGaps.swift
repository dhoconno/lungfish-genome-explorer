// ViewStateDeclaredGaps.swift - The view-switch kinds that do not keep their view yet, each with its lane and reason
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ViewSwitchViewStateTests fails for a kind of ViewSwitchKinds.all with no driver and no row here, and it pins the
// count of rows as a ceiling (VS Q1). A family lane that adopts a kind removes its row and lowers the ceiling in its own
// commit. At the close only Status only, and Quick Look unless VS-PRIMER adopts it, stay, each with its reason (X1).

/// A kind whose view is not kept yet, the lane that adopts it and why.
struct ViewStateDeclaredGap: Sendable {
    let kind: String
    let lane: String
    let reason: String
}

enum ViewStateDeclaredGaps {
    /// The most rows the table may hold. Lower it in the commit that removes a row.
    static let ceiling = 10

    static let all: [ViewStateDeclaredGap] = [
        gap("TaxTriage", "VS-CLASS", "sample, filter, batch facet, selection, sort and split are not kept yet"),
        gap("NVD", "VS-CLASS", "grouping, sample filter, search, expansion, selection and split are not kept yet"),
        gap("MSA", "VS-ALN", "zoom, selection, colour scheme, search and bottom pane are not kept yet"),
        gap("Tree", "VS-ALN", "layout, zoom, pan, node, collapse, colour mode and columns are not kept yet"),
        gap("Primer analysis", "VS-PRIMER", "section, selection, template and pair are not kept yet"),
        gap("Primer order", "VS-PRIMER", "not read by any seat, VS-PRIMER reads it first"),
        gap("FASTA document", "VS-DATA", "the locus and zoom of a loose file are not kept yet"),
        gap("Quick Look", "VS-PRIMER", "its preview draws in another process, unless VS-PRIMER finds the app's own text view (VS U8)"),
        gap("Status only", "none", "a status line holds no view (VS U8)"),
        gap("PDF", "VS-PRIMER", "page and scale are not kept yet (VS U8)"),
    ]

    private static func gap(_ kind: String, _ lane: String, _ reason: String) -> ViewStateDeclaredGap {
        ViewStateDeclaredGap(kind: kind, lane: lane, reason: reason)
    }
}
