// PortablePathRerootTests.swift - Records written under another machine's project resolve into this one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// A record written before paths were made portable, or on another machine,
/// names the project root it was written under. When it is read from inside a
/// project that holds the same relative file, that path now reads as this
/// project's copy. A tail that does not exist here is left alone.
final class PortablePathRerootTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let foreign = "/tmp/lge-demo-build/projects/Human Mapping and Variants (with results).lungfish"

    override func setUpWithError() throws {
        (root, project) = try Self.makeProject()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sidecar: URL { project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json") }

    func testForeignProjectPathWithExistingTailRerootsIntoThisProject() throws {
        let json = """
        {"files":[{"path":"\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"}],"argv":["minimap2","\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"]}
        """
        let resolved = PortablePath.resolveJSON(Data(json.utf8), forFileAt: sidecar)
        let text = try XCTUnwrap(String(data: resolved, encoding: .utf8))
        let expected = project.standardizedFileURL.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        XCTAssertEqual(text.components(separatedBy: expected.replacingOccurrences(of: "/", with: "\\/")).count, 3, text)
        XCTAssertFalse(text.contains("lge-demo-build"), text)
    }

    func testForeignProjectPathWithoutMatchingTailIsLeftAlone() throws {
        let path = "\(foreign)/Imports/other.lungfishfastq/other.fastq.gz"
        let json = "{\"path\":\"\(path)\"}"
        let resolved = PortablePath.resolveJSON(Data(json.utf8), forFileAt: sidecar)
        XCTAssertEqual(resolved, Data(json.utf8))
    }

    func testPathInsideThisProjectIsUnchanged() throws {
        let path = project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        let text = PortablePath.rerootForeignProjectPaths(text: path, context: .forFile(at: sidecar))
        XCTAssertEqual(text, path)
    }

    // MARK: - The shapes the readers hand to the re-root (2.11 A34 M1)
    //
    // Copy Command copies a step's command from a record that
    // `ProvenanceEnvelopeReader` decodes through `PortablePath.resolveJSON(_:forFileAt:)`,
    // and `--repeat-from` reads its run bundle's manifest through the same
    // function (`LocalWorkflowRunBundle.read(from:)`). Each pin reads the same
    // way before and after A34's fix.

    private func here(_ tail: String) -> String { Self.here(tail, in: project) }

    private var taxTriageSidecar: URL {
        project.appendingPathComponent("Analyses/taxtriage-batch-20261016/.lungfish-provenance.json")
    }

    /// Parity case X6 records each word of the TaxTriage step's command in
    /// its argv, so each path whose tail exists here reads as this
    /// project's copy, and every other word reads as recorded.
    func testTaxTriageStepArgvReadsEachPathWhoseTailExistsIntoThisProject() throws {
        let present = Set(Self.taxTriageScratch + [Self.taxTriageOutput])
        for tail in present { try Self.make(tail, in: project) }
        let recorded = Self.taxTriageWords(executable: Self.nextflow) { "\(Self.collaborator)/\($0)" }
        let expected = Self.taxTriageWords(executable: Self.nextflow) {
            present.contains($0) ? self.here($0) : "\(Self.collaborator)/\($0)"
        }
        let read = try Self.read(["argv": recorded, "steps": [["argv": recorded]]], at: taxTriageSidecar)
        XCTAssertEqual(read["argv"] as? [String], expected)
        XCTAssertEqual((read["steps"] as? [[String: Any]])?.first?["argv"] as? [String], expected)
    }

    /// The same step's command as one line reads as recorded when none of
    /// its paths has a tail here.
    func testTaxTriageStepCommandWithNoTailHereReadsAsRecorded() throws {
        let command = Self.taxTriageWords(executable: Self.nextflow) { "\(Self.collaborator)/\($0)" }
            .joined(separator: " ")
        let read = try Self.read(["steps": [["reproducibleCommand": command]]], at: taxTriageSidecar)
        XCTAssertEqual((read["steps"] as? [[String: Any]])?.first?["reproducibleCommand"] as? String, command)
    }

    /// The commands Copy Command copies that name one path, or quote each
    /// path, read each path into this project and keep every word. A
    /// project folder named with a space re-roots quoted and unquoted.
    func testCopyCommandShapesReadTheirPathsIntoThisProject() throws {
        let reads = Self.reads, output = "Analyses/minimap2-1"
        let commands = [
            ("minimap2 -ax sr -t 8 \(Self.collaborator)/\(reads)", "minimap2 -ax sr -t 8 \(here(reads))"),
            ("minimap2 -ax sr '\(Self.share)/\(reads)'", "minimap2 -ax sr '\(here(reads))'"),
            ("minimap2 -ax sr \(Self.share)/\(reads)", "minimap2 -ax sr \(here(reads))"),
            ("samtools sort -o '\(Self.collaborator)/\(output)' '\(Self.share)/\(reads)'",
             "samtools sort -o '\(here(output))' '\(here(reads))'"),
        ]
        for (recorded, expected) in commands {
            let read = try Self.read(
                ["reproducibleCommand": recorded, "steps": [["reproducibleCommand": recorded]]], at: sidecar
            )
            XCTAssertEqual(read["reproducibleCommand"] as? String, expected, recorded)
            XCTAssertEqual((read["steps"] as? [[String: Any]])?.first?["reproducibleCommand"] as? String, expected, recorded)
        }
    }

    /// A run bundle's manifest, as `--repeat-from` reads it. Its single path
    /// values and a command preview that names one path read into this
    /// project.
    func testRepeatFromManifestReadsItsPathsIntoThisProject() throws {
        let manifest = project.appendingPathComponent("Analyses/nf-hello-1/manifest.json")
        let reads = Self.reads, output = "Analyses/minimap2-1"
        let read = try Self.read([
            "workDirectoryPath": "\(Self.collaborator)/\(output)",
            "params": ["input": "\(Self.share)/\(reads)", "outdir": "\(Self.collaborator)/\(output)"],
            "commandPreview": "nextflow run nf-core/hello -profile docker --input \(Self.collaborator)/\(reads)",
        ], at: manifest)
        XCTAssertEqual(read["workDirectoryPath"] as? String, here(output))
        XCTAssertEqual(read["params"] as? [String: String], ["input": here(reads), "outdir": here(output)])
        XCTAssertEqual(read["commandPreview"] as? String, "nextflow run nf-core/hello -profile docker --input \(here(reads))")
    }

    /// A single path value under a project folder named with spaces, or
    /// with a spaced dash, reads into this project.
    func testSinglePathUnderAProjectFolderWithASpaceReadsIntoThisProject() throws {
        for folder in [Self.share, "/Volumes/Lab Share/Run 7 - pilot.lungfish"] {
            let read = try Self.read(["path": "\(folder)/\(Self.reads)"], at: sidecar)
            XCTAssertEqual(read["path"] as? String, here(Self.reads), folder)
        }
    }

    /// A single path value still moves when its project folder lies inside
    /// another folder whose name ends in `.lungfish`.
    func testSinglePathValueStillMovesAtALaterProjectComponent() throws {
        let path = "/Users/collaborator/.lungfish/demo/Project.lungfish/\(Self.reads)"
        let read = try Self.read(["path": path], at: sidecar)
        XCTAssertEqual(read["path"] as? String, here(Self.reads))
    }
}

/// The project and the record shapes the re-root test classes share (2.11 A34).
extension PortablePathRerootTests {
    /// Another machine's project root, and a project root named with spaces.
    static let collaborator = "/Users/collaborator/Desktop/Project.lungfish"
    static let share = "/Volumes/Lab Share/Run 7.lungfish"
    /// A Nextflow that lies in no `.lungfish` folder.
    static let nextflow = "/usr/local/bin/nextflow"
    static let reads = "Imports/reads.lungfishfastq/reads.fastq.gz"
    static let taxTriageOutput = "Analyses/taxtriage-batch-20261016"
    /// The launch scratch a cancelled GUI run removes and a cancelled
    /// `taxtriage run` keeps for the abandoned-scratch sweep (N7).
    static let taxTriageScratch = [".tmp/taxtriage-run-1234/samplesheet.csv", ".tmp/taxtriage-run-1234/work"]

    /// A project named with a space that holds one reads file and one analysis folder.
    static func makeProject() throws -> (root: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-reroot-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("HG002 chr20.lungfish", isDirectory: true)
        try make(reads, in: project)
        try make("Analyses/minimap2-1", in: project)
        return (root, project)
    }

    /// Makes `tail` under `project`, a folder when its last component has no extension.
    static func make(_ tail: String, in project: URL) throws {
        let url = project.appendingPathComponent(tail)
        let folder = url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if folder != url { try Data("@r\n".utf8).write(to: url) }
    }

    /// The path the re-root writes for `tail` in `project`.
    static func here(_ tail: String, in project: URL) -> String {
        project.standardizedFileURL.path + "/" + tail
    }

    /// `object` as `PortablePath.resolveJSON(_:forFileAt:)` hands it to a reader of `file`.
    static func read(_ object: [String: Any], at file: URL) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let resolved = PortablePath.resolveJSON(data, forFileAt: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: resolved) as? [String: Any])
    }

    /// The words of the TaxTriage step's command in parity case X6
    /// (`TaxTriagePipeline.buildNextflowArguments`), each project path spelled
    /// by `path` from its tail.
    static func taxTriageWords(executable: String, _ path: (String) -> String) -> [String] {
        [executable, "run", "jhuapl-bio/taxtriage", "-r", "e10bfebda32a62711f38a4e23ab03b61725a9675", "-profile", "docker",
         "--input", path(taxTriageScratch[0]), "--outdir", path(taxTriageOutput),
         "-with-trace", path(taxTriageOutput + "/trace.txt"), "-w", path(taxTriageScratch[1]),
         "--db", "/tmp/taxtriage-parity/X6/kraken2-db", "--top_hits_count", "10", "--k2_confidence", "0.2",
         "--rank", "S", "--skip_assembly", "--remove_taxids", "9606", "--max_memory", "16.GB"]
    }
}
