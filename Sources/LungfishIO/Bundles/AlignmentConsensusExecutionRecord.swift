// AlignmentConsensusExecutionRecord.swift - A reproducible execution record for one request-scoped samtools stage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

/// A reproducible execution record for one request-scoped samtools stage.
public struct AlignmentConsensusExecutionRecord: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case view
        case index
        case consensus
        case depth
    }

    public let stage: Stage
    public let executablePath: String
    /// The provider deliberately avoids a fifth scientific subprocess solely to
    /// probe a version; Task 7 can replace this provenance hint with its tool
    /// registry's resolved version when publishing a durable output.
    public let executableVersion: String
    public let runtimeIdentity: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let inputs: [AlignmentConsensusFileDescriptor]
    public let outputs: [AlignmentConsensusFileDescriptor]
    public let readGroupFile: AlignmentConsensusReadGroupFile?
    public let resolvedDefaults: [String: String]
    public let exitStatus: Int32?
    public let startedAt: Date
    public let endedAt: Date
    public let wallTimeSeconds: TimeInterval
    public let stderr: String?

    public init(
        stage: Stage,
        executablePath: String,
        executableVersion: String,
        runtimeIdentity: String,
        argv: [String],
        reproducibleCommand: String,
        inputs: [AlignmentConsensusFileDescriptor],
        outputs: [AlignmentConsensusFileDescriptor],
        readGroupFile: AlignmentConsensusReadGroupFile?,
        resolvedDefaults: [String: String],
        exitStatus: Int32?,
        startedAt: Date,
        endedAt: Date,
        wallTimeSeconds: TimeInterval,
        stderr: String?
    ) {
        self.stage = stage
        self.executablePath = executablePath
        self.executableVersion = executableVersion
        self.runtimeIdentity = runtimeIdentity
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.inputs = inputs
        self.outputs = outputs
        self.readGroupFile = readGroupFile
        self.resolvedDefaults = resolvedDefaults
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}
