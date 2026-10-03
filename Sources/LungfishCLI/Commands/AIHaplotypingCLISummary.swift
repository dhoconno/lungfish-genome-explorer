import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AIHaplotypingCLISummary: Codable, Equatable {
    let bundle: String
    let mode: String
    let provider: String
    let model: String
    let revisionID: String
    let analysisPath: String
    let reviewState: String
    let callCount: Int
    let discoveredDefinitionCount: Int
    let provenancePath: String
}
