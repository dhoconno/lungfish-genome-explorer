// ContainerPluginTests.swift - Tests for container plugin system
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ContainerPluginTests: XCTestCase {

    // MARK: - ContainerToolPlugin Tests

    func testPluginCreation() {
        let plugin = ContainerToolPlugin(
            id: "test-tool",
            name: "Test Tool",
            description: "A test tool for unit testing",
            imageReference: "biocontainers/test:1.0",
            commands: [
                "run": CommandTemplate(
                    executable: "test",
                    arguments: ["--input", "${INPUT}", "--output", "${OUTPUT}"],
                    description: "Run the test tool"
                )
            ],
            inputs: [
                PluginInput(
                    name: "INPUT",
                    type: .file,
                    required: true,
                    description: "Input file"
                )
            ],
            outputs: [
                PluginOutput(
                    name: "OUTPUT",
                    type: .file,
                    description: "Output file",
                    fileExtension: "out"
                )
            ],
            resources: ResourceRequirements(cpuCount: 2, memoryGB: 4),
            category: .general,
            version: "1.0"
        )

        XCTAssertEqual(plugin.id, "test-tool")
        XCTAssertEqual(plugin.name, "Test Tool")
        XCTAssertEqual(plugin.imageReference, "biocontainers/test:1.0")
        XCTAssertEqual(plugin.commands.count, 1)
        XCTAssertNotNil(plugin.commands["run"])
        XCTAssertEqual(plugin.inputs.count, 1)
        XCTAssertEqual(plugin.outputs.count, 1)
        XCTAssertEqual(plugin.category, .general)
        XCTAssertEqual(plugin.version, "1.0")
    }

    func testPluginIdentifiable() {
        let plugin = ContainerToolPlugin(
            id: "unique-id",
            name: "Test",
            description: "Test",
            imageReference: "test:1.0",
            commands: [:]
        )

        XCTAssertEqual(plugin.id, "unique-id")
    }

    func testPluginEquatable() {
        let plugin1 = ContainerToolPlugin(
            id: "tool",
            name: "Tool",
            description: "Test",
            imageReference: "test:1.0",
            commands: [:]
        )

        let plugin2 = ContainerToolPlugin(
            id: "tool",
            name: "Tool",
            description: "Test",
            imageReference: "test:1.0",
            commands: [:]
        )

        let plugin3 = ContainerToolPlugin(
            id: "different",
            name: "Different",
            description: "Test",
            imageReference: "test:1.0",
            commands: [:]
        )

        XCTAssertEqual(plugin1, plugin2)
        XCTAssertNotEqual(plugin1, plugin3)
    }

    // MARK: - CommandTemplate Tests

    func testCommandTemplateCreation() {
        let template = CommandTemplate(
            executable: "samtools",
            arguments: ["faidx", "${INPUT}"],
            description: "Index a FASTA file",
            workingDirectory: "/workspace",
            environment: ["PATH": "/usr/bin"],
            producesOutput: true
        )

        XCTAssertEqual(template.executable, "samtools")
        XCTAssertEqual(template.arguments, ["faidx", "${INPUT}"])
        XCTAssertEqual(template.description, "Index a FASTA file")
        XCTAssertEqual(template.workingDirectory, "/workspace")
        XCTAssertEqual(template.environment["PATH"], "/usr/bin")
        XCTAssertTrue(template.producesOutput)
    }

    func testCommandTemplateResolve() {
        let template = CommandTemplate(
            executable: "tool",
            arguments: ["--input", "${INPUT}", "--output", "${OUTPUT}", "--ref", "${REFERENCE}"],
            description: "Test command"
        )

        let resolved = template.resolve(with: [
            "INPUT": "/path/to/input.fa",
            "OUTPUT": "/path/to/output.bcf",
            "REFERENCE": "/path/to/ref.fa"
        ])

        XCTAssertEqual(resolved, [
            "tool",
            "--input", "/path/to/input.fa",
            "--output", "/path/to/output.bcf",
            "--ref", "/path/to/ref.fa"
        ])
    }

    func testCommandTemplateResolvePartial() {
        let template = CommandTemplate(
            executable: "tool",
            arguments: ["--input", "${INPUT}", "--missing", "${MISSING}"],
            description: "Test command"
        )

        let resolved = template.resolve(with: [
            "INPUT": "/path/to/input.fa"
        ])

        // Unresolved placeholders remain as-is
        XCTAssertEqual(resolved, [
            "tool",
            "--input", "/path/to/input.fa",
            "--missing", "${MISSING}"
        ])
    }

    // MARK: - PluginInput Tests

    func testPluginInputCreation() {
        let input = PluginInput(
            name: "INPUT",
            type: .file,
            required: true,
            description: "Input FASTA file",
            acceptedExtensions: ["fa", "fasta", "fna"],
            defaultValue: nil
        )

        XCTAssertEqual(input.name, "INPUT")
        XCTAssertEqual(input.id, "INPUT")
        XCTAssertEqual(input.type, .file)
        XCTAssertTrue(input.required)
        XCTAssertEqual(input.acceptedExtensions, ["fa", "fasta", "fna"])
        XCTAssertNil(input.defaultValue)
    }

    func testPluginInputWithDefault() {
        let input = PluginInput(
            name: "THREADS",
            type: .integer,
            required: false,
            description: "Number of threads",
            defaultValue: "4"
        )

        XCTAssertFalse(input.required)
        XCTAssertEqual(input.defaultValue, "4")
    }

    // MARK: - PluginOutput Tests

    func testPluginOutputCreation() {
        let output = PluginOutput(
            name: "OUTPUT",
            type: .file,
            description: "Output index file",
            fileExtension: "fai"
        )

        XCTAssertEqual(output.name, "OUTPUT")
        XCTAssertEqual(output.id, "OUTPUT")
        XCTAssertEqual(output.type, .file)
        XCTAssertEqual(output.fileExtension, "fai")
    }

    // MARK: - PluginIOType Tests

    func testPluginIOTypes() {
        XCTAssertEqual(PluginIOType.file.rawValue, "file")
        XCTAssertEqual(PluginIOType.directory.rawValue, "directory")
        XCTAssertEqual(PluginIOType.string.rawValue, "string")
        XCTAssertEqual(PluginIOType.integer.rawValue, "integer")
        XCTAssertEqual(PluginIOType.number.rawValue, "number")
        XCTAssertEqual(PluginIOType.boolean.rawValue, "boolean")
        XCTAssertEqual(PluginIOType.fileList.rawValue, "fileList")
    }

    // MARK: - ResourceRequirements Tests

    func testResourceRequirementsDefault() {
        let resources = ResourceRequirements.default

        XCTAssertNil(resources.cpuCount)
        XCTAssertEqual(resources.memoryGB, 4)
        XCTAssertNil(resources.diskGB)
        XCTAssertFalse(resources.requiresGPU)
    }

    func testResourceRequirementsMinimal() {
        let resources = ResourceRequirements.minimal

        XCTAssertEqual(resources.cpuCount, 1)
        XCTAssertEqual(resources.memoryGB, 1)
        XCTAssertNil(resources.diskGB)
        XCTAssertFalse(resources.requiresGPU)
    }

    func testResourceRequirementsHighPerformance() {
        let resources = ResourceRequirements.highPerformance

        XCTAssertNil(resources.cpuCount)
        XCTAssertEqual(resources.memoryGB, 16)
        XCTAssertEqual(resources.diskGB, 50)
        XCTAssertFalse(resources.requiresGPU)
    }

    func testResourceRequirementsCustom() {
        let resources = ResourceRequirements(
            cpuCount: 8,
            memoryGB: 32,
            diskGB: 100,
            requiresGPU: true
        )

        XCTAssertEqual(resources.cpuCount, 8)
        XCTAssertEqual(resources.memoryGB, 32)
        XCTAssertEqual(resources.diskGB, 100)
        XCTAssertTrue(resources.requiresGPU)
    }

    // MARK: - PluginCategory Tests

    func testPluginCategoryDisplayNames() {
        XCTAssertEqual(PluginCategory.general.displayName, "General")
        XCTAssertEqual(PluginCategory.alignment.displayName, "Alignment")
        XCTAssertEqual(PluginCategory.variants.displayName, "Variants")
        XCTAssertEqual(PluginCategory.assembly.displayName, "Assembly")
        XCTAssertEqual(PluginCategory.conversion.displayName, "Conversion")
        XCTAssertEqual(PluginCategory.indexing.displayName, "Indexing")
        XCTAssertEqual(PluginCategory.qualityControl.displayName, "Quality Control")
        XCTAssertEqual(PluginCategory.annotation.displayName, "Annotation")
        XCTAssertEqual(PluginCategory.visualization.displayName, "Visualization")
    }

    func testPluginCategoryAllCases() {
        XCTAssertEqual(PluginCategory.allCases.count, 9)
    }

    // MARK: - PluginExecutionResult Tests

    func testPluginExecutionResultSuccess() {
        let result = PluginExecutionResult(
            exitCode: 0,
            stdout: "Success output",
            stderr: "",
            outputFiles: [URL(fileURLWithPath: "/output/file.txt")],
            duration: 5.5
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "Success output")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.outputFiles.count, 1)
        XCTAssertEqual(result.duration, 5.5)
    }

    func testPluginExecutionResultFailure() {
        let result = PluginExecutionResult(
            exitCode: 1,
            stdout: "",
            stderr: "Error: file not found",
            duration: 0.5
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stderr, "Error: file not found")
    }

    // MARK: - Codable Tests

    func testContainerToolPluginCodable() throws {
        let plugin = ContainerToolPlugin(
            id: "samtools",
            name: "SAMtools",
            description: "Test",
            imageReference: "biocontainers/samtools:1.18",
            commands: [
                "faidx": CommandTemplate(
                    executable: "samtools",
                    arguments: ["faidx", "${INPUT}"],
                    description: "Index FASTA"
                )
            ],
            category: .indexing,
            version: "1.18"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(plugin)
        let decoded = try decoder.decode(ContainerToolPlugin.self, from: data)

        XCTAssertEqual(plugin.id, decoded.id)
        XCTAssertEqual(plugin.name, decoded.name)
        XCTAssertEqual(plugin.imageReference, decoded.imageReference)
        XCTAssertEqual(plugin.commands.count, decoded.commands.count)
        XCTAssertEqual(plugin.category, decoded.category)
        XCTAssertEqual(plugin.version, decoded.version)
    }

    func testCommandTemplateCodable() throws {
        let template = CommandTemplate(
            executable: "tool",
            arguments: ["--arg", "${VALUE}"],
            description: "Test",
            workingDirectory: "/work",
            environment: ["KEY": "value"],
            producesOutput: true
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(template)
        let decoded = try decoder.decode(CommandTemplate.self, from: data)

        XCTAssertEqual(template.executable, decoded.executable)
        XCTAssertEqual(template.arguments, decoded.arguments)
        XCTAssertEqual(template.workingDirectory, decoded.workingDirectory)
        XCTAssertEqual(template.environment, decoded.environment)
        XCTAssertEqual(template.producesOutput, decoded.producesOutput)
    }
}
