// SRAService+NCBIRunInfo.swift - NCBI's run info for one SRA run, looked up when a download needs it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRAService")

public extension SRAService {
    /// NCBI's run info for one run accession, or nil when NCBI does not
    /// answer with it.
    ///
    /// A download asks for it when ENA's record of the run is missing, so
    /// NCBI's LibraryLayout decides the lone-mate rule (`SRARunReads`) on the
    /// window and on `lungfish-cli fetch sra download` alike, and the window
    /// keeps NCBI's metadata for a run its last search did not cover. A
    /// failure is logged and never thrown, because the record only adds
    /// metadata and the listed layout. A cancelled lookup answers nil too,
    /// without a log line, so a caller checks its task afterwards, as
    /// `SRARunListedLayout.resolve(enaLayout:ncbiLayout:)` and the window's
    /// staging do, and stops on a cancellation.
    func ncbiRunInfo(forRun accession: String) async -> SRARunInfo? {
        do {
            let runs = try await ncbiService.sraEFetchRunInfo(ids: [accession])
            return runs.first { $0.accession == accession }
        } catch {
            if !isArchiveRequestCancellation(error) {
                let failure = ArchiveRequestFailure(archive: "NCBI", error: error)
                logger.warning("NCBI run info for \(accession, privacy: .public) is missing: \(failure.message, privacy: .public)")
            }
            return nil
        }
    }
}
