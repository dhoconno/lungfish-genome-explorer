// AnnotationGFF3Export.swift - The GFF3 export of one source's annotations, shared by the app and its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The GFF3 export of one source's annotations (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R2).
///
/// A reference bundle in the sidebar exports through `bundle export-gff3 <bundle>`, which loads the annotations
/// from the bundle's databases. An open document exports through `bundle export-gff3 --selection <file>`, whose
/// selection holds the document's annotations, since they may hold edits not saved to disk.
public enum AnnotationGFF3Export {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, a sibling of `bundle export`).
    public static let commandPath = ["bundle", "export-gff3"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish bundle export-gff3"
    /// The GFF3 source column every exported feature carries.
    public static let featureSource = "Lungfish"
}

/// An open document's annotations in the selection file (ARCH ruling on 12.39 R2 item 2). The leaf names the
/// selection file only, since the document is not read.
public struct AnnotationExportDocumentSelection: Codable, Sendable, Equatable {
    /// The document's name, which the export's messages show.
    public var sourceName: String
    /// The document's file, nil for a document never saved.
    public var sourcePath: String?
    /// The annotations as the document held them at the click, in order.
    public var annotations: [SequenceAnnotation]

    public init(sourceName: String, sourcePath: String?, annotations: [SequenceAnnotation]) {
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.annotations = annotations
    }

    /// Equal when both write the same selection bytes, since `SequenceAnnotation` is not `Equatable`.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceName == rhs.sourceName && lhs.sourcePath == rhs.sourcePath
            && canonicalBytes(lhs.annotations) == canonicalBytes(rhs.annotations)
    }

    private static func canonicalBytes(_ annotations: [SequenceAnnotation]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(annotations)
    }
}
