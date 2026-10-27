// QualityBinningSchemeMapTests.swift - The quantize argument each binning scheme passes to BBTools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishPortable
@testable import LungfishWorkflow

/// Phase 3.0 lane BIN (BIO-BIN, S1). `illumina4` stores called Q0 to Q10 as Q8 and Q18 and Q19 as Q22, so the
/// default import scheme becomes `fiveStep`, which keeps every threshold of five. Old records name `illumina4`, so its
/// argument stays byte for byte what it was and a replay bins the same. The map itself, run through the real
/// `reformat.sh`, is `QualityBinningSchemeMapConformanceTests`.
final class QualityBinningSchemeMapTests: XCTestCase {
    func testIllumina4ArgumentUnchanged() {
        XCTAssertEqual(PortableStoragePlan.quantizeArgument(for: .illumina4), "quantize=0,8,13,22,27,32,37")
        XCTAssertEqual(QualityBinningScheme(rawValue: "illumina4"), .illumina4, "an old record still decodes")
    }

    func testFiveStepArgumentAndName() throws {
        let scheme = try XCTUnwrap(QualityBinningScheme(rawValue: "fiveStep"), "the fiveStep scheme exists")
        XCTAssertEqual(PortableStoragePlan.quantizeArgument(for: scheme), "quantize=0,2,7,12,17,22,27,32,37")
        XCTAssertEqual(scheme.displayName, "Q5 steps (8-level)")
    }
}
