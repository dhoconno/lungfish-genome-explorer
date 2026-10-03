import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingFilterResult: Sendable, Codable, Equatable {
    public let inputBAMURL: URL
    public let outputBAMURL: URL
    public let outputBAIURL: URL
    public let totalAlignments: Int
    public let passedAlignments: Int
    public let genotypeCounts: [ONTGenotypingGenotypeCount]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let wallClockSeconds: TimeInterval

    public init(
        inputBAMURL: URL,
        outputBAMURL: URL,
        outputBAIURL: URL,
        totalAlignments: Int,
        passedAlignments: Int,
        genotypeCounts: [ONTGenotypingGenotypeCount],
        stdout: String,
        stderr: String,
        exitCode: Int32,
        wallClockSeconds: TimeInterval
    ) {
        self.inputBAMURL = inputBAMURL.standardizedFileURL
        self.outputBAMURL = outputBAMURL.standardizedFileURL
        self.outputBAIURL = outputBAIURL.standardizedFileURL
        self.totalAlignments = totalAlignments
        self.passedAlignments = passedAlignments
        self.genotypeCounts = genotypeCounts
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.wallClockSeconds = wallClockSeconds
    }
}
