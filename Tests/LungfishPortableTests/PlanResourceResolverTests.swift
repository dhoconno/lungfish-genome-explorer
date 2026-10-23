// PlanResourceResolverTests.swift - The plan's files resolve under the plan's folder and outputs keep their identity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class PlanResourceResolverTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/inputs"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testResolverRefusesDigestMismatchAndEscapingPath() throws {
        let root = try makeRoot()
        let work = root.appendingPathComponent("work")
        let bytes = Data("@r1\nACGT\n+\nIIII\n".utf8)
        try bytes.write(to: work.appendingPathComponent("inputs/r1.fastq"))
        let outside = root.appendingPathComponent("outside.fastq")
        try bytes.write(to: outside)
        let sha = PortableDigest.sha256Hex(of: bytes)
        let size = Int64(bytes.count)
        let zero = String(repeating: "0", count: 64)
        let resolver = try PlanResourceResolver(planFile: work.appendingPathComponent("plan.json"))

        let resolved = try resolver.verify(PlanEntry(role: .input, relativePath: "inputs/r1.fastq", sha256: sha, size: size))
        XCTAssertEqual(resolved.path, resolver.workRoot + "/inputs/r1.fastq")

        let refusals: [(PlanEntry, PlanResourceRefusal)] = [
            (PlanEntry(role: .input, relativePath: "inputs/r1.fastq", sha256: zero, size: size),
             .digestMismatch(path: "inputs/r1.fastq", expected: zero, actual: sha)),
            (PlanEntry(role: .input, relativePath: "inputs/r1.fastq", sha256: sha, size: size + 1),
             .sizeMismatch(path: "inputs/r1.fastq", expected: size + 1, actual: size)),
            (PlanEntry(role: .input, relativePath: outside.path, sha256: sha, size: size), .absolutePath(outside.path)),
            (PlanEntry(role: .input, relativePath: "../outside.fastq", sha256: sha, size: size), .dotComponent("../outside.fastq")),
            (PlanEntry(role: .input, relativePath: "inputs/../../outside.fastq", sha256: sha, size: size),
             .dotComponent("inputs/../../outside.fastq")),
            (PlanEntry(role: .input, relativePath: "inputs//r1.fastq", sha256: sha, size: size), .dotComponent("inputs//r1.fastq")),
            (PlanEntry(role: .input, relativePath: "-r1.fastq", sha256: sha, size: size), .leadingDash("-r1.fastq")),
            (PlanEntry(role: .input, relativePath: "", sha256: sha, size: size), .emptyPath),
            (PlanEntry(role: .input, relativePath: "inputs/none.fastq", sha256: sha, size: size), .missing("inputs/none.fastq")),
        ]
        try FileManager.default.createSymbolicLink(
            atPath: work.appendingPathComponent("inputs/escape.fastq").path, withDestinationPath: outside.path
        )
        let escaping = PlanEntry(role: .input, relativePath: "inputs/escape.fastq", sha256: sha, size: size)
        for (entry, expected) in refusals + [(escaping, .escapesWorkRoot("inputs/escape.fastq"))] {
            XCTAssertThrowsError(try resolver.verify(entry), entry.relativePath) { error in
                XCTAssertEqual(error as? PlanResourceRefusal, expected)
            }
        }

        // A link that stays inside the plan's folder is followed.
        try FileManager.default.createSymbolicLink(
            atPath: work.appendingPathComponent("inside.fastq").path, withDestinationPath: "inputs/r1.fastq"
        )
        XCTAssertNoThrow(try resolver.verify(PlanEntry(role: .input, relativePath: "inside.fastq", sha256: sha, size: size)))
    }

    func testDescriptorOutputKeepsTheFileIdentity() throws {
        let root = try makeRoot()
        let work = root.appendingPathComponent("work")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let resolver = try PlanResourceResolver(workRoot: work)

        let output = try resolver.openOutput("out/stats/table.tsv")
        defer { output.closeDescriptor() }
        let path = work.appendingPathComponent("out/stats/table.tsv").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? attributes[.systemFileNumber] as? UInt64
        XCTAssertEqual(inode, output.inode)

        // A file planted at the path after the open is never written. The bytes go to the file the descriptor names.
        try FileManager.default.moveItem(atPath: path, toPath: path + ".moved")
        try Data("planted".utf8).write(to: URL(fileURLWithPath: path))
        let handle = FileHandle(fileDescriptor: output.fileDescriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Data("result\n".utf8))
        XCTAssertEqual(try String(contentsOfFile: path + ".moved", encoding: .utf8), "result\n")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "planted")

        // A link at the output path is refused and its target is untouched.
        try FileManager.default.createSymbolicLink(
            atPath: work.appendingPathComponent("out/link.tsv").path, withDestinationPath: outside.path
        )
        XCTAssertThrowsError(try resolver.openOutput("out/link.tsv")) { error in
            XCTAssertEqual(error as? PlanResourceRefusal, .linkInOutputPath(path: "out/link.tsv", component: "link.tsv"))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")

        // A linked folder on the way is refused, and nothing is created through it.
        try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("linked").path, withDestinationPath: root.path)
        XCTAssertThrowsError(try resolver.openOutput("linked/new.tsv")) { error in
            XCTAssertEqual(error as? PlanResourceRefusal, .linkInOutputPath(path: "linked/new.tsv", component: "linked"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.tsv").path))
        XCTAssertThrowsError(try resolver.openOutput("../escape.tsv"))
    }
}
