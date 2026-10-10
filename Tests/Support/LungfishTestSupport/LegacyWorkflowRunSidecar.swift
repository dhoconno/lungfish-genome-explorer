// LegacyWorkflowRunSidecar.swift - Writes the bare WorkflowRun shape that earlier LGE versions produced
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Production code writes a provenance envelope through ProvenanceWriter. This writer lives in the test
// support so that a test can fabricate an old file and production code cannot.

import Foundation
import LungfishCore
import LungfishWorkflow

// MARK: - Sidecar writing

extension WorkflowRun {
    /// Writes this run as a pretty, sorted JSON sidecar at `url`. Inside a
    /// project or bundle the account's home, the managed tool root and
    /// scratch directories are rewritten (see `PortablePath`);
    /// `ProvenanceEnvelopeReader` resolves them again on load.
    public func writeSidecar(to url: URL, workspaceURLs: [URL] = []) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = PortablePath.sanitizeJSON(
            try encoder.encode(self),
            forFileAt: url,
            workspaceURLs: workspaceURLs,
            encoder: encoder
        )
        try data.write(to: url, options: .atomic)
    }
}
