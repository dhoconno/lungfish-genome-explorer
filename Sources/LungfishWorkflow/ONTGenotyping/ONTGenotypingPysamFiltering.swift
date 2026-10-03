import Foundation
import LungfishCore
import LungfishIO

public protocol ONTGenotypingPysamFiltering: Sendable {
    func filter(_ request: ONTGenotypingFilterRequest) async throws -> ONTGenotypingFilterResult
}
