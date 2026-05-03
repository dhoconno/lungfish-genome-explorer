// StepExecutorTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Unit tests for the five recipe step executor types.
///
/// These tests focus on parameter parsing, type IDs, and format declarations.
/// They do NOT call `execute()` (which would require native tool binaries).
final class StepExecutorTests: XCTestCase {

    // MARK: - FastpDedupStep

    func testFastpDedupTypeID() {
        XCTAssertEqual(FastpDedupStep.typeID, "fastp-dedup")
    }

    func testFastpDedupFormats() throws {
        let step = try FastpDedupStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }

    func testFastpDedupArgs() throws {
        let step = try FastpDedupStep(params: nil)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--dedup"), "Expected --dedup in \(args)")
        XCTAssertTrue(args.contains("-A"),      "Expected -A in \(args)")
        XCTAssertTrue(args.contains("-G"),      "Expected -G in \(args)")
        XCTAssertTrue(args.contains("-Q"),      "Expected -Q in \(args)")
        XCTAssertTrue(args.contains("-L"),      "Expected -L in \(args)")
    }

    // MARK: - FastpTrimStep

    func testFastpTrimTypeID() {
        XCTAssertEqual(FastpTrimStep.typeID, "fastp-trim")
    }

    func testFastpTrimDefaultArgs() throws {
        let step = try FastpTrimStep(params: nil)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--detect_adapter_for_pe"), "Expected --detect_adapter_for_pe in \(args)")
        XCTAssertTrue(args.contains("-q"),          "Expected -q in \(args)")
        XCTAssertTrue(args.contains("20"),          "Expected 20 (default quality) in \(args)")
        XCTAssertTrue(args.contains("--cut_right"), "Expected --cut_right for default cutMode in \(args)")
    }

    func testFastpTrimCustomArgs() throws {
        let params: [String: AnyCodableValue] = [
            "quality":  .int(15),
            "window":   .int(5),
            "cutMode":  .string("right"),
        ]
        let step = try FastpTrimStep(params: params)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("15"),          "Expected quality 15 in \(args)")
        XCTAssertTrue(args.contains("5"),           "Expected window 5 in \(args)")
        XCTAssertTrue(args.contains("--cut_right"), "Expected --cut_right in \(args)")
    }

    func testFastpTrimCutBoth() throws {
        let params: [String: AnyCodableValue] = ["cutMode": .string("both")]
        let step = try FastpTrimStep(params: params)
        let args = step.fastpArgs()
        XCTAssertTrue(args.contains("--cut_front"), "Expected --cut_front for cutMode:both in \(args)")
        XCTAssertTrue(args.contains("--cut_right"), "Expected --cut_right for cutMode:both in \(args)")
    }

    // MARK: - DeaconScrubStep

    func testDeaconScrubTypeID() {
        XCTAssertEqual(DeaconScrubStep.typeID, "deacon-scrub")
    }

    func testDeaconScrubFormats() throws {
        let step = try DeaconScrubStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }

    func testDeaconScrubDatabaseID() throws {
        let params: [String: AnyCodableValue] = ["database": .string("custom-db")]
        let step = try DeaconScrubStep(params: params)
        XCTAssertEqual(step.databaseID, "custom-db")
    }

    func testDeaconScrubDefaultDatabase() throws {
        let step = try DeaconScrubStep(params: nil)
        XCTAssertEqual(step.databaseID, DeaconPanhumanDatabaseInstaller.databaseID)
    }

    // MARK: - DeaconRiboFilterStep

    func testDeaconRiboFilterTypeID() {
        XCTAssertEqual(DeaconRiboFilterStep.typeID, "deacon-ribo-filter")
    }

    func testDeaconRiboFilterDefaults() throws {
        let step = try DeaconRiboFilterStep(params: nil)
        XCTAssertEqual(step.databaseID, DeaconRibokmersDatabaseInstaller.databaseID)
        XCTAssertEqual(step.absoluteThreshold, 1)
        XCTAssertEqual(step.relativeThreshold, 0)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .pairedR1R2)
    }

    func testDeaconRiboFilterCustomThresholds() throws {
        let step = try DeaconRiboFilterStep(params: [
            "database": .string("custom-ribo"),
            "absoluteThreshold": .int(2),
            "relativeThreshold": .double(0.01),
        ])

        XCTAssertEqual(step.databaseID, "custom-ribo")
        XCTAssertEqual(step.absoluteThreshold, 2)
        XCTAssertEqual(step.relativeThreshold, 0.01)
    }

    // MARK: - FastpMergeStep

    func testFastpMergeTypeID() {
        XCTAssertEqual(FastpMergeStep.typeID, "fastp-merge")
    }

    func testFastpMergeFormats() throws {
        let step = try FastpMergeStep(params: nil)
        XCTAssertEqual(step.inputFormat, .pairedR1R2)
        XCTAssertEqual(step.outputFormat, .merged)
    }

    func testFastpMergeDefaultOverlap() throws {
        let step = try FastpMergeStep(params: nil)
        XCTAssertEqual(step.minOverlap, 15)
    }

    func testFastpMergeCustomOverlap() throws {
        let params: [String: AnyCodableValue] = ["minOverlap": .int(20)]
        let step = try FastpMergeStep(params: params)
        XCTAssertEqual(step.minOverlap, 20)
    }

    // MARK: - SeqkitLengthFilterStep

    func testSeqkitLengthFilterTypeID() {
        XCTAssertEqual(SeqkitLengthFilterStep.typeID, "seqkit-length-filter")
    }

    func testSeqkitLengthFilterDefaults() throws {
        let params: [String: AnyCodableValue] = ["minLength": .int(50)]
        let step = try SeqkitLengthFilterStep(params: params)
        XCTAssertEqual(step.minLength, 50)
        XCTAssertNil(step.maxLength)
    }

    func testSeqkitLengthFilterWithMax() throws {
        let params: [String: AnyCodableValue] = [
            "minLength": .int(100),
            "maxLength": .int(1000),
        ]
        let step = try SeqkitLengthFilterStep(params: params)
        XCTAssertEqual(step.minLength, 100)
        XCTAssertEqual(step.maxLength, 1000)
    }
}
