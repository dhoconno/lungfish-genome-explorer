// FetchPathoplexusProgressTests.swift - The progress of a fetch pathoplexus record only moves forward
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishCLI

/// A record whose INSDC accession GenBank cannot serve starts a second builder for the Pathoplexus
/// FASTA, and that builder's first shares are lower than the last the GenBank builder reported
/// (Phase 2.10 lane A45 M2). The bar of a batch only moves forward, so the shares the run passes on
/// never fall back, and the messages keep their order.
final class FetchPathoplexusProgressTests: XCTestCase {
    private struct Reported: Sendable, Equatable {
        let share: Double
        let message: String
    }

    func testTheShareNeverFallsBackAndTheMessagesKeepTheirOrder() {
        let seen = OSAllocatedUnfairLock<[Reported]>(initialState: [])
        let progress = MonotonicProgress { share, message in
            seen.withLock { $0.append(Reported(share: share, message: message)) }
        }
        for (share, message) in [
            (0.0, "metadata"), (0.02, "resolving"), (0.0, "falling back"), (0.01, "checking tools"), (0.45, "indexing"), (1.0, "ready"),
        ] {
            progress.report(share, message)
        }
        XCTAssertEqual(
            seen.withLock { $0 },
            [
                Reported(share: 0, message: "metadata"), Reported(share: 0.02, message: "resolving"),
                Reported(share: 0.02, message: "falling back"), Reported(share: 0.02, message: "checking tools"),
                Reported(share: 0.45, message: "indexing"), Reported(share: 1, message: "ready"),
            ])
    }
}
