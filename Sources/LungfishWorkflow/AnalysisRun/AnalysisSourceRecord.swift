// AnalysisSourceRecord.swift - Records an analysis run writes into its source bundles after the root record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A record of the run that the executor writes into a source bundle in phase P5, after the root
/// record and only for a completed run, such as an `analyses-manifest.json` entry. Both the
/// command line and the app's route write the same text through it.
public protocol AnalysisSourceRecord: Sendable {
    func write(_ context: AnalysisSourceRecordContext) throws
}

/// What a source record needs to know about the run.
public struct AnalysisSourceRecordContext: Sendable, Equatable {
    public let toolID: AnalysisToolID
    /// The run's result folder.
    public let analysisDirectory: URL
    /// The project the result folder belongs to, when it belongs to one.
    public let projectURL: URL?

    public init(toolID: AnalysisToolID, analysisDirectory: URL, projectURL: URL?) {
        self.toolID = toolID
        self.analysisDirectory = analysisDirectory
        self.projectURL = projectURL
    }

    /// The result folder as a manifest entry names it, relative to the project's `Analyses/`
    /// folder when it sits there, else its own name, as the app writes it.
    public var analysisDirectoryName: String {
        if let projectURL,
           let relativePath = AnalysisManifestStore.analysisDirectoryPath(
               for: analysisDirectory,
               projectURL: projectURL
           ) {
            return relativePath
        }
        return analysisDirectory.lastPathComponent
    }
}

/// An entry of a source bundle's analysis history, `analyses-manifest.json`.
public struct AnalysisManifestSourceRecord: AnalysisSourceRecord, Equatable {
    /// The bundle the run read.
    public let bundleURL: URL
    public let displayName: String
    public let parameters: [String: AnalysisParameterValue]
    public let summary: String

    public init(
        bundleURL: URL,
        displayName: String,
        parameters: [String: AnalysisParameterValue] = [:],
        summary: String
    ) {
        self.bundleURL = bundleURL
        self.displayName = displayName
        self.parameters = parameters
        self.summary = summary
    }

    public func write(_ context: AnalysisSourceRecordContext) throws {
        let entry = AnalysisManifestEntry(
            tool: context.toolID.rawValue,
            analysisDirectoryName: context.analysisDirectoryName,
            displayName: displayName,
            parameters: parameters,
            summary: summary,
            status: .completed
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
    }
}
