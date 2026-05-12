# Provenance Builder Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ad hoc scientific provenance writing with a canonical provenance envelope, shared builder framework, policy gates, export/report support, GUI rehydration, and real-fixture E2E coverage.

**Architecture:** Add canonical provenance models and writer APIs in `LungfishWorkflow`, then migrate `ProvenanceRecorder`, CLI helpers, app bundle writers, workflow runners, and GUI surfaces onto that writer. Registry and CLI coverage tests make missing provenance a build-time defect, while real-fixture E2E tests and independent review rounds verify the generated JSON and user workflows.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, Swift Testing, AppKit/XCUI, `LungfishWorkflow`, `LungfishCLI`, `LungfishApp`, `LungfishIO`, existing managed-tool fixtures and provenance signing provider.

---

## File Structure

- Create `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift`
  Canonical on-disk schema, file descriptors, runtime identity, options/defaults, signatures, and compatibility aliases.
- Create `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift`
  Decode canonical sidecars first and legacy `WorkflowRun` sidecars second.
- Create `Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift`
  Streaming full SHA-256 and file-size helpers for canonical file descriptors.
- Create `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`
  Builder API for complete run and step provenance.
- Create `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`
  Atomic JSON writer, signing integration, and legacy `WorkflowRun` compatibility writes.
- Create `Sources/LungfishWorkflow/Provenance/ProvenanceRehydrator.swift`
  Copy or convert CLI provenance into final GUI bundle paths.
- Create `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`
  Registry and command policy gates for scientific data-changing surfaces.
- Modify `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`
  Add conversion between `WorkflowRun` and `ProvenanceEnvelope` without removing legacy fields.
- Modify `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift`
  Save canonical sidecars, preserve `load(from:)`, and expose `loadEnvelope(from:)`.
- Modify `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift`
  Export from canonical envelopes and keep `WorkflowRun` export as compatibility.
- Modify `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
  Make CLI provenance helpers wrap the builder.
- Modify `Sources/LungfishCLI/Commands/ProvenanceCommand.swift`
  Add export/report subcommands over canonical provenance.
- Modify scientific CLI command files under `Sources/LungfishCLI/Commands/`
  Replace local `WorkflowRun` writes with `CLIProvenanceSupport` descriptors.
- Modify app workflow and wrapper services under `Sources/LungfishApp/Services/`
  Use builder or rehydrator for final app-owned bundles.
- Modify GUI provenance surfaces under `Sources/LungfishApp/App/`, `Sources/LungfishApp/Views/Inspector/`, and operations panel code paths.
  Open canonical sidecars, expose export actions, and display signature/checksum status.
- Create `Tests/LungfishWorkflowTests/ProvenanceEnvelopeTests.swift`
- Create `Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift`
- Create `Tests/LungfishWorkflowTests/ProvenanceFileHasherTests.swift`
- Create `Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift`
- Create `Tests/LungfishAppTests/ScientificFASTQProvenancePolicyTests.swift`
- Modify `Tests/LungfishWorkflowTests/ProvenanceTests.swift`
- Modify `Tests/LungfishWorkflowTests/ProvenanceSigningTests.swift`
- Create `Tests/LungfishCLITests/ProvenanceExportCommandTests.swift`
- Create `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`
- Modify representative command tests in `Tests/LungfishCLITests/`
- Modify `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
- Create `Tests/LungfishAppTests/ProvenanceRehydrationTests.swift`
- Create `Tests/LungfishAppTests/ProvenanceInteractionReadinessTests.swift`
- Create `Tests/LungfishIntegrationTests/ProvenanceRealFixtureE2ETests.swift`
- Create `Tests/LungfishXCUITests/ProvenanceXCUITests.swift`
- Create review artifacts under `docs/superpowers/reviews/` during review rounds.

---

### Task 1: Canonical Provenance Envelope

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift`
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`
- Create: `Tests/LungfishWorkflowTests/ProvenanceEnvelopeTests.swift`

- [ ] **Step 1: Write failing canonical encoding tests**

Create `Tests/LungfishWorkflowTests/ProvenanceEnvelopeTests.swift`:

```swift
import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Canonical Provenance Envelope")
struct ProvenanceEnvelopeTests {
    @Test("canonical envelope encodes documented top-level fields and compatibility aliases")
    func canonicalEncodingIncludesDocumentedFields() throws {
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "fastq.trim.fastp",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
            inputPath: "reads.fastq",
            outputPath: "trimmed.fastq"
        )

        let data = try ProvenanceJSON.encoder.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["workflowName"] as? String == "fastq.trim.fastp")
        #expect(json["toolName"] as? String == "fastp")
        #expect(json["toolVersion"] as? String == "0.24.1")
        #expect(json["argv"] as? [String] == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(json["reproducibleCommand"] as? String == "fastp -i reads.fastq -o trimmed.fastq")
        #expect(json["runtimeIdentity"] is [String: Any])
        #expect(json["files"] is [[String: Any]])
        #expect(json["output"] is [String: Any])
        #expect(json["outputs"] is [[String: Any]])
        #expect(json["wallTimeSeconds"] as? Double == 1.25)
        #expect(json["exitStatus"] as? Int == 0)

        let output = try #require(json["output"] as? [String: Any])
        #expect(output["checksumSHA256"] as? String == String(repeating: "b", count: 64))
        #expect(output["sha256"] as? String == String(repeating: "b", count: 64))
        #expect(output["fileSize"] as? Int == 22)
        #expect(output["sizeBytes"] as? Int == 22)
    }

    @Test("legacy WorkflowRun sidecar decodes through canonical reader")
    func legacyWorkflowRunDecodesThroughEnvelopeReader() throws {
        let legacy = WorkflowRun(
            name: "legacy fastq trim",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 103),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.23.4",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", sha256: String(repeating: "a", count: 64), sizeBytes: 12, format: .fastq)],
                    outputs: [FileRecord(path: "trimmed.fastq", sha256: String(repeating: "b", count: 64), sizeBytes: 22, format: .fastq, role: .output)],
                    exitCode: 0,
                    wallTime: 3
                )
            ]
        )

        let data = try ProvenanceJSON.encoder.encode(legacy)
        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "legacy fastq trim")
        #expect(decoded.toolName == "fastp")
        #expect(decoded.toolVersion == "0.23.4")
        #expect(decoded.argv == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(decoded.output?.path == "trimmed.fastq")
        #expect(decoded.outputs.first?.checksumSHA256 == String(repeating: "b", count: 64))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceEnvelopeTests
```

Expected: compilation fails with missing `ProvenanceEnvelope`, `ProvenanceEnvelopeReader`, and `ProvenanceJSON`.

- [ ] **Step 3: Add canonical models and JSON helpers**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift` with these public types:

```swift
public enum ProvenanceJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct ProvenanceEnvelope: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var workflowName: String
    public var workflowVersion: String
    public var toolName: String
    public var toolVersion: String
    public var tool: ProvenanceToolIdentity
    public var argv: [String]
    public var reproducibleCommand: String
    public var options: ProvenanceOptions
    public var runtimeIdentity: ProvenanceRuntimeIdentity
    public var files: [ProvenanceFileDescriptor]
    public var output: ProvenanceFileDescriptor?
    public var outputs: [ProvenanceFileDescriptor]
    public var steps: [ProvenanceStep]
    public var wallTimeSeconds: TimeInterval?
    public var exitStatus: Int32?
    public var stderr: String?
    public var signatures: [ProvenanceSignatureReference]
    public var legacyWorkflowRun: WorkflowRun?
}

public struct ProvenanceToolIdentity: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var kind: String?
}

public struct ProvenanceOptions: Codable, Sendable, Equatable {
    public var explicit: [String: ParameterValue]
    public var defaults: [String: ParameterValue]
    public var resolvedDefaults: [String: ParameterValue]
}

public struct ProvenanceRuntimeIdentity: Codable, Sendable, Equatable {
    public var appVersion: String
    public var executablePath: String?
    public var processIdentifier: Int32
    public var operatingSystemVersion: String
    public var architecture: String
    public var gitRevision: String?
    public var user: String?
    public var condaEnvironment: String?
    public var condaPrefix: String?
    public var pluginPack: String?
    public var containerImage: String?
    public var containerDigest: String?
}

public struct ProvenanceFileDescriptor: Codable, Sendable, Equatable {
    public var path: String
    public var checksumSHA256: String?
    public var fileSize: UInt64?
    public var format: FileFormat?
    public var role: FileRole
    public var originPath: String?
    public var sourceProvenancePath: String?

    enum CodingKeys: String, CodingKey {
        case path, checksumSHA256, fileSize, format, role, originPath, sourceProvenancePath
        case sha256, sizeBytes
    }
}

public struct ProvenanceStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var toolName: String
    public var toolVersion: String
    public var argv: [String]
    public var reproducibleCommand: String
    public var inputs: [ProvenanceFileDescriptor]
    public var outputs: [ProvenanceFileDescriptor]
    public var exitStatus: Int32?
    public var wallTimeSeconds: TimeInterval?
    public var stderr: String?
    public var dependsOn: [UUID]
    public var startedAt: Date?
    public var completedAt: Date?
}

public struct ProvenanceSignatureReference: Codable, Sendable, Equatable {
    public var provider: String
    public var provenanceSHA256: String
    public var signaturePath: String
    public var publicKeyPath: String
}
```

Add explicit public initializers, `CodingKeys`, and custom encode/decode for `ProvenanceFileDescriptor` so both canonical keys and legacy aliases round-trip.

- [ ] **Step 4: Add fixture and conversion helpers**

Add a `ProvenanceEnvelope.fixture(...)` test helper under `#if DEBUG` in the same file:

```swift
#if DEBUG
extension ProvenanceEnvelope {
    public static func fixture(
        workflowName: String,
        toolName: String,
        toolVersion: String,
        argv: [String],
        inputPath: String,
        outputPath: String
    ) -> ProvenanceEnvelope {
        let input = ProvenanceFileDescriptor(
            path: inputPath,
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            format: .fastq,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: outputPath,
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 22,
            format: .fastq,
            role: .output
        )
        return ProvenanceEnvelope(
            schemaVersion: currentSchemaVersion,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            workflowName: workflowName,
            workflowVersion: "0.4.0-alpha.13",
            toolName: toolName,
            toolVersion: toolVersion,
            tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: "cli"),
            argv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(explicit: [:], defaults: [:], resolvedDefaults: [:]),
            runtimeIdentity: .fixture(),
            files: [input],
            output: output,
            outputs: [output],
            steps: [],
            wallTimeSeconds: 1.25,
            exitStatus: 0,
            stderr: nil,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }
}
#endif
```

Add `WorkflowRun.canonicalEnvelope()` and `ProvenanceEnvelope.legacyWorkflowRun()` conversion methods in `ProvenanceRecord.swift`.

- [ ] **Step 5: Add canonical-first reader**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift`:

```swift
public enum ProvenanceEnvelopeReader {
    public static func load(from directory: URL) throws -> ProvenanceEnvelope? {
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> ProvenanceEnvelope {
        if let envelope = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data),
           envelope.schemaVersion >= 1 {
            return envelope
        }
        let legacy = try ProvenanceJSON.decoder.decode(WorkflowRun.self, from: data)
        return legacy.canonicalEnvelope()
    }
}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
swift test --filter ProvenanceEnvelopeTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift \
  Tests/LungfishWorkflowTests/ProvenanceEnvelopeTests.swift
git commit -m "feat: add canonical provenance envelope"
```

---

### Task 2: Full Checksums and File Descriptors

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift`
- Create: `Tests/LungfishWorkflowTests/ProvenanceFileHasherTests.swift`

- [ ] **Step 1: Write failing checksum tests**

Create `Tests/LungfishWorkflowTests/ProvenanceFileHasherTests.swift`:

```swift
import CryptoKit
import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Provenance File Hashing")
struct ProvenanceFileHasherTests {
    @Test("canonical file descriptor records full SHA-256 and byte size")
    func canonicalDescriptorRecordsFullDigestAndSize() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("reads.fastq")
        let bytes = Data("@r1\nACGT\n+\nIIII\n".utf8)
        try bytes.write(to: fileURL)

        let descriptor = try ProvenanceFileDescriptor.file(
            url: fileURL,
            format: .fastq,
            role: .input
        )

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(descriptor.checksumSHA256 == expected)
        #expect(descriptor.fileSize == UInt64(bytes.count))
        #expect(descriptor.path == fileURL.path)
        #expect(descriptor.checksumSHA256?.hasPrefix("partial:") == false)
    }

    @Test("directory descriptor uses manifest entries instead of directory digest")
    func directoryDescriptorUsesManifestEntries() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.txt"))
        try Data("bb".utf8).write(to: directory.appendingPathComponent("b.txt"))

        let manifest = try ProvenanceFileHasher.directoryManifest(for: directory)

        #expect(manifest.files.map(\.path).sorted().map { URL(fileURLWithPath: $0).lastPathComponent } == ["a.txt", "b.txt"])
        #expect(manifest.files.allSatisfy { $0.checksumSHA256?.count == 64 })
        #expect(manifest.files.map(\.fileSize).sorted { ($0 ?? 0) < ($1 ?? 0) } == [1, 2])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceFileHasherTests
```

Expected: compilation fails because `ProvenanceFileHasher`, `ProvenanceDirectoryManifest`, and `ProvenanceFileDescriptor.file(...)` do not exist.

- [ ] **Step 3: Implement streaming full SHA-256**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift`:

```swift
import CryptoKit
import Foundation

public struct ProvenanceDirectoryManifest: Codable, Sendable, Equatable {
    public var rootPath: String
    public var files: [ProvenanceFileDescriptor]
}

public enum ProvenanceFileHasher {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? UInt64 { return size }
        if let size = attributes[.size] as? NSNumber { return size.uint64Value }
        throw ProvenanceError.exportFailed("Could not determine file size for \(url.path)")
    }

    public static func directoryManifest(for url: URL) throws -> ProvenanceDirectoryManifest {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let files = try contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
            .map { try ProvenanceFileDescriptor.file(url: $0, format: nil, role: .output) }
        return ProvenanceDirectoryManifest(rootPath: url.path, files: files)
    }
}
```

Add `ProvenanceFileDescriptor.file(url:format:role:originPath:sourceProvenancePath:)` in `ProvenanceEnvelope.swift`, using `ProvenanceFileHasher.sha256`.

- [ ] **Step 4: Preserve legacy partial digest reader but stop emitting canonical partial digests**

Modify `ProvenanceRecorder.sha256(of:)`:

```swift
public static func sha256(of url: URL) -> String? {
    try? ProvenanceFileHasher.sha256(of: url)
}
```

Keep the method name to avoid breaking existing callers, but route new and old file-record helpers through full streaming SHA-256.

- [ ] **Step 5: Run focused and existing provenance tests**

Run:

```bash
swift test --filter ProvenanceFileHasherTests
swift test --filter ProvenanceRecordingTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift \
  Tests/LungfishWorkflowTests/ProvenanceFileHasherTests.swift
git commit -m "feat: record full provenance file checksums"
```

---

### Task 3: Provenance Builder and Writer

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceSigning.swift`
- Create: `Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift`
- Modify: `Tests/LungfishWorkflowTests/ProvenanceSigningTests.swift`

- [ ] **Step 1: Write failing builder tests**

Create `Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Provenance Builder")
struct ProvenanceBuilderTests {
    @Test("builder writes canonical sidecar with command options files and signature")
    func builderWritesCanonicalSignedSidecar() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("reads.fastq")
        let outputURL = directory.appendingPathComponent("trimmed.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "@r1\nCG\n+\nII\n".write(to: outputURL, atomically: true, encoding: .utf8)

        let started = Date(timeIntervalSince1970: 10)
        let ended = Date(timeIntervalSince1970: 12.5)
        let envelope = try await ProvenanceRunBuilder(
            workflowName: "fastq.trim.fastp",
            workflowVersion: "0.4.0-alpha.13",
            toolName: "fastp",
            toolVersion: "0.24.1"
        )
        .argv(["fastp", "-i", inputURL.path, "-o", outputURL.path, "--cut_right"])
        .options(
            explicit: ["threshold": .integer(20)],
            defaults: ["window": .integer(4)],
            resolved: ["threshold": .integer(20), "window": .integer(4)]
        )
        .input(inputURL, format: .fastq, role: .input)
        .output(outputURL, format: .fastq, role: .output)
        .runtime(.fixture(executablePath: "/tmp/fastp", condaEnvironment: "fastp"))
        .complete(exitStatus: 0, stderr: "", startedAt: started, endedAt: ended)

        let writer = ProvenanceWriter(signingProvider: LocalProvenanceSigningProvider(privateKey: "builder-test"))
        let sidecarURL = try writer.write(envelope, to: directory)

        let decoded = try #require(ProvenanceEnvelopeReader.load(from: directory))
        #expect(decoded.workflowName == "fastq.trim.fastp")
        #expect(decoded.argv.first == "fastp")
        #expect(decoded.reproducibleCommand.contains("--cut_right"))
        #expect(decoded.options.resolvedDefaults["window"] == .integer(4))
        #expect(decoded.output?.path == outputURL.path)
        #expect(decoded.output?.checksumSHA256?.count == 64)
        #expect(decoded.exitStatus == 0)
        #expect(decoded.wallTimeSeconds == 2.5)
        #expect(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: sidecarURL).path))
    }

    @Test("builder rejects successful scientific output without argv")
    func builderRejectsMissingArgv() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.fastq")
        try "@r1\nAC\n+\nII\n".write(to: outputURL, atomically: true, encoding: .utf8)

        await #expect(throws: ProvenanceBuilderError.self) {
            _ = try await ProvenanceRunBuilder(
                workflowName: "fastq.test",
                workflowVersion: "0.4.0-alpha.13",
                toolName: "lungfish-cli",
                toolVersion: "0.4.0-alpha.13"
            )
            .output(outputURL, format: .fastq, role: .output)
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceBuilderTests
```

Expected: compilation fails because `ProvenanceRunBuilder`, `ProvenanceWriter`, and `ProvenanceBuilderError` do not exist.

- [ ] **Step 3: Implement builder validation**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift` with:

```swift
public enum ProvenanceBuilderError: Error, LocalizedError, Sendable, Equatable {
    case missingArgv(String)
    case missingOutput(String)
    case missingRuntimeIdentity(String)
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgv(let workflow): return "Provenance for \(workflow) is missing exact argv."
        case .missingOutput(let workflow): return "Provenance for \(workflow) has no output descriptors."
        case .missingRuntimeIdentity(let workflow): return "Provenance for \(workflow) is missing runtime identity."
        case .unreadableFile(let path): return "Provenance file metadata could not be read for \(path)."
        }
    }
}

public struct ProvenanceRunBuilder: Sendable {
    public init(workflowName: String, workflowVersion: String, toolName: String, toolVersion: String)
    public func argv(_ argv: [String]) -> ProvenanceRunBuilder
    public func reproducibleCommand(_ command: String) -> ProvenanceRunBuilder
    public func options(
        explicit: [String: ParameterValue],
        defaults: [String: ParameterValue],
        resolved: [String: ParameterValue]
    ) -> ProvenanceRunBuilder
    public func input(_ url: URL, format: FileFormat?, role: FileRole) throws -> ProvenanceRunBuilder
    public func output(_ url: URL, format: FileFormat?, role: FileRole) throws -> ProvenanceRunBuilder
    public func runtime(_ runtime: ProvenanceRuntimeIdentity) -> ProvenanceRunBuilder
    public func step(_ step: ProvenanceStep) -> ProvenanceRunBuilder
    public func complete(exitStatus: Int32, stderr: String? = nil, startedAt: Date, endedAt: Date) throws -> ProvenanceEnvelope
}
```

The `complete` method must reject `exitStatus == 0` with empty `argv`, empty `outputs`, or missing runtime identity.

- [ ] **Step 4: Implement writer and signing references**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`:

```swift
public struct ProvenanceWriter: Sendable {
    private let signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }

    @discardableResult
    public func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = try ProvenanceJSON.encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
        if let artifact = try signingProvider?.sign(provenanceURL: url) {
            try attachSignatureMetadata(artifact, to: url)
        }
        return url
    }

    private func attachSignatureMetadata(_ artifact: ProvenanceSignatureArtifact, to provenanceURL: URL) throws {
        var envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: provenanceURL))
        let result = try ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)
        envelope.signatures = [
            ProvenanceSignatureReference(
                provider: result.provider,
                provenanceSHA256: result.provenanceSHA256,
                signaturePath: artifact.signatureURL.path,
                publicKeyPath: artifact.publicKeyURL.path
            )
        ]
        try ProvenanceJSON.encoder.encode(envelope).write(to: provenanceURL, options: .atomic)
        _ = try signingProvider?.sign(provenanceURL: provenanceURL)
    }
}
```

If double-signing changes the digest after metadata insertion, verify the final sidecar in the test and store the final `provenanceSHA256`.

- [ ] **Step 5: Run builder and signing tests**

Run:

```bash
swift test --filter ProvenanceBuilderTests
swift test --filter ProvenanceSigningTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceSigning.swift \
  Tests/LungfishWorkflowTests/ProvenanceBuilderTests.swift \
  Tests/LungfishWorkflowTests/ProvenanceSigningTests.swift
git commit -m "feat: add provenance builder and writer"
```

---

### Task 4: Recorder Compatibility Migration

**Files:**
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift`
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`
- Modify: `Tests/LungfishWorkflowTests/ProvenanceTests.swift`

- [ ] **Step 1: Write failing recorder compatibility assertions**

Add to `ProvenancePersistenceTests` in `Tests/LungfishWorkflowTests/ProvenanceTests.swift`:

```swift
@Test("Recorder save writes canonical envelope while legacy load still works")
func testRecorderSaveWritesCanonicalEnvelopeAndLegacyLoadStillWorks() async throws {
    let recorder = ProvenanceRecorder()
    let runID = await recorder.beginRun(name: "Canonical Recorder")
    await recorder.recordStep(
        runID: runID,
        toolName: "seqkit",
        toolVersion: "2.10.0",
        command: ["seqkit", "seq", "reads.fastq"],
        inputs: [FileRecord(path: "reads.fastq", sha256: String(repeating: "a", count: 64), sizeBytes: 20, format: .fastq)],
        outputs: [FileRecord(path: "out.fastq", sha256: String(repeating: "b", count: 64), sizeBytes: 12, format: .fastq, role: .output)],
        exitCode: 0,
        wallTime: 0.25
    )
    await recorder.completeRun(runID, status: .completed)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recorder-canonical-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await recorder.save(runID: runID, to: directory)

    let envelope = try #require(ProvenanceEnvelopeReader.load(from: directory))
    #expect(envelope.schemaVersion == 1)
    #expect(envelope.workflowName == "Canonical Recorder")
    #expect(envelope.toolName == "seqkit")
    #expect(envelope.output?.checksumSHA256 == String(repeating: "b", count: 64))

    let legacy = ProvenanceRecorder.load(from: directory)
    #expect(legacy?.name == "Canonical Recorder")
    #expect(legacy?.steps.first?.toolName == "seqkit")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter ProvenancePersistenceTests/testRecorderSaveWritesCanonicalEnvelopeAndLegacyLoadStillWorks
```

Expected: failure because recorder still writes legacy-only JSON or `ProvenanceRecorder.load` cannot decode canonical JSON.

- [ ] **Step 3: Save canonical envelope from recorder**

Modify `ProvenanceRecorder.save(runID:to:)`:

```swift
public func save(runID: UUID, to directory: URL) throws {
    guard let run = runs[runID] else {
        throw ProvenanceError.runNotFound(runID)
    }
    let envelope = run.canonicalEnvelope()
    _ = try ProvenanceWriter(signingProvider: signingProvider).write(envelope, to: directory)
    logger.info("Provenance: saved canonical run \(runID) to \(directory.path)")
}
```

Add `ProvenanceRecorder.loadEnvelope(from:)`:

```swift
public static func loadEnvelope(from directory: URL) -> ProvenanceEnvelope? {
    try? ProvenanceEnvelopeReader.load(from: directory)
}
```

Modify `ProvenanceRecorder.load(from:)` to decode canonical first and return `legacyWorkflowRun()`:

```swift
public static func load(from directory: URL) -> WorkflowRun? {
    if let envelope = try? ProvenanceEnvelopeReader.load(from: directory) {
        return envelope?.legacyWorkflowRun()
    }
    return nil
}
```

- [ ] **Step 4: Run compatibility tests**

Run:

```bash
swift test --filter ProvenancePersistenceTests
swift test --filter ProvenanceRecordingTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift \
  Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift \
  Tests/LungfishWorkflowTests/ProvenanceTests.swift
git commit -m "feat: save canonical provenance from recorder"
```

---

### Task 5: Provenance Rehydration for GUI-Owned Bundles

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ProvenanceRehydrator.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`
- Modify: `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`
- Create: `Tests/LungfishAppTests/ProvenanceRehydrationTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`

- [ ] **Step 1: Write failing rehydration tests**

Create `Tests/LungfishAppTests/ProvenanceRehydrationTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceRehydrationTests: XCTestCase {
    func testRehydratorRewritesCLIOutputPathToFinalBundlePayload() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let bundle = root.appendingPathComponent("final.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let stagedFASTQ = staging.appendingPathComponent("reads.trimmed.fastq")
        let finalFASTQ = bundle.appendingPathComponent("reads.fastq")
        try "@r1\nAC\n+\nII\n".write(to: stagedFASTQ, atomically: true, encoding: .utf8)
        try "@r1\nAC\n+\nII\n".write(to: finalFASTQ, atomically: true, encoding: .utf8)

        let cliEnvelope = try await ProvenanceRunBuilder(
            workflowName: "fastq.length-filter",
            workflowVersion: "0.4.0-alpha.13",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0-alpha.13"
        )
        .argv(["lungfish", "fastq", "length-filter", stagedFASTQ.path, "-o", stagedFASTQ.path])
        .output(stagedFASTQ, format: .fastq, role: .output)
        .runtime(.fixture())
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        _ = try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, to: staging)

        let rehydrated = try ProvenanceRehydrator.rehydrate(
            sourceDirectory: staging,
            finalDirectory: bundle,
            pathMap: [stagedFASTQ.path: finalFASTQ.path]
        )

        #expect(rehydrated.output?.path == finalFASTQ.path)
        #expect(rehydrated.output?.originPath == stagedFASTQ.path)
        #expect(rehydrated.output?.checksumSHA256?.count == 64)
        #expect(rehydrated.output?.sourceProvenancePath?.hasSuffix(".lungfish-provenance.json") == true)
    }

    func testRehydratorRejectsMissingScientificCLIProvenance() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let bundle = root.appendingPathComponent("final.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ProvenanceRehydrator.rehydrate(
            sourceDirectory: staging,
            finalDirectory: bundle,
            pathMap: [:]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing"))
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-rehydrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceRehydrationTests
```

Expected: compilation fails because `ProvenanceRehydrator` does not exist.

- [ ] **Step 3: Implement rehydrator**

Create `Sources/LungfishWorkflow/Provenance/ProvenanceRehydrator.swift`:

```swift
public enum ProvenanceRehydrationError: Error, LocalizedError, Sendable, Equatable {
    case missingSourceProvenance(String)
    case outputPathNotMapped(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceProvenance(let path): return "CLI output is missing provenance: \(path)"
        case .outputPathNotMapped(let path): return "No final bundle path is mapped for provenance output: \(path)"
        }
    }
}

public enum ProvenanceRehydrator {
    @discardableResult
    public static func rehydrate(
        sourceDirectory: URL,
        finalDirectory: URL,
        pathMap: [String: String]
    ) throws -> ProvenanceEnvelope {
        guard let source = try ProvenanceEnvelopeReader.load(from: sourceDirectory) else {
            throw ProvenanceRehydrationError.missingSourceProvenance(sourceDirectory.path)
        }
        var envelope = source
        envelope.files = try rewrite(envelope.files, pathMap: pathMap, sourceDirectory: sourceDirectory)
        envelope.outputs = try rewrite(envelope.outputs, pathMap: pathMap, sourceDirectory: sourceDirectory)
        envelope.output = try envelope.output.map { try rewrite($0, pathMap: pathMap, sourceDirectory: sourceDirectory) }
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: finalDirectory)
        return envelope
    }

    private static func rewrite(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String],
        sourceDirectory: URL
    ) throws -> ProvenanceFileDescriptor {
        guard let finalPath = pathMap[descriptor.path] else { return descriptor }
        var copy = descriptor
        copy.originPath = descriptor.path
        copy.path = finalPath
        copy.sourceProvenancePath = sourceDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
        copy.checksumSHA256 = try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: finalPath))
        copy.fileSize = try ProvenanceFileHasher.fileSize(of: URL(fileURLWithPath: finalPath))
        return copy
    }
}
```

Add array rewrite helpers.

- [ ] **Step 4: Wire FASTQ GUI output writer to rehydrate or fail**

Modify `AppFASTQOutputBundleWriter.importFASTQOutput(...)` in `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`:

```swift
if let sourceRun = try ProvenanceEnvelopeReader.load(from: sourceURL.deletingLastPathComponent()) {
    _ = try ProvenanceRehydrator.rehydrate(
        sourceDirectory: sourceURL.deletingLastPathComponent(),
        finalDirectory: bundleURL,
        pathMap: [sourceURL.path: bundledFASTQ.path]
    )
} else if originalRequest.requiresScientificProvenance {
    throw FASTQOperationExecutionError.missingProvenance(sourceURL.deletingLastPathComponent().path)
} else {
    try await writeFallbackProvenanceWithBuilder(...)
}
```

Replace `writeFallbackProvenanceWithBuilder(...)` with a builder-backed helper that writes canonical sidecars for app-native fallback operations.

- [ ] **Step 5: Run app provenance tests**

Run:

```bash
swift test --filter ProvenanceRehydrationTests
swift test --filter FASTQOperationExecutionServiceTests/testAppFASTQOutputBundleWriterPreservesCLIProvenanceForDerivativeBundles
swift test --filter FASTQOperationExecutionServiceTests/testAppFASTQOutputBundleWriterCreatesFallbackProvenanceForDerivativeBundles
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceRehydrator.swift \
  Sources/LungfishApp/Services/FASTQOperationExecutionService.swift \
  Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift \
  Tests/LungfishAppTests/ProvenanceRehydrationTests.swift \
  Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift
git commit -m "feat: rehydrate cli provenance into gui bundles"
```

---

### Task 6: Provenance Export and Report CLI

**Files:**
- Modify: `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift`
- Modify: `Sources/LungfishCLI/Commands/ProvenanceCommand.swift`
- Create: `Tests/LungfishCLITests/ProvenanceExportCommandTests.swift`
- Modify: `Tests/LungfishWorkflowTests/ProvenanceTests.swift`

- [ ] **Step 1: Write failing export command tests**

Create `Tests/LungfishCLITests/ProvenanceExportCommandTests.swift`:

```swift
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ProvenanceExportCommandTests: XCTestCase {
    func testProvenanceExportParsesThroughTopLevelCommand() throws {
        let names = ProvenanceCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("export"))

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            "/tmp/result",
            "--format", "shell",
            "--output", "/tmp/provenance-export"
        ])
        XCTAssertEqual(command.format, "shell")
        XCTAssertEqual(command.output, "/tmp/provenance-export")
    }

    func testProvenanceExportShellWritesRunScriptAndCopiedSidecar() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("result", isDirectory: true)
        let export = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)

        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "variants.call.ivar",
            toolName: "ivar",
            toolVersion: "1.4.4",
            argv: ["ivar", "variants", "-p", "variants"],
            inputPath: "alignment.bam",
            outputPath: "variants.vcf.gz"
        )
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: result)

        let command = try ProvenanceCommand.ExportSubcommand.parse([
            result.path,
            "--format", "shell",
            "--output", export.path
        ])
        try await command.run()

        let runScript = export.appendingPathComponent("run.sh")
        let copiedSidecar = export.appendingPathComponent("provenance/.lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runScript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSidecar.path))
        let script = try String(contentsOf: runScript, encoding: .utf8)
        XCTAssertTrue(script.contains("ivar variants -p variants"), script)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceExportCommandTests
```

Expected: compilation fails because `ExportSubcommand` does not exist or runtime fails because no export bundle is written.

- [ ] **Step 3: Add canonical export bundle API**

Extend `ProvenanceExporter`:

```swift
public struct ProvenanceExportBundle: Sendable, Equatable {
    public var rootURL: URL
    public var primaryArtifactURL: URL
    public var copiedSidecarURLs: [URL]
}

public func exportBundle(
    _ envelope: ProvenanceEnvelope,
    format: ProvenanceExportFormat,
    to outputDirectory: URL,
    sourceSidecarURL: URL?
) throws -> ProvenanceExportBundle
```

Write:

- `run.sh` for `.shell`
- `main.nf`, `nextflow.config`, and `containers/manifest.json` for `.nextflow`
- `Snakefile` and `config.yaml` for `.snakemake`
- `methods.md` for `.methods`
- `provenance.json` for `.json`
- `provenance/` containing copied original sidecars

Make `.methods` start with:

```markdown
<!-- This is an automatically-generated draft. Read it before submitting. -->
```

- [ ] **Step 4: Add CLI export subcommand**

Modify `ProvenanceCommand.configuration.subcommands` to include `ExportSubcommand.self`.

Add:

```swift
struct ExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export Lungfish provenance as Shell, Nextflow, Snakemake, Methods, or JSON"
    )

    @Argument(help: "Provenance sidecar file, bundle, or output directory")
    var input: String

    @Option(help: "Export format: shell, nextflow, snakemake, methods, json")
    var format: String

    @Option(name: .shortAndLong, help: "Output directory for exported provenance bundle")
    var output: String

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let sidecarURL = try ProvenanceCommand.resolveProvenanceURL(inputURL)
        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecarURL))
        let exportFormat = try ProvenanceExportFormat.cliValue(format)
        _ = try ProvenanceExporter().exportBundle(
            envelope,
            format: exportFormat,
            to: URL(fileURLWithPath: output),
            sourceSidecarURL: sidecarURL
        )
    }
}
```

Move `resolveProvenanceURL` from nested `VerifySubcommand` to a shared static helper on `ProvenanceCommand`.

- [ ] **Step 5: Run export tests**

Run:

```bash
swift test --filter ProvenanceExportCommandTests
swift test --filter ProvenanceVerifyCommandTests
swift test --filter ProvenanceExport
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift \
  Sources/LungfishCLI/Commands/ProvenanceCommand.swift \
  Tests/LungfishCLITests/ProvenanceExportCommandTests.swift \
  Tests/LungfishWorkflowTests/ProvenanceTests.swift
git commit -m "feat: export canonical provenance reports"
```

---

### Task 7: Scientific Provenance Policy Gates

**Files:**
- Create: `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`
- Create: `Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift`
- Create: `Tests/LungfishAppTests/ScientificFASTQProvenancePolicyTests.swift`
- Create: `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishWorkflow/Constraints/BuiltInTools.swift`

- [ ] **Step 1: Write failing policy coverage tests**

Create `Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift`:

```swift
import Testing
@testable import LungfishWorkflow
@testable import LungfishIO

@Suite("Scientific Provenance Policy")
struct ScientificProvenancePolicyTests {
    @Test("native tools all have provenance policy entries")
    func nativeToolsHavePolicyEntries() {
        let missing = NativeTool.allCases.filter { ScientificProvenancePolicy.nativeTool($0) == nil }
        #expect(missing.isEmpty, "Missing native tool provenance policies: \(missing.map(\.rawValue).joined(separator: \", \"))")
    }

    @Test("MSA action registry validates provenance contracts")
    func msaActionsValidateProvenanceContracts() {
        #expect(MultipleSequenceAlignmentActionRegistry.validate().isEmpty)
    }
}
```

Create `Tests/LungfishAppTests/ScientificFASTQProvenancePolicyTests.swift`:

```swift
import XCTest
@testable import LungfishApp

final class ScientificFASTQProvenancePolicyTests: XCTestCase {
    func testFASTQOperationToolsThatChangeDataRequireProvenance() {
        let missing = FASTQOperationToolID.allCases.filter { tool in
            tool.createsOrModifiesScientificData && tool.requiresProvenance == false
        }

        XCTAssertTrue(
            missing.isEmpty,
            "FASTQ tools missing provenance: \(missing.map(\.rawValue).joined(separator: \", \"))"
        )
    }
}
```

Create `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`:

```swift
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ScientificCLIProvenanceCoverageTests: XCTestCase {
    func testScientificTopLevelCommandsHavePolicyEntries() {
        let scientificCommands = [
            "convert", "analyze", "translate", "search", "universal-search", "extract",
            "fastq", "workflow", "fetch", "bundle", "project", "blast", "esviritu",
            "taxtriage", "align", "msa", "tree", "assemble", "orient", "map", "import",
            "import-fastq", "ops", "bam", "variants", "gatk", "nao-mgs", "freyja", "nvd",
            "czid", "metadata", "build-db", "markdup", "primer"
        ]

        let missing = scientificCommands.filter { ScientificProvenancePolicy.cliCommand($0) == nil }
        XCTAssertTrue(missing.isEmpty, "Missing CLI provenance policies: \(missing.joined(separator: \", \"))")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ScientificProvenancePolicyTests
swift test --filter ScientificFASTQProvenancePolicyTests
swift test --filter ScientificCLIProvenanceCoverageTests
```

Expected: compilation fails because `ScientificProvenancePolicy`, `createsOrModifiesScientificData`, and `requiresProvenance` are not available for all referenced surfaces.

- [ ] **Step 3: Implement policy model**

Create `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`:

```swift
public struct ProvenancePolicyEntry: Sendable, Equatable {
    public var id: String
    public var createsOrModifiesScientificData: Bool
    public var requiresProvenance: Bool
    public var writer: String
}

public enum ScientificProvenancePolicy {
    public static func nativeTool(_ tool: NativeTool) -> ProvenancePolicyEntry? {
        ProvenancePolicyEntry(
            id: "native.\(tool.rawValue)",
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            writer: "ProvenanceRunBuilder"
        )
    }

    public static func cliCommand(_ commandName: String) -> ProvenancePolicyEntry? {
        cliCommandPolicies[commandName]
    }

    public static let cliCommandPolicies: [String: ProvenancePolicyEntry] = [
        "convert": required("cli.convert"),
        "analyze": required("cli.analyze"),
        "translate": required("cli.translate"),
        "search": required("cli.search"),
        "universal-search": required("cli.universal-search"),
        "extract": required("cli.extract"),
        "fastq": required("cli.fastq"),
        "workflow": required("cli.workflow"),
        "fetch": required("cli.fetch"),
        "bundle": required("cli.bundle"),
        "project": required("cli.project"),
        "blast": required("cli.blast"),
        "esviritu": required("cli.esviritu"),
        "taxtriage": required("cli.taxtriage"),
        "align": required("cli.align"),
        "msa": required("cli.msa"),
        "tree": required("cli.tree"),
        "assemble": required("cli.assemble"),
        "orient": required("cli.orient"),
        "map": required("cli.map"),
        "import": required("cli.import"),
        "import-fastq": required("cli.import-fastq"),
        "ops": required("cli.ops"),
        "bam": required("cli.bam"),
        "variants": required("cli.variants"),
        "gatk": required("cli.gatk"),
        "nao-mgs": required("cli.nao-mgs"),
        "freyja": required("cli.freyja"),
        "nvd": required("cli.nvd"),
        "czid": required("cli.czid"),
        "metadata": required("cli.metadata"),
        "build-db": required("cli.build-db"),
        "markdup": required("cli.markdup"),
        "primer": required("cli.primer"),
    ]

    private static func required(_ id: String) -> ProvenancePolicyEntry {
        ProvenancePolicyEntry(
            id: id,
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            writer: "CLIProvenanceSupport"
        )
    }
}
```

- [ ] **Step 4: Add FASTQ operation provenance flags**

In `FASTQOperationToolID`, add:

```swift
var createsOrModifiesScientificData: Bool {
    switch self {
    case .refreshQCSummary:
        return false
    default:
        return true
    }
}

var requiresProvenance: Bool {
    createsOrModifiesScientificData
}
```

- [ ] **Step 5: Run policy tests**

Run:

```bash
swift test --filter ScientificProvenancePolicyTests
swift test --filter ScientificFASTQProvenancePolicyTests
swift test --filter ScientificCLIProvenanceCoverageTests
swift test --filter MultipleSequenceAlignmentActionRegistryTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift \
  Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift \
  Sources/LungfishWorkflow/Constraints/BuiltInTools.swift \
  Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift \
  Tests/LungfishAppTests/ScientificFASTQProvenancePolicyTests.swift \
  Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift
git commit -m "feat: gate scientific provenance coverage"
```

---

### Task 8: CLI Builder Integration and Command Migration

**Files:**
- Modify: `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
- Modify: scientific command files under `Sources/LungfishCLI/Commands/`
- Modify: representative tests under `Tests/LungfishCLITests/`

- [ ] **Step 1: Write failing helper test for canonical CLI output**

Add to `Tests/LungfishCLITests/ProvenanceExportCommandTests.swift`:

```swift
func testCLIRecordSingleStepRunWritesCanonicalFields() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("reads.fastq")
    let output = root.appendingPathComponent("trimmed.fastq")
    try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
    try "@r1\nCG\n+\nII\n".write(to: output, atomically: true, encoding: .utf8)

    try await CLIProvenanceSupport.recordSingleStepRun(
        name: "lungfish fastq trim",
        parameters: ["threshold": .integer(20)],
        toolName: "fastp",
        toolVersion: "0.24.1",
        command: ["fastp", "-i", input.path, "-o", output.path],
        inputs: [ProvenanceRecorder.fileRecord(url: input, format: .fastq, role: .input)],
        outputs: [ProvenanceRecorder.fileRecord(url: output, format: .fastq, role: .output)],
        exitCode: 0,
        wallTime: 0.5,
        stderr: nil,
        status: .completed,
        outputDirectory: root
    )

    let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: root))
    XCTAssertEqual(envelope.workflowName, "lungfish fastq trim")
    XCTAssertEqual(envelope.argv, ["fastp", "-i", input.path, "-o", output.path])
    XCTAssertEqual(envelope.options.resolvedDefaults["threshold"], .integer(20))
    XCTAssertEqual(envelope.output?.path, output.path)
}
```

- [ ] **Step 2: Run test to verify current helper fails canonical assertions**

Run:

```bash
swift test --filter ProvenanceExportCommandTests/testCLIRecordSingleStepRunWritesCanonicalFields
```

Expected: fail until `CLIProvenanceSupport` writes canonical envelopes.

- [ ] **Step 3: Make CLI helper builder-backed**

Modify `CLIProvenanceSupport.recordSingleStepRun(...)`:

```swift
let started = Date().addingTimeInterval(-wallTime)
let ended = Date()
let envelope = try await ProvenanceRunBuilder(
    workflowName: name,
    workflowVersion: LungfishCLI.configuration.version,
    toolName: toolName,
    toolVersion: toolVersion
)
.argv(command)
.options(explicit: parameters, defaults: [:], resolved: parameters)
.inputs(inputs.map(ProvenanceFileDescriptor.init(fileRecord:)))
.outputs(outputs.map(ProvenanceFileDescriptor.init(fileRecord:)))
.runtime(.current(executablePath: nil, condaEnvironment: nil))
.complete(exitStatus: exitCode, stderr: stderr, startedAt: started, endedAt: ended)
_ = try ProvenanceWriter().write(envelope, to: outputDirectory)
```

Add `ProvenanceRunBuilder.inputs(_:)` and `outputs(_:)` convenience methods if needed.

- [ ] **Step 4: Migrate CLI command families through existing helper**

For commands already calling `CLIProvenanceSupport.recordSingleStepRun`, preserve the call sites and add explicit defaults into `parameters`. For commands writing `WorkflowRun` manually, replace the manual writer with builder calls.

Command families to touch in this pass:

- `FastqCommand.swift` and related `Fastq*Subcommand.swift`
- `ImportCommand.swift`, `ImportFastqCommand.swift`, `ImportCzIdCommand.swift`, `ImportMSATreeCommand.swift`
- `BundleCommand.swift`
- `FetchCommand.swift`
- `WorkflowCommand.swift`
- `VariantsCommand.swift`
- `MapCommand.swift`, `BAMCommand.swift`, `BAMPrimerTrimCommand.swift`, `BAMAdoptMappingSubcommand.swift`
- `MSACommand.swift`, `TreeCommand.swift`
- `FreyjaCommand.swift`, `GATKCommand.swift`, `NaoMgsCommand.swift`, `CzIdCommand.swift`
- `BuildDbCommand.swift`, `ExtractCommand.swift`, `ExtractContigsCommand.swift`, `ExtractReadsCommand.swift`
- `CondaCommand.swift`, `CondaExtractCommand.swift`, `CondaPacksCommand.swift`

Use this pattern at each migrated site:

```swift
try await CLIProvenanceSupport.recordSingleStepRun(
    name: "lungfish \(Self.configuration.commandName)",
    parameters: resolvedProvenanceParameters(),
    toolName: toolName,
    toolVersion: toolVersion,
    command: exactArgv,
    inputs: inputRecords,
    outputs: outputRecords,
    exitCode: result.exitCode,
    wallTime: completed.timeIntervalSince(started),
    stderr: result.stderr.nilIfEmpty,
    status: result.isSuccess ? .completed : .failed,
    outputDirectory: outputDirectory
)
```

- [ ] **Step 5: Add representative command assertions**

Update representative tests:

- `Tests/LungfishCLITests/ImportFastqCommandTests.swift`: generated `.lungfishfastq` provenance has canonical fields and resolved defaults.
- `Tests/LungfishCLITests/BundleCreateProvenanceTests.swift`: reference bundle creation has canonical `output` and `outputs`.
- `Tests/LungfishCLITests/FetchNCBIProvenanceTests.swift`: fetched FASTA sidecar records network argv, URL, checksum, and size.
- `Tests/LungfishCLITests/FreyjaCommandTests.swift`: Freyja output sidecar records tool version and conda runtime.
- `Tests/LungfishCLITests/VariantsCommandTests.swift`: variant import/call output has canonical VCF output descriptor.

Example assertion block:

```swift
let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDirectory))
XCTAssertEqual(envelope.schemaVersion, 1)
XCTAssertFalse(envelope.argv.isEmpty)
XCTAssertNotNil(envelope.options.resolvedDefaults["threads"])
XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256?.count == 64 })
XCTAssertEqual(envelope.exitStatus, 0)
```

- [ ] **Step 6: Run CLI focused suite**

Run:

```bash
swift test --filter ProvenanceExportCommandTests/testCLIRecordSingleStepRunWritesCanonicalFields
swift test --filter ImportFastqCommandTests
swift test --filter BundleCreateProvenanceTests
swift test --filter FetchNCBIProvenanceTests
swift test --filter FreyjaCommandTests
swift test --filter VariantsCommandTests
swift test --filter ScientificCLIProvenanceCoverageTests
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCLI/Support/CLIProvenanceSupport.swift \
  Sources/LungfishCLI/Commands \
  Tests/LungfishCLITests
git commit -m "feat: route cli provenance through builder"
```

---

### Task 9: App Workflow and Native Pipeline Migration

**Files:**
- Modify: `Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Primers/BAMPrimerTrimPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Metagenomics/TaxonomyExtractionPipeline.swift`
- Modify: `Sources/LungfishWorkflow/MSA/MSAReferenceBundleBuilder.swift`
- Modify: `Sources/LungfishIO/Bundles/MultipleSequenceAlignmentBundle.swift`
- Modify: `Sources/LungfishIO/Bundles/PhylogeneticTreeBundle.swift`
- Modify: app import/export services under `Sources/LungfishApp/Services/`
- Modify: corresponding tests under `Tests/LungfishWorkflowTests/`, `Tests/LungfishIOTests/`, and `Tests/LungfishAppTests/`

- [ ] **Step 1: Write failing canonical assertions in representative app/native tests**

Add canonical envelope assertions to:

- `Tests/LungfishWorkflowTests/Mapping/MappingProvenanceTests.swift`
- `Tests/LungfishWorkflowTests/Primers/BAMPrimerTrimProvenanceTests.swift`
- `Tests/LungfishAppTests/WorkflowBuilderRunServiceTests.swift`
- `Tests/LungfishIOTests/MultipleSequenceAlignmentBundleTests.swift`
- `Tests/LungfishIOTests/PhylogeneticTreeBundleTests.swift`

Use this helper in each test file:

```swift
private func assertCanonicalProvenance(
    in directory: URL,
    expectedWorkflowPrefix: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> ProvenanceEnvelope {
    let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: directory), file: file, line: line)
    XCTAssertEqual(envelope.schemaVersion, 1, file: file, line: line)
    XCTAssertTrue(envelope.workflowName.hasPrefix(expectedWorkflowPrefix), envelope.workflowName, file: file, line: line)
    XCTAssertFalse(envelope.argv.isEmpty, file: file, line: line)
    XCTAssertNotNil(envelope.runtimeIdentity.operatingSystemVersion, file: file, line: line)
    XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256?.count == 64 }, file: file, line: line)
    XCTAssertEqual(envelope.exitStatus, 0, file: file, line: line)
    return envelope
}
```

- [ ] **Step 2: Run representative tests to verify failures**

Run:

```bash
swift test --filter MappingProvenanceTests
swift test --filter BAMPrimerTrimProvenanceTests
swift test --filter WorkflowBuilderRunServiceTests
swift test --filter MultipleSequenceAlignmentBundleTests
swift test --filter PhylogeneticTreeBundleTests
```

Expected: at least one test fails because app/native writers still emit legacy-only sidecars or incomplete top-level fields.

- [ ] **Step 3: Replace manual workflow-run writes with builder or recorder compatibility**

For each native pipeline:

1. Keep existing `recordStep` calls if they already capture accurate per-step details.
2. Ensure each run's `parameters` includes resolved defaults.
3. Ensure every output `FileRecord` is based on final output paths.
4. Let `ProvenanceRecorder.save` write canonical sidecars.
5. For manual JSON provenance writers, replace manual `JSONEncoder().encode(run)` with `ProvenanceWriter().write(run.canonicalEnvelope(), to:)`.

Use this conversion block:

```swift
let envelope = run.canonicalEnvelope()
_ = try ProvenanceWriter().write(envelope, to: outputDirectory)
```

For direct tool executions, prefer:

```swift
let envelope = try await ProvenanceRunBuilder(...)
    .argv(nativeCommand)
    .options(explicit: explicitOptions, defaults: defaultOptions, resolved: resolvedOptions)
    .inputs(inputRecords.map(ProvenanceFileDescriptor.init(fileRecord:)))
    .outputs(outputRecords.map(ProvenanceFileDescriptor.init(fileRecord:)))
    .runtime(.current(executablePath: toolURL, condaEnvironment: environmentName))
    .complete(exitStatus: result.exitCode, stderr: result.stderr.nilIfEmpty, startedAt: started, endedAt: completed)
_ = try ProvenanceWriter().write(envelope, to: outputDirectory)
```

- [ ] **Step 4: Run migrated app/native tests**

Run:

```bash
swift test --filter MappingProvenanceTests
swift test --filter BAMPrimerTrimProvenanceTests
swift test --filter WorkflowBuilderRunServiceTests
swift test --filter MultipleSequenceAlignmentBundleTests
swift test --filter PhylogeneticTreeBundleTests
swift test --filter FASTQOperationExecutionServiceTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow Sources/LungfishIO Sources/LungfishApp/Services \
  Tests/LungfishWorkflowTests Tests/LungfishIOTests Tests/LungfishAppTests
git commit -m "feat: migrate app workflows to provenance builder"
```

---

### Task 10: GUI Provenance Surfaces and XCUI Readiness

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: operations panel files under `Sources/LungfishApp/Views/`
- Create: `Tests/LungfishAppTests/ProvenanceInteractionReadinessTests.swift`
- Create: `Tests/LungfishXCUITests/ProvenanceXCUITests.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/`

- [ ] **Step 1: Write failing GUI readiness tests**

Create `Tests/LungfishAppTests/ProvenanceInteractionReadinessTests.swift`:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class ProvenanceInteractionReadinessTests: XCTestCase {
    func testInspectorCanRenderCanonicalProvenanceSummary() throws {
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "variants.call.ivar",
            toolName: "ivar",
            toolVersion: "1.4.4",
            argv: ["ivar", "variants", "-p", "variants"],
            inputPath: "input.bam",
            outputPath: "variants.vcf.gz"
        )

        let summary = ProvenanceInspectionSummary(envelope: envelope)

        XCTAssertEqual(summary.workflowName, "variants.call.ivar")
        XCTAssertEqual(summary.toolLine, "ivar 1.4.4")
        XCTAssertTrue(summary.commandLine.contains("ivar variants"))
        XCTAssertEqual(summary.signatureState, .unsigned)
        XCTAssertEqual(summary.outputCount, 1)
    }

    func testExportMenuIncludesDocumentedProvenanceFormats() {
        let formats = ProvenanceExportMenuModel.items.map(\.title)
        XCTAssertEqual(formats, ["Shell", "Nextflow", "Snakemake", "Methods Section", "JSON"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProvenanceInteractionReadinessTests
```

Expected: compilation fails because `ProvenanceInspectionSummary` and `ProvenanceExportMenuModel` do not exist.

- [ ] **Step 3: Add view models for provenance UI**

Create or add to an existing App target file:

```swift
struct ProvenanceInspectionSummary: Equatable {
    enum SignatureState: Equatable {
        case unsigned
        case valid(provider: String)
        case invalid(String)
    }

    let workflowName: String
    let toolLine: String
    let commandLine: String
    let signatureState: SignatureState
    let outputCount: Int

    init(envelope: ProvenanceEnvelope) {
        workflowName = envelope.workflowName
        toolLine = "\(envelope.toolName) \(envelope.toolVersion)"
        commandLine = envelope.reproducibleCommand
        signatureState = envelope.signatures.isEmpty ? .unsigned : .valid(provider: envelope.signatures[0].provider)
        outputCount = envelope.outputs.count
    }
}

enum ProvenanceExportMenuModel {
    struct Item: Equatable {
        let title: String
        let format: ProvenanceExportFormat
    }

    static let items: [Item] = [
        Item(title: "Shell", format: .shell),
        Item(title: "Nextflow", format: .nextflow),
        Item(title: "Snakemake", format: .snakemake),
        Item(title: "Methods Section", format: .methods),
        Item(title: "JSON", format: .json),
    ]
}
```

- [ ] **Step 4: Wire Inspector and File menu**

Update `InspectorViewController` to:

- read `ProvenanceEnvelopeReader.load(from:)`
- render canonical JSON in the existing file inspector
- show signature state from `ProvenanceSignatureVerifier`
- show checksum mismatch warnings when validation fails

Update `AppDelegate` menu validation around `File > Export > Provenance` to use `ProvenanceExportMenuModel.items`.

- [ ] **Step 5: Add XCUI test skeleton**

Create `Tests/LungfishXCUITests/ProvenanceXCUITests.swift`:

```swift
import XCTest

final class ProvenanceXCUITests: XCTestCase {
    func testOperationRowOpensProvenanceInspector() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LUNGFISH_UI_TEST_FIXTURE"] = "provenance-fastq"
        app.launch()

        let provenanceButton = app.buttons["operation-row-provenance"]
        XCTAssertTrue(provenanceButton.waitForExistence(timeout: 10))
        provenanceButton.click()

        let inspector = app.otherElements["provenance-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(inspector.staticTexts["schemaVersion"].exists)
    }

    func testFileExportProvenanceMenuShowsFormats() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LUNGFISH_UI_TEST_FIXTURE"] = "provenance-fastq"
        app.launch()

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Export"].hover()
        app.menuItems["Provenance"].hover()

        XCTAssertTrue(app.menuItems["Shell"].exists)
        XCTAssertTrue(app.menuItems["Nextflow"].exists)
        XCTAssertTrue(app.menuItems["Snakemake"].exists)
        XCTAssertTrue(app.menuItems["Methods Section"].exists)
        XCTAssertTrue(app.menuItems["JSON"].exists)
    }
}
```

Add or reuse launch fixture setup in `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`.

- [ ] **Step 6: Run GUI readiness tests**

Run:

```bash
swift test --filter ProvenanceInteractionReadinessTests
swift test --filter SettingsAndImportXCUIReadinessTests
```

For XCUI, run the repo's existing UI test command if available. If not available in SwiftPM, record the Xcode command in the review artifact:

```bash
xcodebuild test -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/ProvenanceXCUITests
```

Expected: App readiness tests pass. XCUI either passes locally or is documented as requiring the Xcode UI test runner.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp Tests/LungfishAppTests/ProvenanceInteractionReadinessTests.swift \
  Tests/LungfishXCUITests/ProvenanceXCUITests.swift Tests/LungfishXCUITests/TestSupport
git commit -m "feat: surface canonical provenance in gui"
```

---

### Task 11: Real-Fixture End-to-End Provenance Tests

**Files:**
- Create: `Tests/LungfishIntegrationTests/ProvenanceRealFixtureE2ETests.swift`
- Modify: `Tests/Fixtures/README.md`
- Add small fixture files under `Tests/Fixtures/provenance/` if existing fixtures do not cover a case.

- [ ] **Step 1: Write failing real-fixture E2E tests**

Create `Tests/LungfishIntegrationTests/ProvenanceRealFixtureE2ETests.swift`:

```swift
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceRealFixtureE2ETests: XCTestCase {
    func testSarsCov2ReferenceBundleE2EWritesCanonicalProvenanceAndExport() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2", isDirectory: true)
        let fasta = fixtures.appendingPathComponent("genome.fasta")
        let gff = fixtures.appendingPathComponent("genome.gff3")
        let bundle = root.appendingPathComponent("sarscov2.lungfishref", isDirectory: true)

        let command = try BundleCommand.CreateSubcommand.parse([
            fasta.path,
            "--annotation", gff.path,
            "--output", bundle.path
        ])
        try await command.run()

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        assertCanonicalE2EEnvelope(envelope, expectedOutputSuffix: ".lungfishref")

        let exportURL = root.appendingPathComponent("export", isDirectory: true)
        let export = try ProvenanceCommand.ExportSubcommand.parse([
            bundle.path,
            "--format", "shell",
            "--output", exportURL.path
        ])
        try await export.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.appendingPathComponent("run.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.appendingPathComponent("provenance/.lungfish-provenance.json").path))
    }

    func testClassifierFixtureImportWritesCanonicalProvenance() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini/SRR35517702", isDirectory: true)
        let project = root.appendingPathComponent("project.lungfish", isDirectory: true)

        let command = try ImportCommand.Kraken2Subcommand.parse([
            fixture.path,
            "--output", project.path,
            "--sample", "SRR35517702"
        ])
        try await command.run()

        let sidecars = try FileManager.default.contentsOfDirectory(
            at: project,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).flatMap { url in
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.lastPathComponent == ProvenanceRecorder.provenanceFilename }

        XCTAssertFalse(sidecars.isEmpty)
        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: sidecars[0]))
        assertCanonicalE2EEnvelope(envelope, expectedOutputSuffix: "")
    }

    private func assertCanonicalE2EEnvelope(_ envelope: ProvenanceEnvelope, expectedOutputSuffix: String) {
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertFalse(envelope.workflowName.isEmpty)
        XCTAssertFalse(envelope.argv.isEmpty)
        XCTAssertFalse(envelope.reproducibleCommand.isEmpty)
        XCTAssertFalse(envelope.runtimeIdentity.operatingSystemVersion.isEmpty)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertNotNil(envelope.wallTimeSeconds)
        XCTAssertTrue(envelope.outputs.allSatisfy { descriptor in
            descriptor.checksumSHA256?.count == 64 && descriptor.fileSize != nil
        })
        if !expectedOutputSuffix.isEmpty {
            XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix(expectedOutputSuffix) || $0.path.contains(expectedOutputSuffix) })
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail against incomplete migration**

Run:

```bash
swift test --filter ProvenanceRealFixtureE2ETests
```

Expected: fail until representative command migrations and export bundle behavior are complete.

- [ ] **Step 3: Fix command argument details and fixture paths**

Adjust the parse arguments to match the current command signatures from `BundleCommand`, `ImportCommand.Kraken2Subcommand`, and existing fixtures. Keep the tests using real fixture files under `Tests/Fixtures`.

- [ ] **Step 4: Add gated managed-tool fixture tests**

Extend `ProvenanceRealFixtureE2ETests` with skip-aware tests:

```swift
func testManagedFastqOperationFixtureWritesCanonicalProvenanceWhenToolsAvailable() async throws {
    do {
        _ = try await NativeToolRunner.shared.toolPath(for: .seqkit)
    } catch {
        throw XCTSkip("Managed seqkit is unavailable: \(error.localizedDescription)")
    }
    // Use Tests/Fixtures/sarscov2/test_1.fastq.gz and test_2.fastq.gz.
    // Run a real FASTQ operation through the CLI.
    // Assert canonical sidecar fields and final output paths.
}
```

Use `XCTSkip` messages that name the missing tool, database, or fixture path.

- [ ] **Step 5: Run integration tests**

Run:

```bash
swift test --filter ProvenanceRealFixtureE2ETests
swift test --filter FASTQOperationIntegrationTests
swift test --filter ReadsToVariantsEndToEnd
```

Expected: hermetic tests pass; gated tests pass or skip with specific prerequisite messages.

- [ ] **Step 6: Commit**

```bash
git add Tests/LungfishIntegrationTests/ProvenanceRealFixtureE2ETests.swift Tests/Fixtures/README.md Tests/Fixtures/provenance
git commit -m "test: add real fixture provenance e2e coverage"
```

---

### Task 12: Full Verification and Independent Review Rounds

**Files:**
- Create: `docs/superpowers/reviews/2026-05-12-provenance-review-round-1.md`
- Create: `docs/superpowers/reviews/2026-05-12-provenance-review-round-2.md`
- Add further `docs/superpowers/reviews/2026-05-12-provenance-review-round-N.md` up to round 5 when blocking defects remain.
- Modify implementation files as review findings require.

- [ ] **Step 1: Run full local verification**

Run:

```bash
swift test
```

Expected: all non-gated tests pass. Record exact test counts, skipped counts, and failures in the round 1 review artifact.

- [ ] **Step 2: Dispatch three independent review teams for round 1**

Use separate reviewers with these prompts:

CLI provenance team:

```text
Review the provenance builder implementation from the perspective of CLI scientific workflows. Run or inspect representative CLI actions that create, import, transform, export, or wrap scientific data. Check sidecar presence, schemaVersion, workflow/tool identity, exact argv, reproducible command, resolved defaults, runtime identity, final input/output paths, checksums, sizes, exit status, wall time, stderr, export commands, and signature verification. Do not edit files. Return blocking findings with file paths, commands run, observed JSON excerpts, and concrete fixes.
```

JSON/report audit team:

```text
Audit generated .lungfish-provenance.json files and exported provenance reports. Check canonical schema consistency, legacy WorkflowRun conversion, compatibility aliases, full SHA-256 fields, output and outputs consistency, signature artifacts, Shell/Nextflow/Snakemake/Methods/JSON export bundles, and copied sidecars. Do not edit files. Return blocking findings with exact paths and schema/report evidence.
```

GUI/XCUI team:

```text
Review GUI provenance interactions. Inspect or run XCUI coverage for Operations Panel provenance buttons, Inspector JSON rendering, File > Export > Provenance, signing status, checksum warnings, missing/invalid provenance warnings, and GUI-imported CLI outputs whose provenance points at final bundle payloads. Do not edit files. Return blocking findings with UI surface, accessibility identifier, reproduction steps, and concrete fixes.
```

- [ ] **Step 3: Write round 1 review artifact**

Create `docs/superpowers/reviews/2026-05-12-provenance-review-round-1.md`:

```markdown
# Provenance Review Round 1

## Verification

- Command:
- Result:
- Test count:
- Skipped count:

## CLI Provenance Team Findings

- Finding:
- Evidence:
- Resolution:

## JSON and Report Audit Team Findings

- Finding:
- Evidence:
- Resolution:

## GUI and XCUI Team Findings

- Finding:
- Evidence:
- Resolution:

## Blocking Items

- [ ] Item:
```

- [ ] **Step 4: Fix round 1 blockers with TDD**

For every blocking item:

1. Write or extend a failing test that reproduces it.
2. Run the focused test and confirm it fails.
3. Implement the smallest fix.
4. Run the focused test and confirm it passes.
5. Run the relevant suite.

Commit fixes:

```bash
git add <changed files>
git commit -m "fix: address provenance review round 1"
```

- [ ] **Step 5: Run round 2 verification and reviews**

Run:

```bash
swift test
```

Dispatch the same three review prompts, with this additional instruction:

```text
This is review round 2. Re-check every round 1 blocker and look for remaining gaps. Do not assume previous fixes are correct without evidence.
```

Create `docs/superpowers/reviews/2026-05-12-provenance-review-round-2.md` with the same structure as round 1.

- [ ] **Step 6: Continue up to five rounds while blockers remain**

If any round 2 blocker remains, repeat:

```bash
swift test
```

Create:

- `docs/superpowers/reviews/2026-05-12-provenance-review-round-3.md`
- `docs/superpowers/reviews/2026-05-12-provenance-review-round-4.md`
- `docs/superpowers/reviews/2026-05-12-provenance-review-round-5.md`

Stop after the earliest round where all teams report no blocking defects, with a minimum of two rounds completed.

- [ ] **Step 7: Final full verification**

Run:

```bash
swift test
```

If XCUI is available, also run:

```bash
xcodebuild test -scheme Lungfish -destination 'platform=macOS' -only-testing:LungfishXCUITests/ProvenanceXCUITests
```

Expected: `swift test` passes. XCUI passes or has a documented infrastructure limitation unrelated to provenance behavior.

- [ ] **Step 8: Commit review artifacts**

```bash
git add docs/superpowers/reviews
git commit -m "docs: record provenance review rounds"
```

---

## Self-Review Checklist

- Spec coverage: The plan covers canonical schema, builder API, full checksums, policy gates, CLI migration, GUI rehydration, export/reporting/signing, GUI/XCUI interactions, real-fixture E2E tests, and 2-5 independent review rounds.
- Placeholder scan: No placeholder markers, incomplete sections, or vague test-only steps are intentionally present.
- Type consistency: The plan consistently uses `ProvenanceEnvelope`, `ProvenanceEnvelopeReader`, `ProvenanceFileDescriptor`, `ProvenanceRunBuilder`, `ProvenanceWriter`, `ProvenanceRehydrator`, and `ScientificProvenancePolicy`.
- Risk note: Some exact CLI parse arguments in real-fixture tests may need adjustment to match current command signatures; the plan requires keeping the tests real and updating arguments rather than weakening assertions.
