// EnvelopeCopySources.swift - The three recorded sources every envelope copy site has to keep faithfully
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a. Twelve sites copied a recorded envelope into a new one. A copy that names every
// field drops each field it forgets. Two facts were being forgotten. The first is the status, because a
// status derived from the exit status cannot tell a cancelled run from a completed one. The second is a
// pre-2.4 record's `readSetPlan`, which sat only in the nested run that the encoder never writes. This
// file builds the three sources the same way for every site and for every test target.
//
// A source is made from a base envelope the site's own fixture builds, by editing the record's JSON,
// so it does not depend on how the base was built or on the helper that the pins check.

import Foundation
import LungfishWorkflow
import XCTest

public enum EnvelopeCopySources {
    /// The three recorded sources a copy site must keep.
    public enum Kind: String, CaseIterable, Sendable {
        /// Status cancelled while every step exited 0, the shape of a run cancelled between steps.
        case cancelled
        /// Status failed while every step exited 0, the shape of a failure in a stage that records none.
        case failedLastStepExitedZero
        /// A record written before 2.4. Its top-level options lack `readSetPlan` and its nested run holds it.
        case preTwoFourNestedPlan

        /// The status a faithful copy of this source holds.
        public var expectedStatus: RunStatus {
            switch self {
            case .cancelled: return .cancelled
            case .failedLastStepExitedZero: return .failed
            case .preTwoFourNestedPlan: return .completed
            }
        }
    }

    /// The pairing plan that the Kraken2 pipeline puts into a run's parameters
    /// (`ReadSetPlan.provenanceParameters["readSetPlan"]`), with a null member as the real one has.
    public static let readSetPlan: ParameterValue = .dictionary([
        "capability": .string("pairsOrSinglesPerRun"),
        "sourceLayout": .string("pairsAndSingles"),
        "pairedFragments": .integer(1),
        "mergedReads": .null,
        "orphanReads": .integer(1),
        "singleEndReads": .null,
        "runs": .integer(2),
        "singleReadReason": .string("orphan reads run as single reads"),
    ])

    /// Another run parameter that only the nested run holds, under a key no site sets, to show the merge
    /// carries more than the plan.
    public static let nestedOnlyParameter: ParameterValue = .string("only in the nested run")

    public enum SourceError: Error {
        case notAJSONObject
    }

    /// The three sources, then a failed source whose run-level exit status is 1, for the sites that set the
    /// exit status of the copy. A faithful copy of the last one holds status failed and exit status 1, as
    /// the recorder's own records do (S4a review, fix 2).
    public static let sourcesWithFailedExit: [(kind: Kind, exitStatus: Int?)] =
        Kind.allCases.map { ($0, nil) } + [(.failedLastStepExitedZero, 1)]

    /// The record bytes of `kind`, made from the bytes of a completed record. A `.preTwoFourNestedPlan`
    /// source also holds `extraNestedParameters` in its nested run, for a site that rewrites paths, and
    /// `exitStatus`, when given, replaces the run-level exit status.
    public static func recordBytes(
        _ kind: Kind,
        from bytes: Data,
        extraNestedParameters: [String: ParameterValue] = [:],
        exitStatus: Int? = nil
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw SourceError.notAJSONObject
        }
        if let exitStatus {
            object["exitStatus"] = exitStatus
        }
        switch kind {
        case .cancelled, .failedLastStepExitedZero:
            object["status"] = kind.expectedStatus.rawValue
        case .preTwoFourNestedPlan:
            object["status"] = RunStatus.completed.rawValue
            // The nested run an older writer embedded held the same steps as the record and the run's
            // parameters, which are the only place the plan and the thread count were kept.
            var nested = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)
                .legacyWorkflowRun(preferCanonicalSteps: true)
            nested.status = .completed
            nested.parameters = ["readSetPlan": readSetPlan, "copyPinNestedOnly": nestedOnlyParameter]
                .merging(extraNestedParameters) { given, _ in given }
            let nestedBytes = try ProvenanceJSON.encoder.encode(nested)
            object["legacyWorkflowRun"] = try JSONSerialization.jsonObject(with: nestedBytes)
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Rewrites a sidecar a writer just wrote so that it is a record of `kind`.
    public static func rewriteSidecar(
        at url: URL,
        as kind: Kind,
        extraNestedParameters: [String: ParameterValue] = [:],
        exitStatus: Int? = nil
    ) throws {
        try recordBytes(
            kind, from: Data(contentsOf: url), extraNestedParameters: extraNestedParameters, exitStatus: exitStatus
        ).write(to: url, options: .atomic)
    }

    /// Rewrites every envelope record below `folder`. A bundle writer also writes a record per output,
    /// and a reader that looks for the record of one output reads that file and not the root.
    public static func rewriteEveryRecord(under folder: URL, as kind: Kind, exitStatus: Int? = nil) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  object["workflowName"] != nil, object["steps"] != nil else { continue }
            try rewriteSidecar(at: url, as: kind, exitStatus: exitStatus)
        }
    }

    /// An envelope as a record of `kind` would decode, for sites that take an envelope in memory.
    public static func variant(_ kind: Kind, of base: ProvenanceEnvelope) throws -> ProvenanceEnvelope {
        let bytes = try recordBytes(kind, from: ProvenanceJSON.encoder.encode(base))
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)
    }

    /// What a faithful copy of a `kind` source holds in the run-level resolved defaults, which is the
    /// one home of `readSetPlan` (plan decision E13). Empty for the sources with no nested plan.
    public static func expectedResolvedPlan(_ kind: Kind) -> ParameterValue? {
        kind == .preTwoFourNestedPlan ? readSetPlan : nil
    }

    // MARK: Evidence

    /// The folder that receives the facts of every copy a pin produced, when the run names one. The
    /// lane compares the folder of a run at the base with the folder of a run after the change.
    public static let evidenceFolderVariable = "LUNGFISH_COPY_PIN_FACTS_DIR"

    /// A completed envelope with two steps that exited 0, a release version, a durable replay command and
    /// options in all three maps, so that a copy which drops one of those facts shows. `output` must exist.
    public static func baseEnvelope(
        workflowName: String = "lungfish copy-pin",
        output: URL,
        input: URL? = nil
    ) throws -> ProvenanceEnvelope {
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .unknown, role: .output)
        let inputs = try input.map { [try ProvenanceFileDescriptor.file(url: $0, format: .unknown, role: .input)] } ?? []
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let prepare = ProvenanceStep(
            toolName: "samtools",
            toolVersion: "1.22",
            argv: ["samtools", "sort", workflowName],
            inputs: inputs,
            exitStatus: 0,
            wallTimeSeconds: 1,
            startedAt: started,
            completedAt: started.addingTimeInterval(1)
        )
        let finish = ProvenanceStep(
            toolName: "lungfish-cli",
            toolVersion: "2026.10.14",
            argv: ["lungfish-cli", "copy-pin", workflowName],
            durableReplayArgv: ["lungfish-cli", "copy-pin", workflowName],
            inputs: inputs,
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 1,
            dependsOn: [prepare.id],
            startedAt: started.addingTimeInterval(1),
            completedAt: started.addingTimeInterval(2)
        )
        return ProvenanceEnvelope(
            createdAt: started,
            workflowName: workflowName,
            workflowVersion: "2026.10.14",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.14",
            githubReleaseVersion: "v2026.10.14",
            argv: ["lungfish-cli", "copy-pin", workflowName],
            durableReplayArgv: ["lungfish-cli", "copy-pin", workflowName, "--durable"],
            options: ProvenanceOptions(
                explicit: ["mode": .string("fast")],
                defaults: ["quality": .integer(20)],
                resolvedDefaults: ["indexed": .boolean(true)]
            ),
            files: inputs + [outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [prepare, finish],
            wallTimeSeconds: 2,
            exitStatus: 0,
            stderr: "a note"
        )
    }

    /// Reads the sidecar a site wrote through the production reader, projects its facts and records
    /// them as evidence, then returns the envelope for the assertion.
    public static func capture(
        site: String,
        kind: Kind,
        sidecar: URL,
        projectRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProvenanceEnvelope {
        let copy = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: sidecar),
            "\(site) wrote no readable record at \(sidecar.path)",
            file: file,
            line: line
        )
        let facts = try ProvenanceCompatFacts.project(envelope: copy, sidecar: sidecar, projectRoot: projectRoot)
        recordEvidence(site: site, kind: kind, facts: facts)
        return copy
    }

    /// Writes `facts` as `<folder>/<site>-<kind>.json` when `evidenceFolderVariable` names a folder.
    public static func recordEvidence(site: String, kind: Kind, facts: ProvenanceCompatFacts) {
        guard let folder = ProcessInfo.processInfo.environment[evidenceFolderVariable], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(site)-\(kind.rawValue).json"
        try? facts.canonicalJSON().write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

// MARK: - The assertion every site pin makes

extension EnvelopeCopySources {
    /// What a copy site's output holds against what a faithful copy of `kind` holds. The status is the
    /// source's, and `readSetPlan` sits in the run-level resolved defaults and never in the explicit options.
    public static func problems(
        of copy: ProvenanceEnvelope,
        kind: Kind,
        expectedStatus: RunStatus? = nil,
        expectsPlan: Bool? = nil,
        keeping source: ProvenanceEnvelope? = nil,
        keepsDurableReplayArgv: Bool = true
    ) -> [String] {
        var problems: [String] = []
        let status = expectedStatus ?? kind.expectedStatus
        if copy.status != status {
            problems.append("status is \(copy.status.rawValue) and should be \(status.rawValue)")
        }
        if let source {
            if copy.githubReleaseVersion != source.githubReleaseVersion {
                problems.append("githubReleaseVersion is \(String(describing: copy.githubReleaseVersion))")
            }
            if keepsDurableReplayArgv, copy.durableReplayArgv != source.durableReplayArgv {
                problems.append("durableReplayArgv is \(String(describing: copy.durableReplayArgv))")
            }
        }
        if expectsPlan ?? (expectedResolvedPlan(kind) != nil) {
            if copy.options.resolvedDefaults["readSetPlan"] != readSetPlan {
                problems.append("options.resolvedDefaults lost the readSetPlan of the nested run")
            }
            if copy.options.resolvedDefaults["copyPinNestedOnly"] != nestedOnlyParameter {
                problems.append("options.resolvedDefaults lost the other parameter of the nested run")
            }
            if copy.options.explicit["readSetPlan"] != nil {
                problems.append("options.explicit holds the readSetPlan, which belongs in the resolved defaults")
            }
        }
        return problems
    }

    /// The properties `ProvenanceEnvelope.with` changes on its own for a source of `kind`, which are the
    /// signatures, the nested run and, when the run holds parameters the options lack, the options.
    public static func changedByTheHelper(_ kind: Kind) -> Set<String> {
        var changed: Set<String> = ["signatures", "legacyRun"]
        if kind == .preTwoFourNestedPlan { changed.insert("options") }
        return changed
    }

    /// Asserts that every stored property of `copy` that the site does not change is the source's, by
    /// reflection, so a field added to the envelope later is checked without another edit.
    public static func assertCarried(
        _ copy: ProvenanceEnvelope,
        from source: ProvenanceEnvelope,
        except changed: Set<String>,
        site: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func texts(of value: Any) -> [(label: String, text: String)] {
            Mirror(reflecting: value).children.compactMap { child in
                child.label.map { ($0, "\(child.value)") }
            }
        }
        let before = Dictionary(uniqueKeysWithValues: texts(of: source).map { ($0.label, $0.text) })
        let after = texts(of: copy)
        for property in after where !changed.contains(property.label) {
            XCTAssertEqual(
                property.text, before[property.label], "\(site) changed or dropped \(property.label)",
                file: file, line: line
            )
        }
        XCTAssertEqual(Set(after.map(\.label)), Set(before.keys), "\(site) returned another type", file: file, line: line)
        XCTAssertTrue(
            changed.isSubset(of: Set(before.keys)),
            "\(site) names a property the envelope does not have", file: file, line: line
        )
    }

    /// Asserts the copy is faithful.
    public static func assertFaithfulCopy(
        site: String,
        kind: Kind,
        copy: ProvenanceEnvelope,
        expectedStatus: RunStatus? = nil,
        expectsPlan: Bool? = nil,
        keeping source: ProvenanceEnvelope? = nil,
        keepsDurableReplayArgv: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let found = problems(
            of: copy,
            kind: kind,
            expectedStatus: expectedStatus,
            expectsPlan: expectsPlan,
            keeping: source,
            keepsDurableReplayArgv: keepsDurableReplayArgv
        )
        XCTAssertEqual(found, [], "\(site) copied a \(kind.rawValue) source unfaithfully", file: file, line: line)
    }
}
