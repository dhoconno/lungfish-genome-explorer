import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

enum MultipleSequenceAlignmentDocumentSectionKind: Equatable {
    case header
    case alignmentSummary
    case warnings
    case sourceArtifacts
}
