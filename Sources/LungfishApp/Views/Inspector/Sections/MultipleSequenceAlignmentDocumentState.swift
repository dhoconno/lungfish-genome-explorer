import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

struct MultipleSequenceAlignmentDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let contextRows: [(String, String)]
    let warningRows: [String]
    let artifactRows: [MultipleSequenceAlignmentDocumentArtifactRow]
    let consensusPreview: String

    var visibleSectionOrder: [MultipleSequenceAlignmentDocumentSectionKind] {
        [.header, .alignmentSummary, .warnings, .sourceArtifacts]
    }

    static func == (
        lhs: MultipleSequenceAlignmentDocumentState,
        rhs: MultipleSequenceAlignmentDocumentState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.summary == rhs.summary &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.warningRows == rhs.warningRows &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.consensusPreview == rhs.consensusPreview
    }
}
