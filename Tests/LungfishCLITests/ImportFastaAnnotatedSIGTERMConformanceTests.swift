// ImportFastaAnnotatedSIGTERMConformanceTests.swift - A SIGTERM after the build, with --annotations, leaves no bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M3, ruling A48 F2 pin P6, its second case, and L5. A cancel that arrives
// after the service published the bundle but before the leaf's last write returns removes the
// bundle, so the run ends cancelled with exit 125 and Reference Sequences holds nothing.
//
// The leaf runs in this process, so the test holds it with a seam of the leaf's own path: it takes
// the manifest serializer's turn for the bundle first, and the leaf's attach then waits behind it.
// Once the service's record is in the published bundle, the test posts SIGTERM to its own process,
// which ignores SIGTERM while the leaf's handler is not installed, gives the handler a moment to
// cancel the leaf's task and releases its turn. The attach finds itself cancelled before it reads
// the BED. The build runs the real bgzip and samtools, so the class skips without the managed tools
// unless `LUNGFISH_REQUIRE_TOOLS=1`.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishTestSupport
@testable import LungfishWorkflow

final class ImportFastaAnnotatedSIGTERMConformanceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        if let missing = await NativeBundleBuilder().checkRequiredTools() {
            try ToolAvailability.skipOrFail("Native reference bundle tools are unavailable: \(missing.description)")
        }
        root = try TestTempDirectory.make(prefix: "import-fasta-annotated-sigterm").resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testACancelAfterTheServiceReturnedRemovesTheAnnotatedBundle() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("selection.fasta")
        try ">seqA first\nACGTACGTAC\n>seqB\nGGCCAATTGGCC\n".write(to: source, atomically: true, encoding: .utf8)
        let bed = root.appendingPathComponent("selected-annotations.bed")
        try "seqA\t1\t6\tgeneA\t0\t+\t1\t6\t0,0,0\t1\t5,\t0,\tgene\t\n".write(to: bed, atomically: true, encoding: .utf8)
        let bundle = project.appendingPathComponent("Reference Sequences/Annotated_Selection.lungfishref", isDirectory: true)

        // The serializer's turn for the bundle, which the leaf's attach waits behind.
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await BundleManifestMutationSerializer.shared.run(bundleURL: bundle) {
                enteredSignal.finish()
                for await _ in release { break }
            }
        }
        for await _ in entered {}

        // Ignore SIGTERM for the test and put back the disposition the runner had (A48 M3 review, Fix 12).
        let previousDisposition = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previousDisposition) }
        let arguments = [
            source.path, "--output-dir", project.path, "--name", "Annotated Selection", "--annotations", bed.path, "--quiet",
        ]
        let leaf = Task { () -> Int32? in
            do {
                try await ImportCommand.FASTASubcommand.parse(arguments).run()
                return 0
            } catch let exit as ExitCode {
                return exit.rawValue
            } catch {
                return nil
            }
        }

        let record = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let built = await Self.waitUntil { FileManager.default.fileExists(atPath: record.path) }
        XCTAssertTrue(built, "the service never published the bundle with its record")
        // The leaf has returned from the service and waits in the attach, behind the held turn.
        try await Task.sleep(for: .seconds(1))
        kill(getpid(), SIGTERM)
        try await Task.sleep(for: .seconds(1))
        releaser.finish()
        try await holder.value

        let status = await leaf.value
        XCTAssertEqual(status, 125, "a cancelled import exits 125")
        XCTAssertEqual(try ImportFastaSIGTERMTests.leftovers(in: project), [], "the cancel removed the published bundle")
    }

    /// Polls `condition` every 50 milliseconds for up to 30 seconds.
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
