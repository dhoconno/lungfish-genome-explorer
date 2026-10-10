import Foundation
import Testing
import LungfishTestSupport

/// Pins how `ProvenanceCompatFacts.differences(from:ignoring:)` compares facts, since every writer
/// lane relies on it to prove a conversion kept what the frozen case said.
@Suite("Provenance compatibility facts differences")
struct ProvenanceCompatDifferencesTests {
    @Test("identical facts have no differences")
    func identicalFactsHaveNoDifferences() throws {
        let facts = try Self.liveFacts("s3-write-sidecar-bare-run")
        #expect(facts.differences(from: facts).isEmpty)
        #expect(facts.differences(from: facts, ignoring: Set(ProvenanceCompatFacts.Field.allCases)).isEmpty)
    }

    @Test("an edited copy of a case's facts yields lines that name the field")
    func editedCopyYieldsFieldNamedLines() throws {
        let original = try Self.liveFacts("s3-write-sidecar-bare-run")
        var edited = original
        edited.exitStatus = 1
        edited.steps[1].durableReplayArgv = nil
        edited.steps[1].dependsOn = []
        edited.legacyRunSteps[0].containerImage = "registry.example/other:1"
        edited.stderr = "changed"
        edited.explicitOptions = .object([:])

        let lines = edited.differences(from: original)

        #expect(!lines.isEmpty)
        for prefix in [
            "exitStatus:", "steps[1].durableReplayArgv:", "steps[1].dependsOn:",
            "legacyRunSteps[0].containerImage:", "stderr:", "explicitOptions",
        ] {
            #expect(lines.contains { $0.hasPrefix(prefix) }, "no line starts with \(prefix) in \(lines)")
        }
        // A line says what was expected and what was found.
        #expect(lines.contains { $0.hasPrefix("exitStatus:") && $0.hasSuffix("found 1") })
        // Ignoring a field removes only its lines.
        let withoutExit = edited.differences(from: original, ignoring: [.exitStatus])
        #expect(!withoutExit.contains { $0.hasPrefix("exitStatus:") })
        #expect(withoutExit.count == lines.count - 1)
    }

    @Test("the run-specific set hides what two runs of one writer decide for themselves and nothing else")
    func runSpecificSetHidesOnlyRunSpecificFacts() throws {
        let original = try Self.liveFacts("s3-write-sidecar-bare-run")
        var rerun = original
        rerun.recorded["createdAt"] = "2031-01-01T00:00:00Z"
        rerun.recorded["runtimeIdentity.processIdentifier"] = "1"
        rerun.wallTimeSeconds = (original.wallTimeSeconds ?? 0) + 5
        rerun.steps[0].wallTimeSeconds = 999
        rerun.legacyRunSteps[0].wallTime = 999
        rerun.canonicalRunSteps[1].wallTime = 999
        rerun.opsStats.totalWallTimeSeconds += 3

        let all = rerun.differences(from: original)
        for prefix in ["recorded", "wallTimeSeconds:", "steps[0].wallTimeSeconds:", "legacyRunSteps[0].wallTime:", "canonicalRunSteps[1].wallTime:", "opsStats.totalWallTimeSeconds:"] {
            #expect(all.contains { $0.hasPrefix(prefix) }, "no line starts with \(prefix) in \(all)")
        }
        #expect(rerun.differences(from: original, ignoring: ProvenanceCompatFacts.runSpecific).isEmpty)

        rerun.toolVersion = "9.9"
        rerun.steps[1].exitStatus = 2
        let remaining = rerun.differences(from: original, ignoring: ProvenanceCompatFacts.runSpecific)
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.hasPrefix("toolVersion:") })
        #expect(remaining.contains { $0.hasPrefix("steps[1].exitStatus:") })
    }

    @Test("the shape-change set compares files as a set on path, role, SHA-256 and size")
    func shapeChangeSetComparesFilesAsASet() throws {
        let original = try Self.liveFacts("s3-write-sidecar-bare-run")
        var converted = original
        converted.decodedBy = .envelope
        converted.strictAccepts = true
        converted.embeddedRunStatus = "completed"
        converted.files = [original.files[0]] + original.files
        #expect(!converted.differences(from: original).isEmpty)
        #expect(converted.differences(from: original, ignoring: ProvenanceCompatFacts.shapeChange).isEmpty)

        // Repeated entries are the only thing the set rule forgives. A changed digest or size is a difference.
        // The last file is listed once, so changing it changes the set.
        let last = converted.files.count - 1
        let lastSha = converted.files[last].sha256
        let lastSize = converted.files[last].size
        converted.files[last].sha256 = String(repeating: "0", count: 64)
        let changedDigest = converted.differences(from: original, ignoring: ProvenanceCompatFacts.shapeChange)
        #expect(changedDigest.count == 1)
        #expect(changedDigest.first?.hasPrefix("files") == true)
        converted.files[last].sha256 = lastSha
        converted.files[last].size = (lastSize ?? 0) + 1
        #expect(!converted.differences(from: original, ignoring: ProvenanceCompatFacts.shapeChange).isEmpty)

        // A step difference is not forgiven by the shape-change set.
        var stepEdit = original
        stepEdit.steps[0].argv.append("--extra")
        #expect(!stepEdit.differences(from: original, ignoring: ProvenanceCompatFacts.shapeChange).isEmpty)
    }

    @Test("the run wall time tolerance forgives a second and no more")
    func runWallTimeToleranceForgivesASecond() throws {
        let original = try Self.liveFacts("s3-write-sidecar-bare-run")
        #expect(original.wallTimeSeconds == 41)
        var converted = original
        converted.wallTimeSeconds = 41.5

        #expect(converted.differences(from: original).contains { $0.hasPrefix("wallTimeSeconds:") })
        #expect(converted.differences(from: original, runWallTimeTolerance: 1).isEmpty)
        converted.wallTimeSeconds = 43
        #expect(converted.differences(from: original, runWallTimeTolerance: 1).contains { $0.hasPrefix("wallTimeSeconds:") })
        // Step wall times never get a tolerance.
        var stepShift = original
        stepShift.steps[0].wallTimeSeconds = (original.steps[0].wallTimeSeconds ?? 0) + 0.001
        #expect(!stepShift.differences(from: original, runWallTimeTolerance: 1).isEmpty)
    }

    @Test("every field the comparison can ignore names a key the facts encode")
    func everyIgnorableFieldNamesAFactsKey() throws {
        let facts = try Self.liveFacts("s1-cancelled-single-step")
        let json = try #require(
            try JSONSerialization.jsonObject(with: facts.canonicalJSON()) as? [String: Any]
        )
        let partialFields: Set<ProvenanceCompatFacts.Field> = [
            .opsStatsTotalWallTimeSeconds, .filesDuplicates, .stepWallTimeSeconds,
        ]
        for field in ProvenanceCompatFacts.Field.allCases where !partialFields.contains(field) {
            #expect(json[field.rawValue] != nil, "Field.\(field.rawValue) is not a key of the facts")
        }
        // The other keys of the facts are all covered by a field, so no fact escapes the helper.
        let covered = Set(ProvenanceCompatFacts.Field.allCases.map(\.rawValue)).union(["factsVersion"])
        #expect(Set(json.keys).subtracting(covered).isEmpty, "facts keys with no Field: \(Set(json.keys).subtracting(covered))")
    }

    // MARK: Helpers

    private static func liveFacts(_ id: String) throws -> ProvenanceCompatFacts {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        return try ProvenanceCompatFacts.project(sidecar: materialized.sidecar, projectRoot: materialized.projectRoot)
    }
}
