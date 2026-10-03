import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AIHaplotypingCLIDebugSummary: Codable, Equatable {
    let bundle: String
    let mode: String
    let provider: String
    let model: String
    let debugOutput: String
    let chunkStartIndex: Int
    let chunkEndIndex: Int
    let chunkCount: Int
    let chunkIDs: [String]
    let callCount: Int
    let discoveredDefinitionCount: Int
    let provenancePath: String
}
