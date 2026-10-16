// PortablePathRerootSpanTests.swift - A recorded command keeps every word when its paths re-root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// 2.11 A34. In free text a foreign project path re-roots only at the first
/// `.lungfish/` component of its span, and only when no other path starts
/// before that component. So a run of a command's words is never replaced by
/// a later path whose tail exists here, and each path of the command moves on
/// its own. Before A34 the reader wrote the last such path in place of the
/// whole span, a loss the TaxTriage parity declared for case X6 on sides B and C.
final class PortablePathRerootSpanTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        (root, project) = try PortablePathRerootTests.makeProject()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private typealias Fixture = PortablePathRerootTests

    private var taxTriageSidecar: URL {
        project.appendingPathComponent("\(Fixture.taxTriageOutput)/.lungfish-provenance.json")
    }

    /// Each tail in `present` spelled for this project, every other tail as `foreign` recorded it.
    private func spelled(_ present: Set<String>, foreign: String) -> (String) -> String {
        { [project] tail in present.contains(tail) ? Fixture.here(tail, in: project!) : "\(foreign)/\(tail)" }
    }

    /// The step command of a TaxTriage record as Copy Command reads it.
    private func readTaxTriageCommand(executable: String, present: Set<String>) throws -> (read: String?, expected: String) {
        for tail in present { try Fixture.make(tail, in: project) }
        let recorded = Fixture.taxTriageWords(executable: executable, spelled([], foreign: Fixture.collaborator))
        let expected = Fixture.taxTriageWords(executable: executable, spelled(present, foreign: Fixture.collaborator))
        let read = try Fixture.read(
            ["steps": [["reproducibleCommand": recorded.joined(separator: " ")]]], at: taxTriageSidecar
        )
        let command = (read["steps"] as? [[String: Any]])?.first?["reproducibleCommand"] as? String
        return (command, expected.joined(separator: " "))
    }

    /// Side A of parity case X6. The cancel removed the launch scratch, so
    /// only the output folder exists here.
    func testTaxTriageCommandKeepsEveryWordWhenOnlyItsOutputFolderExists() throws {
        let result = try readTaxTriageCommand(executable: Fixture.nextflow, present: [Fixture.taxTriageOutput])
        XCTAssertEqual(result.read, result.expected)
    }

    /// Sides B and C of parity case X6. The launch scratch stays for the sweep.
    func testTaxTriageCommandKeepsEveryWordWhenItsScratchIsKept() throws {
        let present = Set(Fixture.taxTriageScratch + [Fixture.taxTriageOutput])
        let result = try readTaxTriageCommand(executable: Fixture.nextflow, present: present)
        XCTAssertEqual(result.read, result.expected)
    }

    /// A tool under another account's `~/.lungfish` is a `.lungfish/`
    /// component too, and its tail never exists in the project.
    func testCommandWhoseToolLiesUnderALungfishFolderKeepsEveryWord() throws {
        let tool = "/Users/collaborator/.lungfish/conda/envs/nextflow/bin/nextflow"
        let present = Set(Fixture.taxTriageScratch + [Fixture.taxTriageOutput])
        let result = try readTaxTriageCommand(executable: tool, present: present)
        XCTAssertEqual(result.read, result.expected)
    }

    /// A run bundle's command preview, as `--repeat-from` reads it, that names
    /// several paths of the project.
    func testRepeatFromCommandPreviewKeepsEveryWord() throws {
        let words = { (path: (String) -> String) in
            "nextflow run \(path("Workflows/hello/main.nf")) --input \(path(Fixture.reads)) --outdir \(path("Analyses/minimap2-1"))"
        }
        let present: Set = [Fixture.reads, "Analyses/minimap2-1"]
        let manifest = project.appendingPathComponent("Analyses/nf-hello-1/manifest.json")
        let read = try Fixture.read(["commandPreview": words(spelled([], foreign: Fixture.collaborator))], at: manifest)
        XCTAssertEqual(read["commandPreview"] as? String, words(spelled(present, foreign: Fixture.collaborator)))
    }

    /// An unquoted command on a project folder named with spaces moves each
    /// path and keeps the words between them.
    func testUnquotedCommandOnAProjectFolderWithASpaceKeepsEveryWord() throws {
        let words = { (path: (String) -> String) in
            "minimap2 -ax sr \(path(Fixture.reads)) -o \(path("Analyses/minimap2-1")) --secondary=no"
        }
        let present: Set = [Fixture.reads, "Analyses/minimap2-1"]
        let sidecar = project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json")
        let read = try Fixture.read(["reproducibleCommand": words(spelled([], foreign: Fixture.share))], at: sidecar)
        XCTAssertEqual(read["reproducibleCommand"] as? String, words(spelled(present, foreign: Fixture.share)))
    }

    /// A tool path and an option given with `=` start paths of their own, so
    /// the words before a project path stay.
    func testWordsBeforeAProjectPathStayWhenAnotherPathStartsTheSpan() throws {
        let sidecar = project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json")
        for (recorded, expected) in [
            ("/usr/bin/samtools index \(Fixture.collaborator)/Analyses/minimap2-1",
             "/usr/bin/samtools index \(Fixture.here("Analyses/minimap2-1", in: project))"),
            ("/opt/bin/fastp --in=\(Fixture.collaborator)/\(Fixture.reads)",
             "/opt/bin/fastp --in=\(Fixture.here(Fixture.reads, in: project))"),
        ] {
            let read = try Fixture.read(["reproducibleCommand": recorded], at: sidecar)
            XCTAssertEqual(read["reproducibleCommand"] as? String, expected, recorded)
        }
    }
}
