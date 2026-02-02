// WorkflowParametersTests.swift - Tests for workflow parameter types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class WorkflowParametersTests: XCTestCase {

    // MARK: - ParameterValue Tests

    func testParameterValueStringValue() {
        let value = ParameterValue.string("test value")
        XCTAssertEqual(value.stringValue, "test value")
        XCTAssertNil(value.integerValue)
        XCTAssertNil(value.booleanValue)
    }

    func testParameterValueIntegerValue() {
        let value = ParameterValue.integer(42)
        XCTAssertEqual(value.integerValue, 42)
        XCTAssertNil(value.stringValue)
        XCTAssertNil(value.booleanValue)
    }

    func testParameterValueNumberValue() {
        let value = ParameterValue.number(3.14159)
        XCTAssertEqual(value.numberValue, 3.14159)
        XCTAssertNil(value.stringValue)
        XCTAssertNil(value.integerValue)
    }

    func testParameterValueBooleanValue() {
        let trueValue = ParameterValue.boolean(true)
        XCTAssertEqual(trueValue.booleanValue, true)

        let falseValue = ParameterValue.boolean(false)
        XCTAssertEqual(falseValue.booleanValue, false)
    }

    func testParameterValueFileValue() {
        let url = URL(fileURLWithPath: "/path/to/file.txt")
        let value = ParameterValue.file(url)
        XCTAssertEqual(value.fileValue, url)
    }

    func testParameterValueArrayValue() {
        let values: [ParameterValue] = [.string("a"), .string("b"), .integer(1)]
        let value = ParameterValue.array(values)
        XCTAssertEqual(value.arrayValue?.count, 3)
    }

    func testParameterValueDictionaryValue() {
        let dict: [String: ParameterValue] = [
            "name": .string("test"),
            "count": .integer(5)
        ]
        let value = ParameterValue.dictionary(dict)
        XCTAssertEqual(value.dictionaryValue?.count, 2)
    }

    func testParameterValueNull() {
        let value = ParameterValue.null
        XCTAssertTrue(value.isNull)
        XCTAssertNil(value.stringValue)
        XCTAssertNil(value.integerValue)
    }

    func testParameterValueToArgumentString() {
        XCTAssertEqual(ParameterValue.string("hello").toArgumentString(), "hello")
        XCTAssertEqual(ParameterValue.integer(42).toArgumentString(), "42")
        XCTAssertEqual(ParameterValue.number(3.14).toArgumentString(), "3.14")
        XCTAssertEqual(ParameterValue.boolean(true).toArgumentString(), "true")
        XCTAssertEqual(ParameterValue.boolean(false).toArgumentString(), "false")
        XCTAssertEqual(ParameterValue.null.toArgumentString(), "")

        let url = URL(fileURLWithPath: "/path/to/file")
        XCTAssertEqual(ParameterValue.file(url).toArgumentString(), "/path/to/file")

        let array: [ParameterValue] = [.string("a"), .string("b")]
        XCTAssertEqual(ParameterValue.array(array).toArgumentString(), "a,b")
    }

    func testParameterValueCodable() throws {
        let values: [ParameterValue] = [
            .string("test"),
            .integer(123),
            .number(1.5),
            .boolean(true),
            .null,
            .file(URL(fileURLWithPath: "/test/path")),
            .array([.string("a"), .integer(1)]),
            .dictionary(["key": .string("value")])
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(ParameterValue.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    // MARK: - WorkflowParameters Tests

    func testWorkflowParametersEmpty() {
        let params = WorkflowParameters()
        XCTAssertTrue(params.isEmpty)
        XCTAssertEqual(params.count, 0)
    }

    func testWorkflowParametersSubscript() {
        var params = WorkflowParameters()
        params["input"] = .string("/path/to/input")
        params["threads"] = .integer(8)

        XCTAssertEqual(params["input"]?.stringValue, "/path/to/input")
        XCTAssertEqual(params["threads"]?.integerValue, 8)
        XCTAssertNil(params["nonexistent"])
    }

    func testWorkflowParametersTypedAccessors() {
        var params = WorkflowParameters()
        params.set("name", string: "test")
        params.set("count", integer: 10)
        params.set("ratio", number: 0.5)
        params.set("enabled", boolean: true)
        params.set("file", file: URL(fileURLWithPath: "/data/input.fasta"))

        XCTAssertEqual(params.string("name"), "test")
        XCTAssertEqual(params.integer("count"), 10)
        XCTAssertEqual(params.number("ratio"), 0.5)
        XCTAssertEqual(params.boolean("enabled"), true)
        XCTAssertEqual(params.file("file")?.path, "/data/input.fasta")
    }

    func testWorkflowParametersNames() {
        var params = WorkflowParameters()
        params["a"] = .string("1")
        params["b"] = .string("2")
        params["c"] = .string("3")

        let names = params.names.sorted()
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    func testWorkflowParametersRemove() {
        var params = WorkflowParameters()
        params["key1"] = .string("value1")
        params["key2"] = .string("value2")

        XCTAssertEqual(params.count, 2)

        let removed = params.remove("key1")
        XCTAssertEqual(removed?.stringValue, "value1")
        XCTAssertEqual(params.count, 1)

        params.removeAll()
        XCTAssertTrue(params.isEmpty)
    }

    func testWorkflowParametersMerge() {
        var params1 = WorkflowParameters()
        params1["a"] = .string("1")
        params1["b"] = .string("2")

        var params2 = WorkflowParameters()
        params2["b"] = .string("new")
        params2["c"] = .string("3")

        params1.merge(params2)

        XCTAssertEqual(params1["a"]?.stringValue, "1")
        XCTAssertEqual(params1["b"]?.stringValue, "new") // Overwritten
        XCTAssertEqual(params1["c"]?.stringValue, "3")
    }

    func testWorkflowParametersMerging() {
        var params1 = WorkflowParameters()
        params1["x"] = .integer(1)

        var params2 = WorkflowParameters()
        params2["y"] = .integer(2)

        let merged = params1.merging(params2)

        // Original unchanged
        XCTAssertNil(params1["y"])

        // Merged has both
        XCTAssertEqual(merged["x"]?.integerValue, 1)
        XCTAssertEqual(merged["y"]?.integerValue, 2)
    }

    func testWorkflowParametersToNextflowArguments() {
        var params = WorkflowParameters()
        params["input"] = .string("/data/input.fq")
        params["genome"] = .string("GRCh38")
        params["threads"] = .integer(8)
        params["skip_qc"] = .boolean(false)
        params["run_multiqc"] = .boolean(true)
        params["skip_me"] = .null

        let args = params.toNextflowArguments()

        // Should contain --input /data/input.fq
        XCTAssertTrue(args.contains("--input"))
        XCTAssertTrue(args.contains("/data/input.fq"))

        // Boolean true should just be --flag
        XCTAssertTrue(args.contains("--run_multiqc"))

        // Boolean false should be omitted
        XCTAssertFalse(args.contains("--skip_qc"))

        // Null should be omitted
        XCTAssertFalse(args.contains("--skip_me"))
    }

    func testWorkflowParametersToSnakemakeConfig() {
        var params = WorkflowParameters()
        params["input_dir"] = .string("/data")
        params["threads"] = .integer(4)
        params["enabled"] = .boolean(true)

        let config = params.toSnakemakeConfig()

        XCTAssertEqual(config["input_dir"] as? String, "/data")
        XCTAssertEqual(config["threads"] as? Int, 4)
        XCTAssertEqual(config["enabled"] as? Bool, true)
    }

    func testWorkflowParametersToEnvironment() {
        var params = WorkflowParameters()
        params["input-file"] = .string("/path/to/input")
        params["max_threads"] = .integer(8)

        let env = params.toEnvironment(prefix: "WF_")

        XCTAssertEqual(env["WF_INPUT_FILE"], "/path/to/input")
        XCTAssertEqual(env["WF_MAX_THREADS"], "8")
    }

    func testWorkflowParametersJSONRoundTrip() throws {
        var params = WorkflowParameters()
        params["string"] = .string("value")
        params["int"] = .integer(42)
        params["number"] = .number(3.14)
        params["bool"] = .boolean(true)

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("params.json")

        try params.writeJSON(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let loaded = try WorkflowParameters.readJSON(from: tempFile)

        XCTAssertEqual(loaded["string"]?.stringValue, "value")
        XCTAssertEqual(loaded["int"]?.integerValue, 42)
        XCTAssertEqual(loaded["number"]?.numberValue, 3.14)
        XCTAssertEqual(loaded["bool"]?.booleanValue, true)
    }

    func testWorkflowParametersDictionaryLiteral() {
        let params: WorkflowParameters = [
            "input": .string("/data"),
            "threads": .integer(4)
        ]

        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params["input"]?.stringValue, "/data")
        XCTAssertEqual(params["threads"]?.integerValue, 4)
    }

    func testWorkflowParametersSequence() {
        var params = WorkflowParameters()
        params["a"] = .string("1")
        params["b"] = .string("2")

        var count = 0
        for (key, value) in params {
            XCTAssertFalse(key.isEmpty)
            XCTAssertNotNil(value.stringValue)
            count += 1
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - ParameterDefinition Tests

    func testParameterDefinitionCreation() {
        let def = ParameterDefinition(
            name: "input",
            title: "Input File",
            description: "Path to input file",
            type: .file,
            defaultValue: .string("/default/path"),
            isRequired: true,
            isHidden: false
        )

        XCTAssertEqual(def.id, "input")
        XCTAssertEqual(def.name, "input")
        XCTAssertEqual(def.title, "Input File")
        XCTAssertEqual(def.description, "Path to input file")
        XCTAssertEqual(def.type, .file)
        XCTAssertEqual(def.defaultValue?.stringValue, "/default/path")
        XCTAssertTrue(def.isRequired)
        XCTAssertFalse(def.isHidden)
    }

    func testParameterTypeRawValues() {
        XCTAssertEqual(ParameterType.string.rawValue, "string")
        XCTAssertEqual(ParameterType.integer.rawValue, "integer")
        XCTAssertEqual(ParameterType.number.rawValue, "number")
        XCTAssertEqual(ParameterType.boolean.rawValue, "boolean")
        XCTAssertEqual(ParameterType.file.rawValue, "file")
        XCTAssertEqual(ParameterType.directory.rawValue, "directory")
        XCTAssertEqual(ParameterType.array.rawValue, "array")
        XCTAssertEqual(ParameterType.object.rawValue, "object")
    }
}
