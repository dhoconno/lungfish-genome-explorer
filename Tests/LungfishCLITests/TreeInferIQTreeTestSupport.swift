import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

/// A throwaway project with one .lungfishmsa bundle and a fake iqtree3 next to it.
///
/// The fake records its argv in `iqtree-args.txt`, writes a star tree over the staged
/// FASTA headers (or `fake-tree.nwk` when a test supplies one), and writes a run.log
/// with a `Seed:` line (or `fake-log.txt` when a test supplies one). Its run.iqtree is a stub
/// unless a test supplies `fake-report.txt`.
struct IQTreeTestProject {
    let directory: URL
    let projectURL: URL
    let msaBundleURL: URL
    let fakeIQTreeURL: URL

    static func make(fasta: String, label: String = #function) throws -> IQTreeTestProject {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/TreeInferIQTree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectURL = directory.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.aligned.fasta")
        try fasta.write(to: sourceURL, atomically: true, encoding: .utf8)
        let msaBundleURL = projectURL.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(
            from: sourceURL,
            to: msaBundleURL,
            options: .init(name: "Input")
        )
        let fakeURL = directory.appendingPathComponent("iqtree3")
        try fakeIQTreeScript.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)
        return IQTreeTestProject(directory: directory, projectURL: projectURL, msaBundleURL: msaBundleURL, fakeIQTreeURL: fakeURL)
    }

    func outputURL(_ name: String = "Tree") -> URL {
        projectURL.appendingPathComponent("Phylogenetic Trees/\(name).lungfishtree", isDirectory: true)
    }

    func command(_ extra: [String], output: URL? = nil, iqtreePath: String? = nil) throws -> TreeCommand.InferIQTreeSubcommand {
        try TreeCommand.InferIQTreeSubcommand.parse([
            msaBundleURL.path,
            "--project", projectURL.path,
            "--output", (output ?? outputURL()).path,
            "--iqtree-path", iqtreePath ?? fakeIQTreeURL.path,
            "--format", "json",
        ] + extra)
    }

    /// Runs the command and returns the emitted lines.
    @discardableResult
    func run(_ extra: [String], output: URL? = nil, iqtreePath: String? = nil) async throws -> [String] {
        let recorder = IQTreeLineRecorder()
        try await command(extra, output: output, iqtreePath: iqtreePath).executeForTesting { recorder.append($0) }
        return recorder.lines
    }

    /// Runs the command, expecting it to throw, and returns the error text.
    func failure(_ extra: [String], file: StaticString = #filePath, line: UInt = #line) async -> String {
        do {
            try await run(extra)
            XCTFail("Expected the command to fail", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription + " " + String(describing: error)
        }
    }

    var iqtreeWasInvoked: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("iqtree-invoked").path)
    }

    /// The argv the fake received for the inference run (not the --version probe).
    func recordedIQTreeArguments() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("iqtree-args.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast()
            .map { $0 }
    }

    func setFakeTree(_ newick: String) throws {
        try newick.write(to: directory.appendingPathComponent("fake-tree.nwk"), atomically: true, encoding: .utf8)
    }

    func setFakeReport(_ text: String) throws {
        try text.write(to: directory.appendingPathComponent("fake-report.txt"), atomically: true, encoding: .utf8)
    }

    func setFakeLog(_ text: String) throws {
        try text.write(to: directory.appendingPathComponent("fake-log.txt"), atomically: true, encoding: .utf8)
    }

    func provenance(_ output: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: (output ?? outputURL()).appendingPathComponent(".lungfish-provenance.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let fakeIQTreeScript = """
    #!/bin/sh
    dir="$(cd "$(dirname "$0")" && pwd)"
    touch "$dir/iqtree-invoked"
    if [ "$1" = "--version" ]; then
      echo "IQ-TREE multicore version 3.1.3"
      exit 0
    fi
    : > "$dir/iqtree-args.txt"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$dir/iqtree-args.txt"
    done
    prefix=""
    input=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        -s) input="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "$dir/fake-tree.nwk" ]; then
      cp "$dir/fake-tree.nwk" "$prefix.treefile"
    else
      tips=$(grep '^>' "$input" | sed -e 's/^>//' -e 's/$/:0.1/' | paste -sd, -)
      printf '(%s);\\n' "$tips" > "$prefix.treefile"
    fi
    if [ -f "$dir/fake-report.txt" ]; then
      cp "$dir/fake-report.txt" "$prefix.iqtree"
    else
      printf 'IQ-TREE report\\n' > "$prefix.iqtree"
    fi
    if [ -f "$dir/fake-log.txt" ]; then
      cp "$dir/fake-log.txt" "$prefix.log"
    else
      printf 'IQ-TREE log\\nSeed:    937314 (Using SPRNG - Scalable Parallel Random Number Generator)\\n' > "$prefix.log"
    fi
    echo "fake iqtree stdout"
    exit 0
    """
}

final class IQTreeLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Six rows whose headers IQ-TREE would rewrite or truncate, two of which share a first token.
let awkwardHeaderFASTA = """
>Homo sapiens|NC_012920.1:1-100 mito
ACGTACGTACGTAC
>Homo sapiens|NC_999999.1 other
ACGTACGTACGTAA
>Xenopus (frog)
ACGTACCTACGTAC
>X(f),y
ACCTACGTACGAAC
>Hs|a:1
ACGAACGTACGTAC
>it's a fish
TCGTACGTACGTAC

"""

/// Four plain rows, enough for branch-support runs.
let fourRowFASTA = """
>A
ACGTACGTACGT
>B
ACGTACGTACGA
>C
ACGAACGTACGT
>D
TCGTACGTACGT

"""
