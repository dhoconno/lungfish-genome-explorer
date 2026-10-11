// AnalysisRunExecutor+Folder.swift - The result folder of an analysis run, made or claimed in phase P1 and settled in P6
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The result folder of one run and who completes its run record.
struct AnalysisRunFolder: Sendable {
    let root: URL
    /// The project the folder belongs to, when it belongs to one.
    let projectURL: URL?
    /// `owned` when this run made or claimed the folder and settles its run record,
    /// `heldByLiveProducer` when another live process, such as the app, holds the record, and nil
    /// for a folder outside a project or one with other content, which carries no record.
    let claim: AnalysisRunRecord.RunClaim?

    /// Phase P1. Makes or claims the folder, with `analysis-metadata.json` and a run record that
    /// names the command (E1), through the helpers every analysis folder already uses.
    ///
    /// - A project gets a new `Analyses/<tool>[-batch]-<timestamp>/` from
    ///   `AnalysesFolder.createAnalysisDirectory`, which appears under its name with its run record
    ///   and metadata already inside.
    /// - A named folder is claimed with `AnalysesFolder.beginRunInOutputDirectory`, which writes
    ///   the run record only for a folder inside a project that is empty, missing or already a run
    ///   folder. A missing folder is created. The metadata is written into a folder this run
    ///   claimed, a folder another producer holds and a folder outside every project, and an
    ///   existing file that already names this tool and layout is kept.
    static func prepare(
        destination: AnalysisRunDestination,
        toolID: AnalysisToolID,
        layout: AnalysisRunLayout,
        command: String,
        startedAt: Date
    ) throws -> AnalysisRunFolder {
        let isBatch = layout == .batchRoot
        switch destination {
        case .project(let projectURL):
            let root = try AnalysesFolder.createAnalysisDirectory(
                tool: toolID.rawValue,
                in: projectURL,
                isBatch: isBatch,
                date: startedAt,
                command: command
            )
            return AnalysisRunFolder(root: root, projectURL: projectURL.standardizedFileURL, claim: .owned)

        case .directory(let requested):
            let directory = requested.standardizedFileURL
            let projectURL = ProjectTempDirectory.findProjectRoot(directory)?.standardizedFileURL
            if let projectURL,
               directory == projectURL
                || directory == projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true).standardizedFileURL {
                throw AnalysisRunError.destinationIsProjectFolder(path: directory.path)
            }
            let claim = try AnalysesFolder.beginRunInOutputDirectory(
                directory,
                projectURL: projectURL,
                record: AnalysisRunRecord(
                    analysisName: AnalysesFolder.displayName(for: toolID.rawValue),
                    command: command,
                    startedAt: startedAt
                )
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if claim != nil || projectURL == nil {
                let existing = AnalysesFolder.readAnalysisMetadata(from: directory)
                if existing?.tool != toolID.rawValue || existing?.isBatch != isBatch {
                    try AnalysesFolder.writeAnalysisMetadata(
                        AnalysesFolder.AnalysisMetadata(tool: toolID.rawValue, isBatch: isBatch, created: startedAt),
                        to: directory
                    )
                }
            }
            return AnalysisRunFolder(root: directory, projectURL: projectURL, claim: claim)
        }
    }

    /// Phase P6. A completed run, with or without warnings, completes its run record so the
    /// folder is listed. A failed run keeps the folder, its records and its run record, and notes
    /// the outcome, so the folder stays hidden and is listed for review (E5). A record another
    /// live producer holds is left to that producer.
    func settle(_ ending: AnalysisRunEnding) {
        switch ending {
        case .completed:
            if let claim {
                AnalysisRunRecord.completeRun(claim, in: root)
            }
        case .failed:
            guard claim == .owned else { return }
            AnalysisRunRecord.recordOutcome(.failed, in: root)
        }
    }
}
