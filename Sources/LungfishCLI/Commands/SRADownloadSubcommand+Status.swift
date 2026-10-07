// SRADownloadSubcommand+Status.swift - Where fetch sra download prints its status and warning lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension SRADownloadSubcommand {
    /// Prints a status, progress or warning line. With `--format json` it
    /// goes to standard error, so standard output holds the JSON result alone
    /// (review B-N6). In text the line goes to standard output, as before.
    static func printStatus(_ line: String, toStandardError: Bool) {
        if toStandardError {
            printStatusLine(line)
        } else {
            print(line)
        }
    }
}
