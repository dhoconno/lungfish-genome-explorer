// MappingProvenance+Reading.swift - A saved mapping record as a reader sees it, without the reading Mac's facts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension MappingProvenance {
    /// The envelope a reader makes of a saved `mapping-provenance.json`.
    ///
    /// `canonicalEnvelope(sourceDirectory:)` is the form a writer records, so it takes the app
    /// version, operating system, process ID, architecture and dependency set of the process that
    /// runs it. A mapping record holds none of those, nor a workflow version or an account. Read
    /// from disk, the record keeps only the mapper's executable and conda environment it names, and
    /// the facts it never held stay empty instead of taking the reading Mac's. The embedded run
    /// needs text, so its app version and operating system are the empty string.
    func recordedEnvelope(sourceDirectory: URL) -> ProvenanceEnvelope {
        let written = canonicalEnvelope(sourceDirectory: sourceDirectory)
        return written.readingWithoutHostFacts(
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: nil,
                executablePath: written.runtimeIdentity.executablePath,
                processIdentifier: nil,
                operatingSystemVersion: nil,
                architecture: nil,
                user: nil,
                condaEnvironment: written.runtimeIdentity.condaEnvironment,
                dependencySet: nil
            )
        )
    }
}
