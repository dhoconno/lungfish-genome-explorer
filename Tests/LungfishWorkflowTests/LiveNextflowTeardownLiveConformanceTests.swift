// LiveNextflowTeardownLiveConformanceTests.swift - The live helper's teardown against the real Docker daemon
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9b, owner direction O5. LiveNextflowHelperTests checks the teardown against a daemon in
// memory. This class checks the one fact that class cannot, which is the form in which the real daemon
// reports the host side of a mount. It runs only when the live switch is on (LUNGFISH_LIVE_NEXTFLOW_ROOT, or
// LUNGFISH_REQUIRE_TOOLS=1 with LUNGFISH_STORAGE_ROOT) and Docker answers `docker info`. It never starts
// Docker Desktop, pulls nothing and starts no container. It creates four containers from an image that is
// already local, with the mounts a Nextflow task has, and removes the three it keeps by their exact names.

import Foundation
import LungfishTestSupport
import XCTest

final class LiveNextflowTeardownLiveConformanceTests: XCTestCase {
    func testTeardownRemovesTheContainersOfTheRunAndNoOthersOnTheRealDaemon() throws {
        let run = try LiveNextflowRun.begin()
        defer { XCTAssertEqual(run.teardown().problems, []) }
        let docker = run.docker
        let image = try localImage(docker)

        // A Nextflow task container mounts the system temporary folder, which holds every run's work
        // folder, and its own task folder, which lies inside the run's work folder.
        let temporary = run.directory.deletingLastPathComponent()
        let taskFolder = run.workDirectory.appendingPathComponent("06/2dcb09834cd2b4c58ce632d16d3eba", isDirectory: true)
        let otherRun = try TestTempDirectory.make(prefix: "live-foreign-\(run.key)")
        defer { TestTempDirectory.cleanup(otherRun) }
        let otherTaskFolder = otherRun.appendingPathComponent("work/06/2dcb09834cd2b4c58ce632d16d3eba", isDirectory: true)
        let siblingFolder = run.directory.appendingPathComponent("work-other/aa", isDirectory: true)

        let keptNames = ["\(run.key)-other-run", "\(run.key)-sibling", "\(run.key)-temporary-only"]
        defer { _ = try? docker.run(["rm", "-f", "-v", "\(run.key)-owned"] + keptNames) }

        let owned = try create("\(run.key)-owned", mounting: [temporary, taskFolder], image: image, docker: docker)
        let other = try create(keptNames[0], mounting: [temporary, otherTaskFolder], image: image, docker: docker)
        let sibling = try create(keptNames[1], mounting: [siblingFolder], image: image, docker: docker)
        let temporaryOnly = try create(keptNames[2], mounting: [temporary], image: image, docker: docker)

        let before = try run.ownedContainers()
        print("[live-nextflow] mount sources the daemon reports for the run's container: \(before.flatMap(\.mountSources))")
        XCTAssertEqual(before.map(\.id), [owned], "only the container with a mount inside the run's work folder is the run's")

        let report = run.teardown()

        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.removedContainerIDs, [owned])
        let present = Set(try docker.containers().map(\.id))
        XCTAssertFalse(present.contains(owned), "the run's container is gone")
        XCTAssertTrue(present.isSuperset(of: [other, sibling, temporaryOnly]), "no other container was touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directory.path), "the run's folder is gone")
    }

    // MARK: - Helpers

    /// An image that is already local. The test pulls nothing.
    private func localImage(_ docker: LiveNextflowDocker) throws -> String {
        let listing = try docker.run(["images", "--format", "{{.Repository}}:{{.Tag}}"])
        let image = listing.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.hasPrefix("<none>") && !$0.hasSuffix(":<none>") }
        guard let image else {
            try ToolAvailability.skipOrFail("Docker holds no local image to create the test containers from, and this test pulls nothing.")
        }
        return image
    }

    /// Creates a container, which starts nothing, and returns its full id.
    private func create(
        _ name: String,
        mounting folders: [URL],
        image: String,
        docker: LiveNextflowDocker
    ) throws -> String {
        var arguments = ["create", "--name", name]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            arguments += ["-v", "\(folder.path):\(folder.path)"]
        }
        arguments += [image, "true"]
        let output = try docker.run(arguments)
        XCTAssertEqual(output.status, 0, output.stderr)
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
