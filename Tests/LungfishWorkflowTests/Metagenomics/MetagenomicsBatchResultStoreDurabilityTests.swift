// MetagenomicsBatchResultStoreDurabilityTests.swift - Batch sidecars reach disk whole or not at all
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.10 lane S31, M2. `MetagenomicsBatchResultStore.writeJSON` wrote
/// with `Data.write(.atomic)`, which renames a temporary file into place
/// without a sync, so a crash could leave a sidecar that was empty or old
/// after the run that wrote it had finished. The Kraken2 and EsViritu
/// finalize steps call it (`Kraken2AnalysisRunTool+Finalize.swift:128`,
/// `EsVirituAnalysisRunTool+Finalize.swift:69`), and so do the TaxTriage
/// result views. It now publishes through `DurableReplace`, with the same
/// bytes.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback.
final class MetagenomicsBatchResultStoreDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "batch-result-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func reference(sample: String = "S1") -> TaxTriageCrossRef {
        TaxTriageCrossRef(
            resultDirectory: "/tmp/out",
            runId: "taxtriage-20261013-120000",
            sampleId: sample,
            createdAt: Date(timeIntervalSince1970: 0),
            batchSampleCount: 3
        )
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private var sidecarName: String { MetagenomicsBatchResultStore.taxTriageRefFilename(runId: "taxtriage-20261013-120000") }

    // MARK: - Byte pin

    func testASidecarIsSortedPrettyPrintedJSONWithAnISODateAndEscapedSlashes() throws {
        try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(), to: root)

        let expected = """
            {
              "batchSampleCount" : 3,
              "createdAt" : "1970-01-01T00:00:00Z",
              "resultDirectory" : "\\/tmp\\/out",
              "runId" : "taxtriage-20261013-120000",
              "sampleId" : "S1"
            }
            """
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(sidecarName), encoding: .utf8), expected)
        XCTAssertEqual(MetagenomicsBatchResultStore.loadTaxTriageRefs(from: root), [reference()])
        XCTAssertEqual(try entries(), [sidecarName])
    }

    func testSavingAgainReplacesTheEarlierSidecarWithoutALeftoverEvenOnSimulatedExFAT() throws {
        try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "first"), to: root)

        try PortableRename.simulatingUnsupportedFlags {
            try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "second"), to: root)
        }

        XCTAssertEqual(MetagenomicsBatchResultStore.loadTaxTriageRefs(from: root), [reference(sample: "second")])
        XCTAssertEqual(try entries(), [sidecarName])
    }

    // MARK: - Faults

    func testASidecarIsSyncedBeforeItIsNamed() throws {
        let tally = ReadWriterFixtures.Tally()
        let operations = DurableReplace.Operations(
            syncFile: { tally.add("syncFile"); return Darwin.fsync($0) },
            checkpoint: { tally.add($0.rawValue) }
        )

        try DurableReplace.$overrideOperations.withValue(operations) {
            try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(), to: root)
        }

        XCTAssertEqual(tally["syncFile"], 1)
        XCTAssertEqual(tally["stageSynced"], 1)
        XCTAssertEqual(tally["published"], 1)
        XCTAssertEqual(tally["flushed"], 1, "one full flush for the volume")
    }

    func testAFullDiskIsAThrownErrorAndTheNameKeepsItsOldSidecar() throws {
        try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "old"), to: root)
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if ReadWriterFixtures.path(of: descriptor).contains(DurableReplace.stageInfix) {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(descriptor, bytes, count)
        })

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "new"), to: root)
            }
        ) { error in
            guard case .systemFailure(_, let operation, let code)? = error as? DurableReplace.ReplaceError else {
                return XCTFail("expected a system failure, got \(error)")
            }
            XCTAssertEqual(operation, "write the stage file")
            XCTAssertEqual(code, ENOSPC)
        }

        XCTAssertEqual(MetagenomicsBatchResultStore.loadTaxTriageRefs(from: root), [reference(sample: "old")])
        XCTAssertEqual(try entries(), [sidecarName], "no stage file is left")
    }

    func testAFaultAtAnyStepBeforeTheNameChangesKeepsTheOldSidecar() throws {
        try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "old"), to: root)

        for step in [DurableReplace.Step.staged, .stageSynced] {
            let operations = DurableReplace.Operations(checkpoint: { reached in
                if reached == step { throw ReadWriterFixtures.Refusal() }
            })

            XCTAssertThrowsError(
                try DurableReplace.$overrideOperations.withValue(operations) {
                    try MetagenomicsBatchResultStore.saveTaxTriageRef(reference(sample: "new"), to: root)
                },
                "\(step)"
            ) { XCTAssertTrue($0 is ReadWriterFixtures.Refusal, "\(step): \($0)") }
            XCTAssertEqual(MetagenomicsBatchResultStore.loadTaxTriageRefs(from: root), [reference(sample: "old")], "\(step)")
            XCTAssertEqual(try entries(), [sidecarName], "\(step)")
        }
    }
}
