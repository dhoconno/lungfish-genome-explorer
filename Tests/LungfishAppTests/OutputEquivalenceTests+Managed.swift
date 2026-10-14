// OutputEquivalenceTests+Managed.swift - The masks a managed plan gets (docs/contracts/CLI-EQUIVALENCE.md, row "Masks")
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 review, Fix 3 a (ARCH Q3, BIO co-review). A managed storage root holds the clock of
// the run that wrote it: the receipt's `installedAt` and `updatedAt`, the pack status cache's `timestamp`
// and `mtime=` values, the provenance envelopes of the run and the UTC stamp that starts a record's file
// name. Two runs of one command differ on those values and nothing else, so `.managedPlan` masks exactly
// them, by key, and compares a date anywhere else as written. OutputEquivalenceTests.swift is over the
// 800 line limit and may not grow, so these cases extend its class from a file of their own.

import Foundation
import XCTest
import LungfishTestSupport

extension OutputEquivalenceTests {
    /// The files of a managed storage root as one run writes them. The first group of fields holds what
    /// two runs of one command differ on. The second group holds what a route must keep.
    private struct ManagedTree {
        var clock: String
        var epoch: Double
        var mtime: String
        var runID: UUID
        var executable: String
        var stamp: String

        var databaseVersion = "2026-01-01"
        var fileSize = 10
        var recordLabel = "multiple-sequence-alignment-reinstall"
        var otherFile = #"{"installedAt":"2026-10-01T09:00:00Z"}"#

        func write(to root: URL) throws {
            let storage = root.appendingPathComponent("storage", isDirectory: true)
            func put(_ text: String, _ relative: String) throws {
                let url = storage.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            let environment = #""samtools":{"installedAt":"\#(clock)","packID":"lungfish-tools","packageSpec":"bioconda::samtools=1.24=h36b3a25_1","state":"installed"}"#
            let database = #""kraken2-viral":{"installedAt":"\#(clock)","path":"/db/viral","version":"\#(databaseVersion)"}"#
            try put(
                #"{"bootstrap":{"micromambaVersion":"2.9.0"},"databases":{\#(database)},"dependencySet":"2026.2","environments":{\#(environment)},"#
                    + #""pipelines":{},"schemaVersion":1,"synthesized":false,"updatedAt":"\#(clock)"}"#,
                "dependency-receipt.json"
            )
            let component = "/e/envs/mafft/bin/mafft|type=NSFileTypeRegular|size=\(fileSize)|perm=493|mtime=\(mtime)"
            try put(
                #"{"packStatuses":{"multiple-sequence-alignment":{"fingerprint":{"components":["\#(component)","/e/envs/gone|missing"]},"#
                    + #""status":{"state":"ready"},"timestamp":\#(epoch)}},"visibleStatuses":{"statuses":[],"timestamp":\#(epoch)}}"#,
                "conda/cache/plugin-pack-statuses.json"
            )
            try put(
                #"{"argv":["lungfish-cli","conda","install","--pack","multiple-sequence-alignment","--reinstall"],"createdAt":"\#(clock)","#
                    + #""exitStatus":0,"id":"\#(runID.uuidString)","runtimeIdentity":{"executablePath":"\#(executable)"},"status":"completed","#
                    + #""steps":[{"completedAt":"\#(clock)","exitStatus":0,"startedAt":"\#(clock)","toolName":"mafft"}],"workflowName":"conda-pack-install"}"#,
                "provenance/packs/\(stamp)-\(recordLabel).lungfish-provenance.json"
            )
            try put(otherFile, "plan.json")
        }
    }

    /// Two runs of one command differ on the clock of the receipt, the clock of the pack status cache, the
    /// clock and ids of a provenance envelope, the executable it names and the stamp in its file name, and
    /// those are the only values the masks hide. The cases after it each change one more value, so a date
    /// anywhere else in a managed plan, such as a database release, and the same keys in another file are
    /// compared as written.
    func testManagedStateClockValuesAreMasked() throws {
        let scratch = try TestTempDirectory.make(prefix: "output-equivalence-managed")
        addTeardownBlock { TestTempDirectory.cleanup(scratch) }
        let a = scratch.appendingPathComponent("A", isDirectory: true)
        let b = scratch.appendingPathComponent("B", isDirectory: true)
        let first = ManagedTree(
            clock: "2026-10-14T12:00:00Z", epoch: 782_136_000, mtime: "1760443200.0", runID: UUID(),
            executable: "/Applications/Lungfish.app/Contents/MacOS/Lungfish", stamp: "2026-10-14T120000"
        )
        var second = first
        second.clock = "2026-10-14T12:00:07Z"
        second.epoch = 782_136_007
        second.mtime = "1760443207.0"
        second.runID = UUID()
        second.executable = "/Applications/Lungfish.app/Contents/Helpers/lungfish-cli"
        second.stamp = "2026-10-14T120007"
        try first.write(to: a)
        try second.write(to: b)

        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .managedPlan), [],
            "only the clock values, the run's ids, the executable and the record's stamp differ"
        )

        let cases: [(label: String, count: Int, edit: (inout ManagedTree) -> Void)] = [
            ("a database version that is a date", 1, { $0.databaseVersion = "2026-02-01" }),
            ("a size in the status fingerprint", 1, { $0.fileSize = 11 }),
            ("installedAt in a file that is not the receipt", 1, { $0.otherFile = #"{"installedAt":"2026-10-02T09:00:00Z"}"# }),
            ("a record with another name behind the stamp", 2, { $0.recordLabel = "multiple-sequence-alignment-install" }),
        ]
        for (label, count, edit) in cases {
            var changed = second
            edit(&changed)
            try FileManager.default.removeItem(at: b.appendingPathComponent("storage", isDirectory: true))
            try changed.write(to: b)
            let result = try OutputEquivalence.differences(a, b, kind: .managedPlan)
            XCTAssertEqual(result.count, count, "\(label): \(result)")
        }
    }
}
