// AlignmentConsensusScope.swift - Explicit persistent consensus region selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The user-selected consensus scope.  This preference persists while the
/// active evidence changes; an unavailable selected region must be reported,
/// never silently widened to a contig.
enum AlignmentConsensusScope: String, CaseIterable, Sendable {
    case wholeContig
    case selectedRegion

    func resolve(
        in context: AlignmentActionContext,
        selection: AlignmentCoordinateSelection?
    ) throws -> ResolvedAlignmentRegion {
        switch self {
        case .wholeContig:
            return .init(scope: self, contig: context.contig, start: 0, end: context.contigLength)
        case .selectedRegion:
            guard let selection else {
                throw AlignmentConsensusScopeError.selectionRequired("Select a region in the viewer first")
            }
            guard selection.contig == context.contig else {
                throw AlignmentConsensusScopeError.crossContigSelection(
                    expected: context.contig,
                    actual: selection.contig
                )
            }
            let start = min(max(selection.start, 0), context.contigLength)
            let end = min(max(selection.end, 0), context.contigLength)
            guard start < end else {
                throw AlignmentConsensusScopeError.emptySelection(contig: selection.contig, start: start, end: end)
            }
            return .init(scope: self, contig: context.contig, start: start, end: end)
        }
    }
}

/// A coordinate range selected deliberately in the active viewer. Coordinates
/// are zero-based and half-open, as required by the alignment provider.
struct AlignmentCoordinateSelection: Sendable, Equatable {
    let contig: String
    let start: Int
    let end: Int

    init(contig: String, start: Int, end: Int) {
        self.contig = contig
        self.start = start
        self.end = end
    }
}

/// A fully resolved action range, retaining its source scope for provenance
/// and display while enforcing a single active contig.
struct ResolvedAlignmentRegion: Sendable, Equatable {
    let scope: AlignmentConsensusScope
    let contig: String
    let start: Int
    let end: Int

    init(scope: AlignmentConsensusScope, contig: String, start: Int, end: Int) {
        self.scope = scope
        self.contig = contig
        self.start = start
        self.end = end
    }
}

enum AlignmentConsensusScopeError: Error, Sendable, Equatable, LocalizedError {
    case selectionRequired(String)
    case crossContigSelection(expected: String, actual: String)
    case emptySelection(contig: String, start: Int, end: Int)

    var errorDescription: String? {
        switch self {
        case .selectionRequired(let message): message
        case .crossContigSelection(let expected, let actual):
            "The selected region is on '\(actual)', not the active contig '\(expected)'."
        case .emptySelection:
            "Select a non-empty region in the viewer first"
        }
    }
}
