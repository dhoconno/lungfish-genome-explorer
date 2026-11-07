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
        completionDetail
    }

    static func notice(for result: FASTQOperationExecutionResult) -> String? {
        nil
    }
}
