// ClassifierReadResolver+StrandFix.swift - Refuses a NAO-MGS BAM made before the strand fix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ClassifierReadResolver {

    /// Resolves the per-sample BAM URL for a classifier tool, and for NAO-MGS refuses a BAM made before the strand fix
    /// (Phase 3.1 lane NAO-BAM-STALE, ruling UX-NAO-BAM-STALE 4a and 5). The estimate, the run and both CLI commands
    /// resolve their BAM here, so the Extract sheet, the Extract alert and the CLI refuse alike. The check reads one
    /// header with the samtools the extraction uses and changes no file. A header that cannot be read throws
    /// `samtoolsFailed`, never the stale words, since the orientation is then unknown and not known to be wrong.
    /// The layout lookup is ``locateBAMURL(tool:sampleId:resultPath:)``.
    func resolveBAMURL(tool: ClassifierTool, sampleId: String?, resultPath: URL) async throws -> URL {
        let bamURL = try await locateBAMURL(tool: tool, sampleId: sampleId, resultPath: resultPath)
        guard tool == .naomgs else { return bamURL }
        let sample = sampleId ?? "(single)"
        let header = try await toolRunner.run(.samtools, arguments: ["view", "-H", bamURL.path], timeout: 60)
        guard header.isSuccess else {
            throw ClassifierExtractionError.samtoolsFailed(sampleId: sample, stderr: header.stderr)
        }
        if NaoMgsBamMaterializer.orientation(ofHeader: header.stdout) == .beforeStrandFix {
            throw ClassifierExtractionError.naoMgsBAMBeforeStrandFix(sampleId: sample)
        }
        return bamURL
    }
}
