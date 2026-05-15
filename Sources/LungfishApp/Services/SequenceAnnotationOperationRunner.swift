// SequenceAnnotationOperationRunner.swift - CLI-backed sequence annotation operations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

enum SequenceAnnotationOperationKind: Sendable, Equatable {
    case orf

    var cliSubcommand: String {
        switch self {
        case .orf: return "annotate-orfs"
        }
    }

    var displayName: String {
        switch self {
        case .orf: return "Find ORFs"
        }
    }
}

struct SequenceAnnotationOperationRequest: Sendable, Equatable {
    let operation: SequenceAnnotationOperationKind
    let bundleURL: URL
    let sequenceName: String
    let start: Int
    let end: Int
    let frames: [String]
    let codonTableID: Int
    let trackID: String?
    let trackName: String
    let minimumORFLength: Int?
    let includePartialORFs: Bool
    let allowAlternativeStarts: Bool

    init(
        operation: SequenceAnnotationOperationKind,
        bundleURL: URL,
        sequenceName: String,
        start: Int,
        end: Int,
        frames: [String],
        codonTableID: Int,
        trackID: String? = nil,
        trackName: String,
        minimumORFLength: Int? = nil,
        includePartialORFs: Bool = false,
        allowAlternativeStarts: Bool = false
    ) {
        self.operation = operation
        self.bundleURL = bundleURL
        self.sequenceName = sequenceName
        self.start = start
        self.end = end
        self.frames = frames
        self.codonTableID = codonTableID
        self.trackID = trackID
        self.trackName = trackName
        self.minimumORFLength = minimumORFLength
        self.includePartialORFs = includePartialORFs
        self.allowAlternativeStarts = allowAlternativeStarts
    }
}

enum SequenceAnnotationOperationRunner {
    static func commandArguments(for request: SequenceAnnotationOperationRequest) -> [String] {
        var arguments = [
            "sequence",
            request.operation.cliSubcommand,
            request.bundleURL.path,
            "--sequence", request.sequenceName,
            "--start", String(request.start),
            "--end", String(request.end),
            "--frames", request.frames.joined(separator: ","),
            "--table", String(request.codonTableID),
        ]

        if let trackID = request.trackID, !trackID.isEmpty {
            arguments += ["--track-id", trackID]
        }
        arguments += ["--track-name", request.trackName]

        if request.operation == .orf {
            if let minimumORFLength = request.minimumORFLength {
                arguments += ["--min-length", String(minimumORFLength)]
            }
            if request.includePartialORFs {
                arguments.append("--include-partial")
            }
            if request.allowAlternativeStarts {
                arguments.append("--allow-alternative-starts")
            }
        }

        arguments.append("--quiet")
        return arguments
    }

    static func displayCommand(for request: SequenceAnnotationOperationRequest) -> String {
        (["lungfish-cli"] + commandArguments(for: request))
            .map(shellEscape)
            .joined(separator: " ")
    }

    static func run(_ request: SequenceAnnotationOperationRequest) throws -> LungfishCLIRunner.Output {
        try LungfishCLIRunner.run(arguments: commandArguments(for: request))
    }
}
