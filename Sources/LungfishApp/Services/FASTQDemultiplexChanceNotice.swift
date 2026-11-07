// FASTQDemultiplexChanceNotice.swift - What a finished demultiplex row says about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The words the Operations row of a finished demultiplex run adds about chance matches, worked out from the run's
/// request and the manifest it wrote (DEMUX-EXACT-BARE-NO-FLOOR, ruling UX-EXACT-BARE-WORDS).
///
/// `lungfish-cli fastq demultiplex` has no event channel, so no line of its summary reaches the window. The notice is
/// built here from the result. It reads files, so a caller runs it off the main actor.
enum FASTQDemultiplexChanceNotice {
    /// The line under the row's name starts with the cause, so a cut-off line still says it.
    static let rowPrefix = "Not checked for chance matches. "

    static func rowDetail(_ completionDetail: String) -> String {
        rowPrefix + completionDetail
    }

    /// The words of Exact Bare Barcode when the run made a sample file, or nil. A run whose manifest cannot be read
    /// may have made sample files, so it gets the words (the safe side).
    static func notice(for result: FASTQOperationExecutionResult) -> String? {
        guard case .derivative(.demultiplex(_, _, _, _, _, _, _, let engine, _, _, _), _, _) = result.resolvedRequest,
              engine == .exactBareBarcode else { return nil }
        let manifests = (result.importedURLs + [result.groupedContainerURL].compactMap { $0 })
            .compactMap { DemultiplexManifest.load(from: $0) }
        let madeASampleFile = manifests.contains { $0.barcodes.contains { $0.readCount > 0 } }
        return manifests.isEmpty || madeASampleFile ? DemultiplexEngine.exactBareChanceWords : nil
    }
}
