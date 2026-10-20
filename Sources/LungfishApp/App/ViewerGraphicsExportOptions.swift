// ViewerGraphicsExportOptions.swift - viewer graphics export choices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import UniformTypeIdentifiers

/// The Scope menu's choices. A bundle offers Tracks, Ruler and Tracks and Selected Region, a document Tracks, Full
/// Viewer Pane and Selected Region, and other content Full Viewer Pane (UX ruling Q-G2 items 2 and 3).
enum ViewerExportScope: String, CaseIterable {
    case tracks = "tracks"
    case rulerAndTracks = "ruler"
    case fullViewer = "full"
    case selectedRegion = "selection"

    var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .rulerAndTracks: return "Ruler and Tracks"
        case .fullViewer: return "Full Viewer Pane"
        case .selectedRegion: return "Selected Region"
        }
    }
}

enum ViewerGraphicFormat: String, CaseIterable {
    case png
    case jpeg
    case tiff
    case pdf

    var title: String { rawValue.uppercased() }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .pdf: return .pdf
        }
    }

    var fileExtension: String { rawValue }

    var isVector: Bool { self == .pdf }
}
