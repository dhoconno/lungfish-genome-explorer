// SchemaParserTests.swift - Tests for Nextflow and Snakemake schema parsers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class SchemaParserTests: XCTestCase {

    // MARK: - UnifiedWorkflowSchema Tests

    func testUnifiedWorkflowSchemaCreation() {
        let param = UnifiedWorkflowParameter(
            id: "input",
            name: "input",
            title: "Input File",
            description: "Path to input FASTQ file",
            type: .file,
            defaultValue: nil,
            isRequired: true,
            isHidden: false,
            validation: nil,
            iconName: "doc"
        )

        let group = UnifiedParameterGroup(
            id: "input_output",
            title: "Input/Output",
            description: "Input and output parameters",
            iconName: "folder",
            isCollapsedByDefault: false,
            isHidden: false,
            parameters: [param]
        )

        let schema = UnifiedWorkflowSchema(
            version: "1.0",
            title: "Test Workflow",
            description: "A test workflow schema",
            groups: [group]
        )

        XCTAssertEqual(schema.title, "Test Workflow")
        XCTAssertEqual(schema.version, "1.0")
        XCTAssertEqual(schema.groups.count, 1)
        XCTAssertEqual(schema.allParameters.count, 1)
        XCTAssertEqual(schema.allParameters.first?.id, "input")
    }

    func testUnifiedParameterTypes() {
        // Test string type
        let stringType = UnifiedParameterType.string
        XCTAssertEqual(stringType.displayName, "Text")
        XCTAssertEqual(stringType.iconName, "textformat")

        // Test file type
        let fileType = UnifiedParameterType.file
        XCTAssertEqual(fileType.displayName, "File")
        XCTAssertEqual(fileType.iconName, "doc")

        // Test enumeration type
        let enumType = UnifiedParameterType.enumeration(["option1", "option2", "option3"])
        XCTAssertEqual(enumType.displayName, "Selection")
        if case .enumeration(let options) = enumType {
            XCTAssertEqual(options.count, 3)
        } else {
            XCTFail("Expected enumeration type")
        }

        // Test array type
        let arrayType = UnifiedParameterType.array(.string)
        XCTAssertEqual(arrayType.displayName, "Array")
    }

    func testUnifiedParameterValue() {
        // Test string value
        let stringValue = UnifiedParameterValue.string("hello")
        XCTAssertEqual(stringValue.stringValue, "hello")

        // Test integer value
        let intValue = UnifiedParameterValue.integer(42)
        XCTAssertEqual(intValue.integerValue, 42)

        // Test number value
        let numValue = UnifiedParameterValue.number(3.14)
        XCTAssertEqual(numValue.numberValue, 3.14)

        // Test boolean value
        let boolValue = UnifiedParameterValue.boolean(true)
        XCTAssertEqual(boolValue.booleanValue, true)

        // Test null value
        let nullValue = UnifiedParameterValue.null
        XCTAssertTrue(nullValue.isNull)
    }

    func testUnifiedParameterValueCodable() throws {
        let values: [UnifiedParameterValue] = [
            .string("test"),
            .integer(42),
            .number(3.14),
            .boolean(true),
            .null
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(UnifiedParameterValue.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    func testUnifiedParameterValidation() {
        let validation = UnifiedParameterValidation(
            pattern: "^[A-Z]+$",
            minimum: 0,
            maximum: 100,
            minLength: 1,
            maxLength: 50,
            mustExist: true,
            mimeTypes: ["text/plain"],
            fileExtensions: ["txt", "log"]
        )

        XCTAssertEqual(validation.pattern, "^[A-Z]+$")
        XCTAssertEqual(validation.minimum, 0)
        XCTAssertEqual(validation.maximum, 100)
        XCTAssertEqual(validation.minLength, 1)
        XCTAssertEqual(validation.maxLength, 50)
        XCTAssertEqual(validation.mustExist, true)
        XCTAssertEqual(validation.mimeTypes, ["text/plain"])
        XCTAssertEqual(validation.fileExtensions, ["txt", "log"])
    }

    func testSchemaParameterLookup() {
        let param1 = UnifiedWorkflowParameter(
            id: "input",
            name: "input",
            title: "Input",
            description: nil,
            type: .file,
            defaultValue: nil,
            isRequired: true,
            isHidden: false,
            validation: nil,
            iconName: nil
        )

        let param2 = UnifiedWorkflowParameter(
            id: "output",
            name: "output",
            title: "Output",
            description: nil,
            type: .directory,
            defaultValue: nil,
            isRequired: true,
            isHidden: false,
            validation: nil,
            iconName: nil
        )

        let group = UnifiedParameterGroup(
            id: "io",
            title: "I/O",
            description: nil,
            parameters: [param1, param2]
        )

        let schema = UnifiedWorkflowSchema(
            title: "Test",
            description: nil,
            groups: [group]
        )

        // Test parameter lookup by name
        let foundParam = schema.parameter(named: "input")
        XCTAssertNotNil(foundParam)
        XCTAssertEqual(foundParam?.id, "input")

        let notFoundParam = schema.parameter(named: "nonexistent")
        XCTAssertNil(notFoundParam)
    }

    // MARK: - NextflowSchemaParser Tests

    func testNextflowSchemaParser() async throws {
        // Create a temporary schema file
        let schemaJSON = """
        {
            "$schema": "http://json-schema.org/draft-07/schema",
            "title": "nf-core/testpipeline",
            "description": "A test pipeline",
            "definitions": {
                "input_output_options": {
                    "title": "Input/Output Options",
                    "description": "Define input and output paths",
                    "properties": {
                        "input": {
                            "type": "string",
                            "format": "file-path",
                            "description": "Path to input samplesheet",
                            "fa_icon": "fas fa-file-code"
                        },
                        "outdir": {
                            "type": "string",
                            "format": "directory-path",
                            "default": "./results",
                            "description": "Output directory"
                        }
                    },
                    "required": ["input"]
                },
                "max_job_request_options": {
                    "title": "Max Job Request Options",
                    "properties": {
                        "max_cpus": {
                            "type": "integer",
                            "default": 16,
                            "description": "Maximum CPUs"
                        },
                        "max_memory": {
                            "type": "string",
                            "default": "128.GB",
                            "description": "Maximum memory"
                        }
                    }
                }
            },
            "allOf": [
                {"$ref": "#/definitions/input_output_options"},
                {"$ref": "#/definitions/max_job_request_options"}
            ]
        }
        """

        let tempDir = FileManager.default.temporaryDirectory
        let schemaURL = tempDir.appendingPathComponent("nextflow_schema.json")
        try schemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: schemaURL)
        }

        let parser = NextflowSchemaParser()
        let schema = try await parser.parse(from: schemaURL)

        XCTAssertEqual(schema.title, "nf-core/testpipeline")
        XCTAssertEqual(schema.groups.count, 2)

        // Check parameter parsing
        let allParams = schema.allParameters
        XCTAssertGreaterThanOrEqual(allParams.count, 4)

        // Find input parameter
        let inputParam = schema.parameter(named: "input")
        XCTAssertNotNil(inputParam)
        XCTAssertEqual(inputParam?.type, .file)
        XCTAssertEqual(inputParam?.isRequired, true)

        // Find max_cpus parameter
        let cpuParam = schema.parameter(named: "max_cpus")
        XCTAssertNotNil(cpuParam)
        XCTAssertEqual(cpuParam?.type, .integer)
        if case .integer(let value) = cpuParam?.defaultValue {
            XCTAssertEqual(value, 16)
        }
    }

    // MARK: - SnakemakeConfigParser Tests

    func testSnakemakeConfigParser() async throws {
        // Create a temporary config file
        let configYAML = """
        # Snakemake config
        input_dir: "data/raw"
        output_dir: "results"
        threads: 4
        run_qc: true
        genome:
          reference: "GRCh38"
          annotation: "gencode.v38"
        samples:
          - sample1
          - sample2
        """

        let tempDir = FileManager.default.temporaryDirectory
        let configURL = tempDir.appendingPathComponent("config.yaml")
        try configYAML.write(to: configURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: configURL)
        }

        let parser = SnakemakeConfigParser()
        let schema = try await parser.parse(from: configURL)

        XCTAssertEqual(schema.groups.count, 1) // All params in one group

        // Find input_dir parameter
        let inputDirParam = schema.parameter(named: "input_dir")
        XCTAssertNotNil(inputDirParam)
        XCTAssertEqual(inputDirParam?.type, .directory)

        // Find threads parameter
        let threadsParam = schema.parameter(named: "threads")
        XCTAssertNotNil(threadsParam)
        XCTAssertEqual(threadsParam?.type, .integer)
        if case .integer(let value) = threadsParam?.defaultValue {
            XCTAssertEqual(value, 4)
        }

        // Find run_qc parameter
        let qcParam = schema.parameter(named: "run_qc")
        XCTAssertNotNil(qcParam)
        XCTAssertEqual(qcParam?.type, .boolean)
        if case .boolean(let value) = qcParam?.defaultValue {
            XCTAssertEqual(value, true)
        }
    }

    // MARK: - SchemaParseError Tests

    func testSchemaParseErrorDescriptions() {
        let fileNotFoundError = SchemaParseError.fileNotFound(URL(fileURLWithPath: "/nonexistent/path"))
        XCTAssertTrue(fileNotFoundError.localizedDescription.contains("not found"))

        let invalidJSONError = SchemaParseError.invalidJSON("Unexpected token")
        XCTAssertTrue(invalidJSONError.localizedDescription.contains("Invalid JSON"))

        let invalidYAMLError = SchemaParseError.invalidYAML("Bad indentation")
        XCTAssertTrue(invalidYAMLError.localizedDescription.contains("Invalid YAML"))

        let missingFieldError = SchemaParseError.missingRequiredField("title")
        XCTAssertTrue(missingFieldError.localizedDescription.contains("title"))

        let versionError = SchemaParseError.unsupportedSchemaVersion("0.1")
        XCTAssertTrue(versionError.localizedDescription.contains("0.1"))
    }
}
