// ViewerGraphicsExportOptions.swift - viewer graphics export choices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import UniformTypeIdentifiers

enum ViewerExportScope: String, CaseIterable {
    case tracks = "tracks"
    case fullViewer = "full"
    case selectedRegion = "selection"

    var title: String {
        switch self {
        case .tracks: return "Tracks View (Sequence + Variants + Annotations)"
        case .fullViewer: return "Full Viewer Pane (Ruler + Tracks + Table)"
        case .selectedRegion: return "Selected Region Only"
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
