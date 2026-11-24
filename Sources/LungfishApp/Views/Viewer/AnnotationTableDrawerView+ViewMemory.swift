// AnnotationTableDrawerView+ViewMemory.swift - The reference viewer's drawer keeps its tab and its row (VS-MAP-2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane VS-MAP-2 item 1 (VS B4, VS-MAP BIO R1). The drawer's tab is presentation and restores on any data key. Its one
// selected row restores by `trackId`, row id, name, chromosome, start and end, never by index, and only after the
// drawer's rows load; a row that no longer matches is dropped. Both ride in the viewer's record
// (`ReferenceViewerMemory.drawer`), so the item keeps one record with one writer (VS-REF Finding 5).

import AppKit
import LungfishWorkflow

/// A drawer row by its identity (VS B4, `AnnotationSearchResult.swift:9-45`).
struct ReferenceDrawerRow: Codable, Sendable, Equatable {
    var trackId: String
    var rowId: Int64?
    var name: String
    var chromosome: String
    var start: Int
    var end: Int

    init(_ result: AnnotationSearchResult) {
        trackId = result.trackId
        rowId = result.annotationRowId ?? result.variantRowId
        name = result.name
        chromosome = result.chromosome
        start = result.start
        end = result.end
    }
}

/// The drawer's kept view: its tab and its one selected row.
struct ReferenceDrawerMemory: Codable, Sendable, Equatable {
    var tab: Int
    var row: ReferenceDrawerRow?
}

extension AnnotationTableDrawerView {
    /// The tab and the one selected row as they stand (VS-MAP-2 item 1). Nil in this seam.
    var keptViewMemory: ReferenceDrawerMemory? { nil }
}
