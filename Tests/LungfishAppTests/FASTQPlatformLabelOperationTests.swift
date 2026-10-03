// FASTQPlatformLabelOperationTests.swift - begin() site of the Inspector's platform and read-type changes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Inspector's Read Type popup and the suspect-label notice used to write
// FASTQ sidecars directly, with no command and no provenance (a CLI parity
// gap). They now run `lungfish-cli fastq platform`. A held lock must refuse
// the row and launch nothing, and the recorded command must parse through the
// real CLI with the run's values.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQPlatformLabelOperationTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/lane b1/barcode10.lungfishfastq", isDirectory: true)
    private let second = URL(fileURLWithPath: "/tmp/lane b1/barcode11.lungfishfastq", isDirectory: true)

    func testARefusedRowLaunchesNothing() throws {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Primer-trimming", detail: "Running", operationType: .bamPrimerTrim,
            targetBundleURL: first, cliCommand: "lungfish-cli bam primer-trim"
        ).startedID)
        var launched = false
        let result = FASTQPlatformLabelOperation.beginPlatformLabelOperation(
            title: "Record platform",
            bundleURLs: [first],
            cliArguments: FASTQPlatformLabelOperation.cliArguments(bundleURLs: [first], change: .setPlatform(.oxfordNanopore)),
            reporter: center
        ) { _ in launched = true }
        guard case .refused = result else { return XCTFail("a held lock must refuse the row") }
        XCTAssertFalse(launched)
    }

    func testTheReadTypeChangeRecordsItsLocksAndAParsableCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?
        let arguments = FASTQPlatformLabelOperation.cliArguments(bundleURLs: [first, second], change: .setReadType(.ontReads))
        FASTQPlatformLabelOperation.beginPlatformLabelOperation(
            title: "Record read type", bundleURLs: [first, second], cliArguments: arguments, reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.operationType, .fastqOperation)
        XCTAssertEqual(item.targetBundleURL, first)
        XCTAssertEqual(item.additionalLockedBundleURLs, [second])
        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqPlatformSubcommand.self)
        XCTAssertEqual(command.inputs, [first.path, second.path])
        XCTAssertEqual(command.readType, "ont-reads")
        XCTAssertNil(command.setPlatform)
    }

    func testEveryChangeBuildsACommandTheCLIParses() throws {
        let changes: [(FASTQPlatformLabelOperation.Change, (FastqPlatformSubcommand) -> Bool)] = [
            (.setPlatform(.pacbio), { $0.setPlatform == "pacbio" }),
            (.setPlatform(.oxfordNanopore), { $0.setPlatform == "ont" }),
            (.setReadType(nil), { $0.readType == "auto" }),
            (.setReadType(.pacBioHiFi), { $0.readType == "pacbio-hifi" }),
            (.confirm, { $0.confirm }),
        ]
        for (change, check) in changes {
            let arguments = FASTQPlatformLabelOperation.cliArguments(bundleURLs: [first], change: change)
            let command = OperationCenter.buildCLICommand(subcommand: "fastq platform", args: Array(arguments.dropFirst(2)))
            let parsed = try RecordedCLICommand.parse(command, as: FastqPlatformSubcommand.self)
            XCTAssertTrue(check(parsed), "\(change)")
        }
    }

    func testTheNoticeNamesTheEvidenceAndBothChoices() throws {
        let root = try TestTempDirectory.make(prefix: "platform-notice")
        defer { TestTempDirectory.cleanup(root) }
        let fastq = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: root)
        let check = PlatformLabelCheck.check(
            fastqURL: fastq,
            metadata: PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads)
        )
        XCTAssertTrue(FASTQPlatformNotice.message(for: check).hasPrefix("Recorded as Illumina short reads."))
        XCTAssertTrue(FASTQPlatformNotice.message(for: check).contains("dorado SAM tags"))
        XCTAssertEqual(FASTQPlatformNotice.keepTitle(for: check), "Keep Illumina")
        XCTAssertEqual(check.suggestedPlatform, .oxfordNanopore)
    }
}
