import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

public struct GenotypeAIHaplotypingUIRequest: Equatable, Sendable {
    public let mode: GenotypeAIHaplotypingUIMode

    public init(mode: GenotypeAIHaplotypingUIMode) {
        self.mode = mode
    }
}
