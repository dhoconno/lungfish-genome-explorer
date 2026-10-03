import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AIHaplotypingCLIDebugOutput: Codable, Equatable {
    let summary: AIHaplotypingCLIDebugSummary
    let runnerOutput: AIHaplotypingRunnerOutput
}
