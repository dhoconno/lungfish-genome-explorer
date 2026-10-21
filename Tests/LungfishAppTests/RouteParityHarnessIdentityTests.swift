// RouteParityHarnessIdentityTests.swift - One entry declares where a record names its caller, and no other path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27, R2 of BIO-Q-A2 and ruling MD62. A record names the tool that made it, so the app's route
// and a leaf's route differ at a fixed set of paths (`CallerIdentityPaths`). `RouteParityHarness.appIdentityDifference`
// declares those paths in A against C with an exact count. A difference at any other path, one that a side lacks and
// one between C and C' still fail.

import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport

final class RouteParityHarnessIdentityTests: XCTestCase {
    private var scratch: URL!
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/usr/bin/false"), kind: .bundle)
    private let label = "run.lungfish-provenance.json"

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "route-parity-identity-unit")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// A completed side whose root holds `record` as its one provenance file.
    private func run(_ side: RouteParitySide, _ record: String) throws -> RouteParitySideRun {
        let root = scratch.appendingPathComponent(side.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try record.write(to: root.appendingPathComponent(label), atomically: true, encoding: .utf8)
        return RouteParitySideRun(side: side, root: root, outcome: RouteParitySideOutcome(end: .completed))
    }

    /// A record as the app or a leaf writes it. The tool is named in four value paths, its executable opens each argv
    /// and each command line, and the arguments after the executable are the same.
    private func record(app: Bool) -> String {
        let (name, kind, executable) = app ? ("Lungfish Genome Explorer", "gui", "lungfish-gui") : ("lungfish-cli", "cli", "lungfish-cli")
        return """
        {"toolName":"\(name)","tool":{"name":"\(name)","kind":"\(kind)"},"runtime":{"app":"\(name)"},
        "argv":["\(executable)","import","a.fa"],"reproducibleCommand":"\(executable) import a.fa",
        "steps":[{"toolName":"\(name)","argv":["\(executable)","import","a.fa"],"reproducibleCommand":"\(executable) import a.fa"}]}
        """
    }

    private func failures(_ scope: RouteParityScope, _ found: [RouteParityDifference], count: Int) -> [String] {
        RouteParityHarness.failures(
            found: [scope: found], parityCase: "case", declared: [RouteParityHarness.appIdentityDifference(["case": count])]
        )
    }

    /// The first line of each failure, without the values it quotes.
    private func headlines(_ failures: [String]) -> [String] {
        failures.map { String($0.prefix { $0 != "\n" }) }
    }

    // MARK: - What is declared

    /// Two roots that differ at identity paths only give one difference for each path, and one entry with the exact
    /// count declares all of them. One more or one fewer in the count fails the case.
    func testTheCallerNameAtEveryIdentityPathIsDeclaredByOneEntryWithAnExactCount() throws {
        let found = try harness.differences(try run(.a, record(app: true)), try run(.c, record(app: false)))
        XCTAssertEqual(found.map(\.id), [
            "identity: \(label) at argv[0]",
            "identity: \(label) at reproducibleCommand",
            "identity: \(label) at runtime.app",
            "identity: \(label) at steps[0].argv[0]",
            "identity: \(label) at steps[0].reproducibleCommand",
            "identity: \(label) at steps[0].toolName",
            "identity: \(label) at tool.kind",
            "identity: \(label) at tool.name",
            "identity: \(label) at toolName",
        ])
        XCTAssertEqual(failures(.aAgainstC, found, count: 9), [])
        XCTAssertEqual(failures(.aAgainstC, found, count: 8).count, 1)
        XCTAssertTrue(
            failures(.aAgainstC, found, count: 8)[0].hasPrefix("A against C: 9 differences match, 8 declared for case"),
            "one more than the count fails"
        )
        XCTAssertTrue(
            failures(.aAgainstC, found, count: 10)[0].hasPrefix("A against C: 9 differences match, 10 declared for case"),
            "one fewer than the count fails"
        )
    }

    // MARK: - What is not declared

    /// An argument after the executable, a version, a command line beyond its first word and a value that one side lacks
    /// stay `differs:` and fail, beside a caller name that is declared.
    func testADifferenceAtAnyOtherPathStillFails() throws {
        let a = try run(.a, """
        {"toolName":"Lungfish Genome Explorer","toolVersion":"1.0","runtime":{"app":"Lungfish Genome Explorer","kind":"k"},
        "steps":[{"argv":["lungfish-cli","import"]}],"reproducibleCommand":"lungfish-cli import a.fa"}
        """)
        let c = try run(.c, """
        {"toolName":"lungfish-cli","toolVersion":"2.0","runtime":{"kind":"k"},
        "steps":[{"argv":["lungfish-cli","export"]}],"reproducibleCommand":"lungfish-cli import b.fa"}
        """)
        let found = try harness.differences(a, c)
        XCTAssertEqual(found.map(\.id), [
            "differs: \(label) at reproducibleCommand",
            "differs: \(label) at runtime.app",
            "differs: \(label) at steps[0].argv[1]",
            "identity: \(label) at toolName",
            "differs: \(label) at toolVersion",
        ])
        XCTAssertEqual(headlines(failures(.aAgainstC, found, count: 1)), [
            "A against C: not declared: differs: \(label) at reproducibleCommand",
            "A against C: not declared: differs: \(label) at runtime.app",
            "A against C: not declared: differs: \(label) at steps[0].argv[1]",
            "A against C: not declared: differs: \(label) at toolVersion",
        ])
    }

    /// C against C' declares nothing, so an identity difference between them fails whatever the entry says.
    func testAnIdentityDifferenceBetweenCAndCPrimeIsNotDeclared() throws {
        let found = try harness.differences(try run(.c, record(app: false)), try run(.cPrime, record(app: true)))
        XCTAssertEqual(found.count, 9)
        XCTAssertTrue(found.allSatisfy { $0.id.hasPrefix("identity: ") })
        let rejected = headlines(failures(.cAgainstCPrime, found, count: 9)).filter { $0.hasPrefix("C against C': not declared: identity: ") }
        XCTAssertEqual(rejected.count, 9)
    }

    // MARK: - The leaf masks

    /// The masks of the leaf tests drop the same paths: lines of a dump, and the values of a log entry.
    func testTheLeafMasksDropTheIdentityPathsAndNoOther() throws {
        XCTAssertEqual(
            CallerIdentityPaths.removingIdentityLines(
                from: "toolName = x\ntool.name = y\ntool.kind = z\ntoolVersion = 1\nsteps[2].toolName = w\nsteps[2].argv[1] = i"
            ),
            "toolVersion = 1\nsteps[2].argv[1] = i"
        )
        let entry: [String: Any] = [
            "toolName": "x", "runtime": ["app": "y", "version": "1"], "argv": ["a", "b"], "annotation": ["toolName": "kept"],
        ]
        let expected: [String: Any] = ["runtime": ["version": "1"], "argv": ["a", "b"], "annotation": ["toolName": "kept"]]
        let masked = try XCTUnwrap(CallerIdentityPaths.removingIdentity(from: entry, at: "entries[0]") as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: masked), NSDictionary(dictionary: expected))
    }
}
