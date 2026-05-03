// RecipeStepExecutorTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class RecipeStepExecutorTests: XCTestCase {

    // MARK: - RecipeFileFormat

    func testFileFormatCodable() throws {
        let format = RecipeFileFormat.pairedR1R2
        let data = try JSONEncoder().encode(format)
        let decoded = try JSONDecoder().decode(RecipeFileFormat.self, from: data)
        XCTAssertEqual(decoded, .pairedR1R2)
    }

    // MARK: - StepInput

    func testStepInputPaired() {
        let r1 = URL(fileURLWithPath: "/tmp/R1.fq.gz")
        let r2 = URL(fileURLWithPath: "/tmp/R2.fq.gz")
        let input = StepInput(r1: r1, r2: r2, r3: nil, format: .pairedR1R2)
        XCTAssertEqual(input.format, .pairedR1R2)
        XCTAssertNotNil(input.r2)
        XCTAssertNil(input.r3)
    }

    func testStepInputMerged() {
        let merged = URL(fileURLWithPath: "/tmp/merged.fq.gz")
        let ur1 = URL(fileURLWithPath: "/tmp/unmerged_R1.fq.gz")
        let ur2 = URL(fileURLWithPath: "/tmp/unmerged_R2.fq.gz")
        let input = StepInput(r1: merged, r2: ur1, r3: ur2, format: .merged)
        XCTAssertEqual(input.format, .merged)
        XCTAssertNotNil(input.r3)
    }

    // MARK: - StepOutput

    func testStepOutputSingle() {
        let url = URL(fileURLWithPath: "/tmp/reads.fq.gz")
        let output = StepOutput(r1: url, r2: nil, r3: nil, format: .single, readCount: 1000)
        XCTAssertEqual(output.readCount, 1000)
        XCTAssertNil(output.r2)
    }

    func testRiboDetectorStepParsesPairedParameters() throws {
        let step = try RiboDetectorStep(params: [
            "retain": .string("norrna"),
            "ensure": .string("rrna"),
            "readLength": .int(151),
            "chunkSize": .int(200),
        ])

        XCTAssertEqual(step.retention, .nonRRNA)
        XCTAssertEqual(step.ensureMode, .rrna)
        XCTAssertEqual(step.readLength, 151)
        XCTAssertEqual(step.chunkSize, 200)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }
}
