// NextflowDockerContainerCleanupTests.swift - The container cleanup of a cancelled Nextflow run, on a stand-in docker
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S10, decision N5 and the SWIFT review's rule 6. Each case calls `NextflowDockerContainerCleanup`
// on `NextflowStandInDocker`, a `/bin/sh` script in place of `docker`, or reads its pure parts, so it needs no
// Docker. TaxTriageContainerCleanupTests runs the same cleanup through a cancelled TaxTriage run, and
// NextflowContainerCleanupLiveConformanceTests through a real one.

import Darwin
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class NextflowDockerContainerCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-container-cleanup")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private static let listing = ["ps", "--all", "--quiet", "--no-trunc"]
    private static let inspection = ["inspect", "--type", "container", "--format", "{{.Id}}|{{.State.Status}}|{{json .Mounts}}"]

    // MARK: - The cleanup on a stand-in docker

    func testTheCleanupKillsTheRunningAndRemovesEveryContainerOfTheWorkFolderAndNoOther() async throws {
        let docker = try NextflowStandInDocker.make(in: root)
        let work = try makeWorkFolder("taxtriage-run-1111")
        let ids = ["a1", "b2", "c3", "d4", "e5", "f6", "07"].map { String(repeating: $0, count: 32) }
        try docker.serve([
            // The run's task, with the folder that holds every run's scratch mounted too, as a real task has it.
            .init(id: ids[0], status: "running", mountSources: [root.path, work.appendingPathComponent("06/2dcb09").path]),
            // The run's task that ended while its wrapper was killed, so nothing removed it.
            .init(id: ids[1], status: "exited", mountSources: [work.appendingPathComponent("aa/111111").path]),
            // The run's task folder in Docker Desktop's spelling.
            .init(id: ids[2], status: "running", mountSources: ["/host_mnt" + realPath(work) + "/bb/222222"]),
            // Another run's task.
            .init(id: ids[3], status: "running", mountSources: [root.path, root.appendingPathComponent("taxtriage-run-2222/work/06/2dcb09").path]),
            // A container that mounts only the folder that holds every run.
            .init(id: ids[4], status: "running", mountSources: [root.path]),
            // A sibling folder whose name starts with the same letters.
            .init(id: ids[5], status: "running", mountSources: [work.path + "-other/06/2dcb09"]),
            // The run's container that was created and never started.
            .init(id: ids[6], status: "created", mountSources: [work.appendingPathComponent("cc/333333").path]),
        ])

        await NextflowDockerContainerCleanup(docker: docker.executable).stopContainers(boundTo: work, within: .seconds(30))

        XCTAssertEqual(docker.arguments(), [
            Self.listing,
            Self.inspection + ids,
            ["kill", ids[0], ids[2]],
            ["rm", ids[0], ids[1], ids[2], ids[6]],
        ], "the running containers of the run are killed, then every container of the run is removed, and no other")
        XCTAssertEqual(
            docker.calls().map(\.argumentCount),
            docker.calls().map(\.arguments.count),
            "each id reaches docker as an argument of its own"
        )
    }

    func testACleanupThatFindsNoContainerOfTheRunStopsOnceItHasReadTheMounts() async throws {
        let docker = try NextflowStandInDocker.make(in: root)
        let work = try makeWorkFolder("taxtriage-run-1111")
        let foreign = String(repeating: "d4", count: 32)
        try docker.serve([
            .init(id: foreign, status: "running", mountSources: [root.appendingPathComponent("taxtriage-run-2222/work/06/2dcb09").path]),
        ])

        await NextflowDockerContainerCleanup(docker: docker.executable).stopContainers(boundTo: work, within: .seconds(30))

        XCTAssertEqual(docker.arguments(), [Self.listing, Self.inspection + [foreign]], "no container of the run, nothing killed")
    }

    func testAnEmptyOrFailedListingEndsTheCleanup() async throws {
        let work = try makeWorkFolder("taxtriage-run-1111")
        let empty = try NextflowStandInDocker.make(in: root)
        try empty.serve([])
        let failing = try NextflowStandInDocker.make(in: root)
        try failing.serve([
            .init(id: String(repeating: "a1", count: 32), status: "running", mountSources: [work.appendingPathComponent("06/2dcb09").path]),
        ])
        failing.failListing()

        await NextflowDockerContainerCleanup(docker: empty.executable).stopContainers(boundTo: work, within: .seconds(30))
        await NextflowDockerContainerCleanup(docker: failing.executable).stopContainers(boundTo: work, within: .seconds(30))

        XCTAssertEqual(empty.arguments(), [Self.listing], "a daemon with no container gets nothing more")
        XCTAssertEqual(failing.arguments(), [Self.listing], "a listing that failed names no container, so nothing is killed")
    }

    func testTheCleanupNeverRunsPastItsBoundAndStopsADockerThatHangs() async throws {
        let docker = try NextflowStandInDocker.make(in: root)
        docker.hangOnListing()
        let work = try makeWorkFolder("taxtriage-run-3333")
        try docker.serve([
            .init(id: String(repeating: "a1", count: 32), status: "running", mountSources: [work.appendingPathComponent("06/2dcb09").path]),
        ])
        let clock = ContinuousClock()
        let started = clock.now

        await NextflowDockerContainerCleanup(docker: docker.executable).stopContainers(boundTo: work, within: .milliseconds(1500))

        let took = clock.now - started
        let hungPID = try XCTUnwrap(docker.hungPID(), "the cleanup asks docker for the containers")
        let stopped = await waitUntil(timeout: .seconds(30)) { !engineTestProcessIsRunning(hungPID) }
        XCTAssertGreaterThanOrEqual(took, .milliseconds(1400), "the cleanup gives docker what is left of the bound")
        XCTAssertLessThan(took, .seconds(5), "and stops it once the bound has passed, \(took)")
        XCTAssertTrue(stopped, "the docker that hangs is stopped, so none outlives the cleanup")
        XCTAssertEqual(docker.arguments(), [Self.listing], "nothing more runs once the bound has passed")
    }

    // MARK: - The match (pure)

    func testAMountCountsByWholePathComponentsInEverySpellingWithLinksResolved() throws {
        let work = try makeWorkFolder("taxtriage-run-4444")
        let task = work.appendingPathComponent("06/2dcb09", isDirectory: true)
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-run")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: work.deletingLastPathComponent())
        let real = realPath(work)
        let cases: [(source: String, isTheRuns: Bool)] = [
            (work.path, true),
            (task.path, true),
            (real + "/06/2dcb09", true),
            ("/host_mnt" + real + "/06/2dcb09", true),
            (link.appendingPathComponent("work/06/2dcb09").path, true),
            (work.appendingPathComponent("06/gone-since").path, true),
            (work.deletingLastPathComponent().path, false),
            (root.path, false),
            (work.path + "-other/06", false),
            (work.path + "/../work-2/06", false),
            ("work/06/2dcb09", false),
            ("", false),
        ]
        for (source, isTheRuns) in cases {
            let container = NextflowDockerContainer(id: String(repeating: "ab", count: 32), status: "running", mountSources: [source])
            let found = NextflowDockerContainerCleanup.containers([container], mountingInside: work)
            XCTAssertEqual(found.count, isTheRuns ? 1 : 0, "\(source) \(isTheRuns ? "lies inside" : "lies outside") the work folder")
        }
    }

    func testAWorkFolderOfFewerThanThreeComponentsSelectsNothing() {
        let container = NextflowDockerContainer(
            id: String(repeating: "ab", count: 32),
            status: "running",
            mountSources: ["/tmp/taxtriage-run-1/work/06", "/var/folders/xx/T/taxtriage-run-1/work/06", "/Users/x"]
        )
        for folder in ["/", "/tmp", "/private/tmp", "/var/folders", "/Users"] {
            let found = NextflowDockerContainerCleanup.containers([container], mountingInside: URL(fileURLWithPath: folder))
            XCTAssertEqual(found, [], "\(folder) holds other runs, so it selects nothing")
        }
    }

    func testInspectLinesAreReadAndOnlyContainerIDsReachDocker() {
        let id = String(repeating: "a1", count: 32)
        let output = [
            #"\#(id)|running|[{"Type":"bind","Source":"/var/folders/xx/T","Destination":"/var/folders/xx/T"},{"Type":"bind","Source":"/var/folders/xx/T/taxtriage-run-1/work/06/2dcb09"}]"#,
            String(repeating: "b2", count: 32) + "|exited|null",
            String(repeating: "c3", count: 32) + "|running|[not json",
            "--help|running|[]",
            String(repeating: "D4", count: 32) + "|running|[]",
            "abc|running|[]",
            "a line with no bars",
        ].joined(separator: "\n")

        XCTAssertEqual(NextflowDockerContainerCleanup.parseInspect(output), [
            NextflowDockerContainer(id: id, status: "running", mountSources: ["/var/folders/xx/T", "/var/folders/xx/T/taxtriage-run-1/work/06/2dcb09"]),
            NextflowDockerContainer(id: String(repeating: "b2", count: 32), status: "exited", mountSources: []),
        ], "a line that cannot be read, and an id that is not one, are left out")
        XCTAssertEqual(
            NextflowDockerContainerCleanup.containerIDs(in: "\(id)\n  \n--all\n\(String(repeating: "e5", count: 6))\n"),
            [id],
            "only full ids reach docker as arguments, so the 12-digit token is left out"
        )
        XCTAssertEqual(
            NextflowDockerContainerCleanup.inspectArguments(for: [id]),
            Self.inspection + [id]
        )
    }

    // MARK: - Which runs get the cleanup

    func testOnlyALaunchWhoseProfileRunsInDockerGetsTheCleanupAndItAsksForDockerOnlyAtACancel() async throws {
        let probe = StandInDockerProbe(dockerPath: "/opt/stand-in/docker")
        let dockerLaunch = NextflowEngineProcess(configuration: .forTests(waitsForDocker: true))
        let otherLaunch = NextflowEngineProcess(configuration: .forTests(waitsForDocker: false))

        let cleanup = try XCTUnwrap(dockerLaunch.containerCleanup(probe: probe) as? NextflowDockerContainerCleanup)
        XCTAssertEqual(probe.cliLookups, 0, "a run that is not cancelled starts no process to find docker")
        XCTAssertEqual(cleanup.dockerExecutable()?.path, "/opt/stand-in/docker", "a cancel uses the docker the probe finds")
        XCTAssertNil(otherLaunch.containerCleanup(probe: probe), "a launch that runs no task in Docker has none to stop")
        let noDocker = StandInDockerProbe(dockerPath: nil)
        let clock = ContinuousClock()
        let started = clock.now
        await dockerLaunch.containerCleanup(probe: noDocker)?
            .stopContainers(boundTo: try makeWorkFolder("taxtriage-run-5555"), within: .seconds(30))
        XCTAssertEqual(noDocker.cliLookups, 1, "the cancel asks for docker once")
        XCTAssertLessThan(clock.now - started, .seconds(5), "with no docker the cleanup ends at once")
        XCTAssertNotNil(TaxTriagePipeline.nextflowEngine(processManager: .shared, profile: "docker").containerCleanup(probe: probe))
        for profile in ["conda", TaxTriageStandInEngine.profile] {
            XCTAssertNil(
                TaxTriagePipeline.nextflowEngine(processManager: .shared, profile: profile).containerCleanup(probe: probe),
                "TaxTriage with the \(profile) profile"
            )
        }
    }

    // MARK: - Helpers

    /// `<root>/<name>/work`, made on disk.
    private func makeWorkFolder(_ name: String) throws -> URL {
        let work = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    /// The path with every link resolved, `/private/var/...` for a folder in the system temporary folder.
    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
