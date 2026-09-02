# Viral Recon Phase 2: Wizard Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the Viral Recon sheet from about nineteen controls to four, with an advanced disclosure for everything else.

**Architecture:** The reference and executor controls are deleted outright, since both are now fixed. Callers, version and skip options become invisible defaults. An advanced disclosure carries a GFF picker and an extra-parameters field parsed by the existing `AdvancedCommandLineOptions`, validated against the pipeline schema.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest, `AdvancedCommandLineOptions` (in `LungfishWorkflow`).

**Spec:** `docs/superpowers/specs/2026-09-02-viral-recon-wizard-simplification-design.md`

**Depends on:** `2026-09-02-viral-recon-phase1-reference-foundation.md` Tasks 1 to 5 complete.

## Global Constraints

- Viral Recon is SARS-CoV-2 only. No reference control appears anywhere in the sheet.
- Docker is the only executor. No executor control appears in the sheet.
- `skip_freyja` and `skip_freyja_boot` are forced and unreachable from any user input.
- Visible controls, in order: Inputs, Primer Scheme, Minimum mapped reads, Readiness.
- Build and test with `--package-path` and `--skip-update`. Never `-C`.
- SwiftPM holds one `.build/.lock` per checkout. Never run a swift command while another is running in this worktree.
- No em dashes in any prose, comment, or committed document.

---

### Task 1: Schema-backed advanced parameter validation

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconParameterSchema.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconParameterSchemaTests.swift`

**Interfaces:**
- Consumes: `ViralReconRunRequest.structuralAdvancedKeys` and `.overridableAdvancedKeys` from Phase 1 Task 5.
- Produces: `ViralReconParameterSchema.ValidationOutcome` (enum: `accepted`, `unknownParameter(String)`, `structural(String)`), and `ViralReconParameterSchema.validate(_ params: [String: String], knownParameters: Set<String>) -> [ValidationOutcome]`, plus `ViralReconParameterSchema.loadKnownParameters(from schemaURL: URL) throws -> Set<String>`.

A typo currently fails minutes into a run. Validating names at the sheet turns that into an immediate, correctable error.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ViralReconParameterSchemaTests: XCTestCase {
    private let known: Set<String> = ["variant_caller", "min_mapped_reads", "skip_fastqc", "input"]

    func testKnownOverridableParameterIsAccepted() {
        let outcomes = ViralReconParameterSchema.validate(
            ["variant_caller": "bcftools"], knownParameters: known)
        XCTAssertEqual(outcomes, [.accepted])
    }

    func testUnknownParameterIsReportedByName() {
        let outcomes = ViralReconParameterSchema.validate(
            ["varient_caller": "bcftools"], knownParameters: known)
        XCTAssertEqual(outcomes, [.unknownParameter("varient_caller")])
    }

    func testStructuralParameterIsReportedEvenWhenKnownToTheSchema() {
        // `input` is a real pipeline parameter, but the wizard owns it.
        let outcomes = ViralReconParameterSchema.validate(
            ["input": "/tmp/x.csv"], knownParameters: known)
        XCTAssertEqual(outcomes, [.structural("input")])
    }

    func testLoadsParameterNamesFromNextflowSchema() throws {
        let schema = """
        {"$defs":{"input_output":{"properties":{
          "input":{"type":"string"},"outdir":{"type":"string"}}},
        "callers":{"properties":{"variant_caller":{"type":"string"}}}}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-\(UUID().uuidString).json")
        try schema.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let names = try ViralReconParameterSchema.loadKnownParameters(from: url)

        XCTAssertTrue(names.contains("input"))
        XCTAssertTrue(names.contains("outdir"))
        XCTAssertTrue(names.contains("variant_caller"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconParameterSchemaTests`
Expected: FAIL, cannot find `ViralReconParameterSchema` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconParameterSchema.swift - Validate advanced parameters before launch
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Checks advanced parameter names before a run starts.
///
/// A misspelled parameter otherwise fails several minutes into a pipeline run,
/// long after the user has left the sheet.
public enum ViralReconParameterSchema {
    public enum ValidationOutcome: Equatable, Sendable {
        case accepted
        case unknownParameter(String)
        case structural(String)
    }

    public static func validate(
        _ params: [String: String],
        knownParameters: Set<String>
    ) -> [ValidationOutcome] {
        params.keys.sorted().map { key in
            if ViralReconRunRequest.structuralAdvancedKeys.contains(key) {
                return .structural(key)
            }
            if !knownParameters.contains(key) {
                return .unknownParameter(key)
            }
            return .accepted
        }
    }

    /// Collects every parameter name declared anywhere in a Nextflow schema by
    /// walking `properties` maps wherever they appear.
    public static func loadKnownParameters(from schemaURL: URL) throws -> Set<String> {
        let data = try Data(contentsOf: schemaURL)
        let root = try JSONSerialization.jsonObject(with: data)
        var names: Set<String> = []
        collectProperties(from: root, into: &names)
        return names
    }

    private static func collectProperties(from node: Any, into names: inout Set<String>) {
        guard let object = node as? [String: Any] else {
            if let array = node as? [Any] {
                for element in array { collectProperties(from: element, into: &names) }
            }
            return
        }
        if let properties = object["properties"] as? [String: Any] {
            names.formUnion(properties.keys)
        }
        for (key, value) in object where key != "properties" {
            collectProperties(from: value, into: &names)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconParameterSchemaTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Verify against the real pipeline schema**

Run:
```bash
swift test --package-path . --skip-update --filter ViralReconParameterSchemaTests 2>&1 | tail -3
ls ~/.nextflow/assets/nf-core/viralrecon/nextflow_schema.json
```
Expected: the schema file exists. Confirm by inspection that `loadKnownParameters` returns a set containing `variant_caller`, `skip_fastqc` and `min_mapped_reads` when pointed at it. If the real schema nests differently, correct the walker.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconParameterSchema.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconParameterSchemaTests.swift
git commit -m "Validate advanced Viral Recon parameters against the pipeline schema"
```

---

### Task 2: Reduce the wizard to four visible controls

**Files:**
- Modify: `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`
- Test: `Tests/LungfishAppTests/ViralReconWizardSheetTests.swift`

**Interfaces:**
- Consumes: `ViralReconReferenceCatalog` and `ViralReconReferenceAcquisition` from Phase 1, `ViralReconParameterSchema` from Task 1.
- Produces: `ViralReconWizardSheet.VisibleControl` (enum: `inputs`, `primerScheme`, `minimumMappedReads`, `readiness`) and `ViralReconWizardSheet.visibleControls(platformDetected:) -> [VisibleControl]`.

Removed from the sheet: the reference mode picker, the genome accession field, the Local FASTA menu, the Choose FASTA button, the executor picker, the version field, the CPU and memory fields, the caller pickers and the nine skip checkboxes.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp

final class ViralReconWizardSheetTests: XCTestCase {
    func testFourVisibleControlsWhenPlatformDetected() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: true)
        XCTAssertEqual(controls, [.inputs, .primerScheme, .minimumMappedReads, .readiness])
    }

    func testPlatformControlAppearsOnlyWhenDetectionFails() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: false)
        XCTAssertTrue(controls.contains(.platform))
        XCTAssertEqual(controls.first, .inputs)
    }

    func testNoReferenceOrExecutorControlIsOffered() {
        for detected in [true, false] {
            let controls = ViralReconWizardSheet.visibleControls(platformDetected: detected)
            XCTAssertFalse(controls.contains(.reference))
            XCTAssertFalse(controls.contains(.executor))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconWizardSheetTests`
Expected: FAIL, no member `visibleControls`. The test also references `.platform`, `.reference` and `.executor`, so add all six cases to the enum in Step 3 while only four are returned by default.

- [ ] **Step 3: Write minimal implementation**

Add to `ViralReconWizardSheet`:

```swift
    /// Controls the sheet can show.
    ///
    /// `reference` and `executor` exist only so tests can assert they are never
    /// returned. Viral Recon is SARS-CoV-2 only and Docker only, so neither is
    /// ever a choice.
    enum VisibleControl: Equatable {
        case inputs
        case platform
        case primerScheme
        case minimumMappedReads
        case readiness
        case reference
        case executor
    }

    static func visibleControls(platformDetected: Bool) -> [VisibleControl] {
        var controls: [VisibleControl] = [.inputs]
        if !platformDetected { controls.append(.platform) }
        controls.append(contentsOf: [.primerScheme, .minimumMappedReads, .readiness])
        return controls
    }
```

Then delete the reference section, executor picker, version field, CPU and memory fields, caller pickers and skip-option grid from the sheet body, and drive the body from `visibleControls(platformDetected:)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconWizardSheetTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Build the app target**

Run: `swift build --package-path . --skip-update`
Expected: build succeeds. Deleting state properties will surface unused-variable warnings and any remaining references to removed controls; fix them.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift Tests/LungfishAppTests/ViralReconWizardSheetTests.swift
git commit -m "Reduce the Viral Recon sheet to four visible controls"
```

---

### Task 3: Advanced disclosure

**Files:**
- Modify: `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`
- Test: `Tests/LungfishAppTests/ViralReconWizardSheetTests.swift`

**Interfaces:**
- Consumes: `AdvancedCommandLineOptions.parse(_:) throws -> [String]`, `ViralReconParameterSchema.validate(_:knownParameters:)`.
- Produces: `ViralReconWizardSheet.parseAdvancedParameters(_ text: String, knownParameters: Set<String>) -> Result<[String: String], String>`, returning a message suitable for the readiness line on failure.

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testAdvancedFieldParsesKeyValuePairs() {
        let known: Set<String> = ["variant_caller", "min_mapped_reads"]
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--variant_caller bcftools --min_mapped_reads 500", knownParameters: known)
        guard case .success(let params) = result else { return XCTFail("expected success") }
        XCTAssertEqual(params["variant_caller"], "bcftools")
        XCTAssertEqual(params["min_mapped_reads"], "500")
    }

    func testAdvancedFieldRejectsUnknownParameterByName() {
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--varient_caller bcftools", knownParameters: ["variant_caller"])
        guard case .failure(let message) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("varient_caller"), message)
    }

    func testAdvancedFieldRejectsStructuralParameterNamingTheOwningControl() {
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--primer_bed /tmp/x.bed", knownParameters: ["primer_bed"])
        guard case .failure(let message) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("primer_bed"), message)
    }

    func testEmptyAdvancedFieldSucceeds() {
        let result = ViralReconWizardSheet.parseAdvancedParameters("", knownParameters: [])
        guard case .success(let params) = result else { return XCTFail("expected success") }
        XCTAssertTrue(params.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconWizardSheetTests`
Expected: FAIL, no member `parseAdvancedParameters`.

- [ ] **Step 3: Write minimal implementation**

```swift
    /// Parses the advanced parameters field into pipeline parameters.
    ///
    /// Uses the same tokenizer six other wizards use, then checks each name
    /// against the pipeline schema so a typo is caught here rather than several
    /// minutes into a run.
    static func parseAdvancedParameters(
        _ text: String,
        knownParameters: Set<String>
    ) -> Result<[String: String], String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success([:]) }

        let tokens: [String]
        do {
            tokens = try AdvancedCommandLineOptions.parse(trimmed)
        } catch {
            return .failure(error.localizedDescription)
        }

        var params: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("--") else {
                return .failure("Expected a parameter starting with -- but found \(token).")
            }
            let name = String(token.dropFirst(2))
            guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
                return .failure("Parameter --\(name) needs a value.")
            }
            params[name] = tokens[index + 1]
            index += 2
        }

        for outcome in ViralReconParameterSchema.validate(params, knownParameters: knownParameters) {
            switch outcome {
            case .accepted:
                continue
            case .unknownParameter(let name):
                return .failure("\(name) is not a Viral Recon parameter. Check the spelling.")
            case .structural(let name):
                return .failure("\(name) is set by the wizard and cannot be overridden here.")
            }
        }
        return .success(params)
    }
```

Then add a collapsed `DisclosureGroup` titled "Advanced" to the sheet body containing a GFF picker and a `TextField` bound to the advanced text, routing failures to the readiness line.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconWizardSheetTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift Tests/LungfishAppTests/ViralReconWizardSheetTests.swift
git commit -m "Add the Viral Recon advanced parameters disclosure"
```

---

### Task 4: Correct the user manual

**Files:**
- Modify: `docs/user-manual/05-viral-recon-wizard.md`

The manual currently states that Docker, Conda and Local all work. Only Docker does.

- [ ] **Step 1: Find every executor claim**

Run: `grep -n -i 'conda\|local\|executor\|docker' docs/user-manual/05-viral-recon-wizard.md`

- [ ] **Step 2: Rewrite the affected passages**

State that Viral Recon requires Docker Desktop and runs SARS-CoV-2 amplicon data only. Remove references to choosing an executor, a reference, a pipeline version, callers and skip checkboxes, since none of those controls exist any more. Describe the four visible controls and the advanced field.

House style applies to this file: no em dashes, bullets capped at 5 items and 2 sentences each.

- [ ] **Step 3: Verify style**

Run: `grep -c '—' docs/user-manual/05-viral-recon-wizard.md`
Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add docs/user-manual/05-viral-recon-wizard.md
git commit -m "Correct the Viral Recon manual: Docker only, four controls"
```

---

### Task 5: Phase gate

- [ ] **Step 1: Run the unit tier**

Run: `bash scripts/full-suite-gate.sh --tier unit`
Expected: `GATE PASS`.

- [ ] **Step 2: Build the debug app and confirm the sheet**

Run: `swift build --package-path . --skip-update && bash scripts/build-app.sh --debug --skip-build`
Expected: build succeeds. The sheet is verified visually in the QA round, not here.

- [ ] **Step 3: Commit any gate fixes**

```bash
git add -A
git commit -m "Phase 2 gate: wizard simplification"
```
