import Foundation
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCCohortAlignmentBuilderTests: XCTestCase {
    func testBuildNamespacesTargetsAddsReadGroupsAndUsesExactStableCommandOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(samples: [
            fixture.sample("sample-B", clusters: ["cluster-2"]),
            fixture.sample("sample-A", clusters: ["cluster-1"]),
        ])

        XCTAssertEqual(result.sampleMappings.map(\.sampleID), ["sample-A", "sample-B"])
        XCTAssertEqual(
            result.sampleMappings.flatMap(\.targets).map(\.namespacedTargetID),
            ["sample-A|cluster-1", "sample-B|cluster-2"]
        )
        XCTAssertEqual(result.sampleMappings.map(\.readGroupID), ["sample-A", "sample-B"])
        XCTAssertEqual(result.sampleMappings.map(\.readGroupSample), ["sample-A", "sample-B"])

        let bam = try String(contentsOf: result.bamURL, encoding: .utf8)
        XCTAssertTrue(bam.contains("@SQ\tSN:sample-A|cluster-1"))
        XCTAssertTrue(bam.contains("@SQ\tSN:sample-B|cluster-2"))
        XCTAssertTrue(bam.contains("@RG\tID:sample-A\tSM:sample-A"))
        XCTAssertTrue(bam.contains("@RG\tID:sample-B\tSM:sample-B"))

        let commands = try fixture.commands()
        XCTAssertEqual(commands.map(\.first), [
            "minimap2", "samtools", "samtools", "samtools",
            "minimap2", "samtools", "samtools", "samtools",
            "samtools", "samtools", "samtools", "samtools", "samtools",
        ])
        XCTAssertEqual(commands.compactMap { $0.dropFirst().first }, [
            "-a", "view", "addreplacerg", "sort",
            "-a", "view", "addreplacerg", "sort",
            "merge", "sort", "index", "quickcheck", "idxstats",
        ])

        let minimapArguments = Array(commands[0].dropFirst())
        XCTAssertEqual(Array(minimapArguments.prefix(11)), [
            "-a", "-x", "splice", "--eqx", "-t", "4", "-N", "100", "--secondary=yes",
            result.sampleMappings[0].namespacedClustersFASTAURL.path,
            fixture.referenceURL.path,
        ])
        XCTAssertEqual(minimapArguments.count, 11)
        XCTAssertEqual(Array(commands[1].dropFirst()), [
            "view", "-b", "-o",
            result.sampleMappings[0].unsortedBAMURL.path,
            result.sampleMappings[0].samURL.path,
        ])
        XCTAssertEqual(Array(commands[2].dropFirst()), [
            "addreplacerg", "-r", "ID:sample-A", "-r", "SM:sample-A", "-o",
            result.sampleMappings[0].readGroupBAMURL.path,
            result.sampleMappings[0].unsortedBAMURL.path,
        ])
        XCTAssertEqual(Array(commands[3].dropFirst()), [
            "sort", "-o", result.sampleMappings[0].sortedBAMURL.path,
            result.sampleMappings[0].readGroupBAMURL.path,
        ])

        let merge = Array(commands[8].dropFirst())
        XCTAssertEqual(merge, [
            "merge", "-f", "-o", result.mergedBAMURL.path,
            result.sampleMappings[0].sortedBAMURL.path,
            result.sampleMappings[1].sortedBAMURL.path,
        ])
        XCTAssertEqual(result.commandRecords.map(\.argv), commands.map { command in
            [fixture.toolsURL.appendingPathComponent(command[0]).path] + command.dropFirst()
        })
    }

    func testBuildStagesAndValidatesBothFilesBeforePublishingFinalNames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])

        XCTAssertEqual(result.bamURL.path, fixture.outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam").path)
        XCTAssertEqual(result.baiURL.path, fixture.outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bamURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.baiURL.path))
        let commands = try fixture.commands()
        let cohortSort = Array(commands[5].dropFirst())
        let stagedBAM = cohortSort[2]
        XCTAssertNotEqual(stagedBAM, result.bamURL.path)
        XCTAssertTrue(stagedBAM.contains(".genotyping-evidence-staging-"))
        XCTAssertEqual(Array(commands[6].dropFirst()), ["index", stagedBAM, stagedBAM + ".bai"])
        XCTAssertEqual(Array(commands[7].dropFirst()), ["quickcheck", stagedBAM])
        XCTAssertEqual(Array(commands[8].dropFirst()), ["idxstats", stagedBAM])
        XCTAssertEqual(result.commandRecords.suffix(2).map(\.arguments.first), ["quickcheck", "idxstats"])
    }

    func testFailureBeforePublicationRetainsTemporaryFilesAndPublishesNoPair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setFailure(command: "quickcheck")

        var retained: URL?
        do {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
            XCTFail("Expected quickcheck failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            retained = error.retainedWorkDirectoryURL
        }

        XCTAssertNotNil(retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAIURL.path))
        XCTAssertTrue(try recursiveFiles(at: retained!).contains { $0.pathExtension == "bam" })
    }

    func testSuccessRemovesTemporaryFilesUnlessKeepIntermediatesIsTrue() async throws {
        let cleanupFixture = try Fixture()
        defer { cleanupFixture.remove() }
        let cleaned = try await cleanupFixture.build(samples: [cleanupFixture.sample("S1", clusters: ["c1"])])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.temporaryWorkDirectoryURL.path))

        let retainedFixture = try Fixture()
        defer { retainedFixture.remove() }
        let retained = try await retainedFixture.build(
            samples: [retainedFixture.sample("S1", clusters: ["c1"])],
            keepIntermediates: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.temporaryWorkDirectoryURL.path))
        XCTAssertTrue(try recursiveFiles(at: retained.temporaryWorkDirectoryURL).contains {
            $0.lastPathComponent.hasSuffix(".namespaced-clusters.fa")
        })
    }

    func testValidationFailureDoesNotReplaceExistingFinalPair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.finalBAMURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-bam".utf8).write(to: fixture.finalBAMURL)
        try Data("old-bai".utf8).write(to: fixture.finalBAIURL)
        try Data().write(to: fixture.toolsURL.appendingPathComponent("allow-existing-final"))
        try fixture.setFailure(command: "idxstats")

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
        }

        XCTAssertEqual(try String(contentsOf: fixture.finalBAMURL, encoding: .utf8), "old-bam")
        XCTAssertEqual(try String(contentsOf: fixture.finalBAIURL, encoding: .utf8), "old-bai")
    }

    func testMissingDeclaredOutputFailsEvenWhenToolExitsZero() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.setMissingOutput(command: "view")

        var retained: URL?
        do {
            _ = try await fixture.build(samples: [fixture.sample("S1", clusters: ["c1"])])
            XCTFail("Expected missing output failure")
        } catch let error as FullLengthONTMHCCohortAlignmentBuildError {
            retained = error.retainedWorkDirectoryURL
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAMURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalBAIURL.path))
    }

    func testRejectsUnsafeOrDuplicateSampleIDsAndDuplicateNamespacedTargets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for samples in [
            [fixture.sample("../unsafe", clusters: ["c1"])],
            [fixture.sample("duplicate", clusters: ["c1"]), fixture.sample("duplicate", clusters: ["c2"])],
            [fixture.sample("S1", clusters: ["same", "same"])],
        ] {
            await XCTAssertThrowsErrorAsync {
                _ = try await fixture.build(samples: samples)
            }
        }
        XCTAssertEqual(try fixture.commands(), [])
    }
}

private final class Fixture {
    let root: URL
    let toolsURL: URL
    let outputURL: URL
    let workURL: URL
    let referenceURL: URL

    var finalBAMURL: URL { outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam") }
    var finalBAIURL: URL { outputURL.appendingPathComponent("artifacts/alignments/genotyping-evidence.bam.bai") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohort-alignment-builder-tests-\(UUID().uuidString)", isDirectory: true)
        toolsURL = root.appendingPathComponent("tools", isDirectory: true)
        outputURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        workURL = root.appendingPathComponent("work", isDirectory: true)
        referenceURL = root.appendingPathComponent("alleles.fa")
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        try ">allele-1\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        try Self.writeExecutable(Self.minimap2Script, to: toolsURL.appendingPathComponent("minimap2"))
        try Self.writeExecutable(Self.samtoolsScript, to: toolsURL.appendingPathComponent("samtools"))
        try finalBAMURL.path.write(
            to: toolsURL.appendingPathComponent("final-bam-path"),
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func sample(_ id: String, clusters: [String]) -> FullLengthONTMHCSampleAlignmentInput {
        let source = root.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).clusters.fa")
        try? clusters.map { ">\($0)\nACGT\n" }.joined().write(to: source, atomically: true, encoding: .utf8)
        return FullLengthONTMHCSampleAlignmentInput(
            sampleID: id,
            originalClustersFASTAURL: source,
            clusterRecords: clusters.map {
                FullLengthONTMHCClusterFASTARecord(name: $0, sequence: "ACGT", readCount: 1)
            }
        )
    }

    func build(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        keepIntermediates: Bool = false
    ) async throws -> FullLengthONTMHCCohortAlignmentResult {
        try await FullLengthONTMHCCohortAlignmentBuilder(executableDirectoryURL: toolsURL).build(
            .init(
                samples: samples,
                referenceAlleleFASTAURL: referenceURL,
                threads: 4,
                outputDirectoryURL: outputURL,
                workDirectoryURL: workURL,
                keepIntermediates: keepIntermediates
            )
        )
    }

    func setFailure(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("fail-command"), atomically: true, encoding: .utf8)
    }

    func setMissingOutput(command: String) throws {
        try command.write(to: toolsURL.appendingPathComponent("missing-output-command"), atomically: true, encoding: .utf8)
    }

    func commands() throws -> [[String]] {
        let url = toolsURL.appendingPathComponent("commands.log")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let minimap2Script = #"""
    #!/bin/sh
    tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    printf 'minimap2' >> "$tool_dir/commands.log"
    for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
    printf '\n' >> "$tool_dir/commands.log"
    previous=''
    current=''
    for arg in "$@"; do previous=$current; current=$arg; done
    target=$previous
    target_id=$(awk '/^>/{sub(/^>/, ""); print $1; exit}' "$target")
    printf '@HD\tVN:1.6\tSO:unsorted\n@SQ\tSN:%s\tLN:4\nallele-1\t0\t%s\t1\t60\t4=\t*\t0\t0\tACGT\tIIII\n' "$target_id" "$target_id"
    """#

    private static let samtoolsScript = #"""
    #!/bin/sh
    tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    printf 'samtools' >> "$tool_dir/commands.log"
    for arg in "$@"; do printf '\t%s' "$arg" >> "$tool_dir/commands.log"; done
    printf '\n' >> "$tool_dir/commands.log"
    command=$1
    if [ -f "$tool_dir/fail-command" ] && [ "$(cat "$tool_dir/fail-command")" = "$command" ]; then
      printf 'forced %s failure\n' "$command" >&2
      exit 42
    fi
    missing=''
    if [ -f "$tool_dir/missing-output-command" ] && [ "$(cat "$tool_dir/missing-output-command")" = "$command" ]; then
      missing=1
    fi
    shift
    case "$command" in
      view)
        [ "$1" = "-b" ] && shift
        [ "$1" = "-o" ] || exit 90
        output=$2; input=$3
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      addreplacerg)
        shift; rg_id=$1; shift
        shift; rg_sm=$1; shift
        shift; output=$1; input=$2
        if [ -z "$missing" ]; then
          printf '@RG\t%s\t%s\n' "$rg_id" "$rg_sm" > "$output"
          cat "$input" >> "$output"
        fi
        ;;
      sort)
        [ "$1" = "-o" ] || exit 91
        output=$2; input=$3
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      merge)
        [ "$1" = "-f" ] || exit 92; shift
        [ "$1" = "-o" ] || exit 93
        output=$2; shift 2
        if [ -z "$missing" ]; then
          : > "$output"
          for input in "$@"; do cat "$input" >> "$output"; done
        fi
        ;;
      index)
        input=$1; output=$2
        [ -n "$missing" ] || cp "$input" "$output"
        ;;
      quickcheck|idxstats)
        input=$1
        final_path=$(cat "$tool_dir/final-bam-path")
        if [ -e "$final_path" ] && [ ! -f "$tool_dir/allow-existing-final" ]; then
          printf 'final BAM published before %s\n' "$command" >&2
          exit 77
        fi
        [ -f "$input" ] || exit 94
        [ -f "$input.bai" ] || exit 95
        [ "$command" = "idxstats" ] && printf 'sample-target\t4\t1\t0\n'
        ;;
      *) exit 99 ;;
    esac
    exit 0
    """#
}

private func recursiveFiles(at root: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
