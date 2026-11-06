// Kraken2BlastPopoverDatabaseTests.swift - The Kraken 2 BLAST popover names core_nt
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit
@testable import LungfishTaxonomyUI

/// Phase 3.2 lane KRAKENCORE (ARCH-BLAST-SEAM section 6, BIO-BLAST-DATABASES item 2). The popover's consent line names the
/// database the Kraken 2 run searches, and that is `core_nt`, as for every other route. It named `nt`, which NCBI answered
/// with `core_nt`, so the line named a database that was not searched.
@MainActor
final class Kraken2BlastPopoverDatabaseTests: XCTestCase {
    func testKraken2PopoverNamesCoreNt() {
        let controller = TaxonomyViewController()
        let view = controller.makeBlastConfigView(taxonName: "Escherichia coli", readsClade: 40) { _ in }

        XCTAssertEqual(view.database, "core_nt")
        XCTAssertTrue(
            BlastConfigPopoverView.submissionCaption(database: view.database).contains("NCBI BLASTN core_nt,"),
            "the consent line names the database searched"
        )
    }
}
