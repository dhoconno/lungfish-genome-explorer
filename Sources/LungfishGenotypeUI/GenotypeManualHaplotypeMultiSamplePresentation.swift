import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct GenotypeManualHaplotypeMultiSamplePresentation: Equatable {
    static let maximumVisibleSamples = 12

    let visibleSamples: [String]
    let omittedSampleCount: Int

    init(samples: [String]) {
        visibleSamples = Array(
            samples.prefix(Self.maximumVisibleSamples)
        )
        omittedSampleCount = max(0, samples.count - visibleSamples.count)
    }

    var omissionSummary: String? {
        guard omittedSampleCount > 0 else { return nil }
        let noun = omittedSampleCount == 1 ? "sample" : "samples"
        return
            "\(omittedSampleCount) additional selected \(noun) "
            + (omittedSampleCount == 1 ? "is" : "are")
            + " not shown."
    }
}
