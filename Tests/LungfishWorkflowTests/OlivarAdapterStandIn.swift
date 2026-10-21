// OlivarAdapterStandIn.swift - The finished output of an Olivar adapter run for pipeline tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.49. `PrimerSchemePipelineFixture.writeAdapterSuccess` writes a varVAMP-shaped result over a 100 bp
// reference with an 80 bp assay, and the result loader refuses an assay outside the request's amplicon bounds. Olivar
// needs an amplicon of 120 bp or more (`PrimerSchemeDesignOptions.validate`), so this stand-in writes the same shape over
// a 200 bp reference with a 160 bp assay. It replaces only the native tool run. The pipeline's result loading,
// publication and destination handling run as shipped.

import Foundation
@testable import LungfishWorkflow

enum OlivarAdapterStandIn {
    static let referenceLength = 200
    private static let assayStart = 10
    private static let assayEnd = 170

    static func writeSuccess(command: PrimerSchemeAdapterCommand, fixture: PrimerSchemePipelineFixture) throws {
        let fileManager = FileManager.default
        let output = command.outputDirectoryURL
        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        let generated = output.appendingPathComponent("generated/reference.fasta")
        let map = output.appendingPathComponent("maps/target.json")
        let stdout = output.appendingPathComponent("logs/native-stdout.txt")
        let stderr = output.appendingPathComponent("logs/native-stderr.txt")
        let replay = output.appendingPathComponent("replay/request-v1.json")
        for directory in [
            generated.deletingLastPathComponent(), map.deletingLastPathComponent(), stdout.deletingLastPathComponent(),
            replay.deletingLastPathComponent(), output.appendingPathComponent("native"),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data((">generated-ref\n" + String(repeating: "ACGT", count: referenceLength / 4) + "\n").utf8)
            .write(to: generated)
        try Data("native stdout\n".utf8).write(to: stdout)
        try Data().write(to: stderr)
        try Data("{}\n".utf8).write(to: replay)

        let requestInput = command.request.inputs[0]
        try writeJSON([
            "schemaVersion": 1, "coordinateConvention": "zeroBasedHalfOpen",
            "sourceInputID": requestInput.id.uuidString, "sourcePath": requestInput.path,
            "generatedReferencePath": "generated/reference.fasta",
            "sourceLength": referenceLength, "generatedLength": referenceLength,
            "blocks": [[
                "generatedStart": 0, "generatedEnd": referenceLength, "sourceStart": 0, "sourceEnd": referenceLength,
                "kind": "mapped",
            ]],
        ], to: map)

        let artifacts = try [
            artifact(path: "generated/reference.fasta", kind: "generatedReference", root: output),
            artifact(path: "maps/target.json", kind: "bindingProjection", root: output),
            artifact(path: "logs/native-stdout.txt", kind: "stdout", root: output),
            artifact(path: "logs/native-stderr.txt", kind: "stderr", root: output),
            artifact(path: "replay/request-v1.json", kind: "requestSnapshot", root: output),
        ]
        let oligos: [[String: Any]] = [
            oligo(fixture, id: fixture.forwardID, name: "LEFT_1", role: "forward", sequence: "ACGTACGTAC",
                  start: 10, end: 20, strand: "+"),
            oligo(fixture, id: fixture.reverseID, name: "RIGHT_1", role: "reverse", sequence: "TGCATGCATG",
                  start: 160, end: 170, strand: "-"),
        ]
        let target: [String: Any] = [
            "id": fixture.targetID.uuidString, "label": "target",
            "referencePath": "generated/reference.fasta", "referenceID": "generated-ref",
            "referenceLength": referenceLength, "sourceInputID": requestInput.id.uuidString,
            "bindingProjectionPath": "maps/target.json",
            "assays": [[
                "id": fixture.assayID.uuidString, "start": assayStart, "end": assayEnd,
                "memberIDs": oligos.map { $0["id"] as! String }, "pool": "1",
                "status": "selected", "rank": NSNull(), "nativeMetadata": [:],
            ]],
            "oligos": oligos,
        ]

        let provenance = output.appendingPathComponent("provenance-v1.json")
        let runPy = command.adapterDirectoryURL.appendingPathComponent("run.py")
        let environmentRoot = command.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let packageRecord = environmentRoot.appendingPathComponent(
            "conda-meta/\(command.request.engine.rawValue)-\(command.request.engineVersion)-test.json")
        try fileManager.createDirectory(at: packageRecord.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: packageRecord)
        let inputHash = try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: requestInput.path))
        let inputSize = try fileManager.attributesOfItem(atPath: requestInput.path)[.size] as! NSNumber
        let requestOptions = command.request.options.mapValues(jsonObject)
        var resolvedOptions = requestOptions
        resolvedOptions["adapterResolution"] = ["fixture": true]
        try writeJSON([
            "schemaVersion": 1, "adapterVersion": "1.0.0",
            "adapterSHA256": try PrimerSchemeAdapterResources.directorySHA256(command.adapterDirectoryURL),
            "engine": command.request.engine.rawValue, "engineVersion": command.request.engineVersion,
            "analysisID": command.request.analysisID.uuidString, "runID": command.request.runID.uuidString,
            "resultID": command.request.resultID.uuidString,
            "command": [
                "executable": command.executableURL.path,
                "argv": [command.executableURL.path] + command.arguments,
                "replayCommand": "fixture replay", "workingDirectory": command.workingDirectoryURL.path,
                "environment": command.environment, "nativeInvocations": [],
                "pathMappings": [[
                    "kind": "prefix", "historicalPrefix": command.workingDirectoryURL.path,
                    "durablePrefix": output.path, "durableBase": "outputDirectory",
                    "durableRelativePrefix": ".", "excludedHistoricalSubpaths": ["cache"],
                ]],
                "durableReplay": [
                    "kind": "adapterRequestTemplate",
                    "requestSnapshot": try artifact(path: "replay/request-v1.json", kind: "requestSnapshot", root: output),
                ],
            ],
            "settings": ["supplied": requestOptions, "resolved": resolvedOptions],
            "runtime": [
                "pythonExecutable": command.executableURL.path, "pythonVersion": "3.13.0",
                "platform": "fixture", "implementation": "CPython", "engineModulePath": runPy.path,
                "sourceVerification": [[
                    "path": runPy.path, "sha256": try ProvenanceFileHasher.sha256(of: runPy),
                    "expectedSHA256": try ProvenanceFileHasher.sha256(of: runPy),
                    "byteSize": try ProvenanceFileHasher.fileSize(of: runPy),
                ]],
                "environmentPrefix": environmentRoot.path,
                "distribution": "bioconda::olivar=1.3.3=pyhdfd78af_3",
                "condaPackageRecord": [
                    "path": packageRecord.path, "sha256": try ProvenanceFileHasher.sha256(of: packageRecord),
                    "byteSize": try ProvenanceFileHasher.fileSize(of: packageRecord),
                    "name": command.request.engine.rawValue, "version": command.request.engineVersion,
                    "build": "pyhdfd78af_3", "channel": "bioconda", "subdir": "noarch",
                    "url": "https://conda.anaconda.org/bioconda/noarch/fixture.conda",
                ],
            ],
            "inputs": [[
                "id": requestInput.id.uuidString, "path": requestInput.path, "sha256": inputHash,
                "byteSize": inputSize.intValue,
            ]],
            "auxiliaryInputs": [] as [[String: Any]],
            "inputIntegrity": [
                "checkedBeforeExecution": true, "checkedAfterExecution": true, "unchanged": true,
                "postExecution": [[
                    "id": requestInput.id.uuidString, "path": requestInput.path, "sha256": inputHash,
                    "byteSize": inputSize.intValue, "unchanged": true,
                ]],
            ],
            "outputs": artifacts,
            "nativeEvents": [[
                "engine": command.request.engine.rawValue, "kind": "fixture", "module": "fixture",
                "function": "design", "arguments": [:], "durableArguments": [:], "status": "succeeded",
                "startedAt": "1970-01-01T00:00:01Z", "finishedAt": "1970-01-01T00:00:02Z",
                "wallTimeSeconds": 1.0, "exitStatus": 0,
            ]],
            "startedAt": "1970-01-01T00:00:01Z", "finishedAt": "1970-01-01T00:00:02Z",
            "wallTimeSeconds": 1.0, "exitStatus": 0,
            "stdoutPath": "logs/native-stdout.txt", "stderrPath": "logs/native-stderr.txt",
        ], to: provenance)

        try writeJSON([
            "schemaVersion": 1, "analysisID": command.request.analysisID.uuidString,
            "runID": command.request.runID.uuidString, "resultID": command.request.resultID.uuidString,
            "engine": command.request.engine.rawValue, "engineVersion": command.request.engineVersion,
            "adapterVersion": "1.0.0", "mode": PrimerSchemeMode.tiled.rawValue,
            "resolvedOptions": resolvedOptions,
            "results": [[
                "id": fixture.resultID.uuidString, "inputIDs": [requestInput.id.uuidString], "targets": [target],
            ]],
            "artifacts": artifacts, "provenancePath": "provenance-v1.json",
        ], to: output.appendingPathComponent("adapter-result-v1.json"))
    }

    private static func oligo(
        _ fixture: PrimerSchemePipelineFixture, id: UUID, name: String, role: String, sequence: String, start: Int,
        end: Int, strand: String
    ) -> [String: Any] {
        [
            "id": id.uuidString, "name": name, "role": role, "sequence": sequence, "start": start, "end": end,
            "strand": strand, "assayIDs": [fixture.assayID.uuidString], "pool": "1", "nativeMetadata": [:],
        ]
    }

    private static func artifact(path: String, kind: String, root: URL) throws -> [String: Any] {
        let url = root.appendingPathComponent(path)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        return [
            "path": path, "sha256": try ProvenanceFileHasher.sha256(of: url), "byteSize": size.intValue, "kind": kind,
        ]
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private static func jsonObject(_ value: PrimerSchemeJSONValue) -> Any {
        switch value {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(jsonObject)
        case .object(let values): return values.mapValues(jsonObject)
        }
    }
}
