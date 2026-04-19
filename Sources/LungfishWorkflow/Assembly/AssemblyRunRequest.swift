// AssemblyRunRequest.swift - Shared assembly run request for app and CLI entry points
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Assembler-neutral request passed into the managed assembly pipeline.
public struct AssemblyRunRequest: Sendable, Codable, Equatable {
    public let tool: AssemblyTool
    public let readType: AssemblyReadType
    public let inputURLs: [URL]
    public let projectName: String
    public let outputDirectory: URL
    public let pairedEnd: Bool
    public let threads: Int
    public let memoryGB: Int?
    public let minContigLength: Int?
    public let selectedProfileID: String?
    public let extraArguments: [String]

    public init(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        inputURLs: [URL],
        projectName: String,
        outputDirectory: URL,
        pairedEnd: Bool = false,
        threads: Int,
        memoryGB: Int? = nil,
        minContigLength: Int? = nil,
        selectedProfileID: String? = nil,
        extraArguments: [String] = []
    ) {
        self.tool = tool
        self.readType = readType
        self.inputURLs = inputURLs
        self.projectName = projectName
        self.outputDirectory = outputDirectory
        self.pairedEnd = pairedEnd
        self.threads = threads
        self.memoryGB = memoryGB
        self.minContigLength = minContigLength
        self.selectedProfileID = selectedProfileID
        self.extraArguments = extraArguments
    }
}
