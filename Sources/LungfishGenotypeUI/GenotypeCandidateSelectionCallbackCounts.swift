import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct GenotypeCandidateSelectionCallbackCounts: Equatable {
    let known: Int
    let candidate: Int
}
