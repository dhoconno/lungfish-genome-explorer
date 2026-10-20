// NaoMgsBamMaterializationStep.swift - The result and the steps of a NAO-MGS BAM materialization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct NaoMgsBamMaterializationResult: Sendable {
    public let bamURLs: [URL]
    public let steps: [NaoMgsBamMaterializationStep]

    public init(bamURLs: [URL], steps: [NaoMgsBamMaterializationStep]) {
        self.bamURLs = bamURLs
        self.steps = steps
    }
}

public struct NaoMgsBamMaterializationStep: Sendable {
    /// Fixed when the step ran, so every conversion of it keeps one step id.
    public let id = UUID()
    public let sample: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let inputURLs: [URL]
    public let outputURLs: [URL]
    public let exitStatus: Int?
    public let wallTimeSeconds: TimeInterval?
    public let stderr: String?
    public let startedAt: Date?
    public let completedAt: Date?
    /// The step this one ran inside, as each samtools stage of a markdup runs inside the markdup call.
    public let parentStepID: UUID?
    /// `pipe:stdout:<stage>` of the stage whose stdout this one reads, and of this stage's own stdout.
    public let stdinPipe: String?
    public let stdoutPipe: String?

    public init(
        sample: String,
        toolName: String,
        toolVersion: String = "unknown",
        argv: [String],
        reproducibleCommand: String? = nil,
        inputURLs: [URL] = [],
        outputURLs: [URL] = [],
        exitStatus: Int? = nil,
        wallTimeSeconds: TimeInterval? = nil,
        stderr: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        parentStepID: UUID? = nil,
        stdinPipe: String? = nil,
        stdoutPipe: String? = nil
    ) {
        self.sample = sample
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(naoMgsShellEscape).joined(separator: " ")
        self.inputURLs = inputURLs
        self.outputURLs = outputURLs
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.parentStepID = parentStepID
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
    }
}
