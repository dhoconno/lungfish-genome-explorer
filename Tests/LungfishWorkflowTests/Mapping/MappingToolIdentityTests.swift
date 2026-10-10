// MappingToolIdentityTests.swift - Every mapper and assembler names an environment the lock builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.5 decision S10. A mapper or assembler environment that is not a
// lock environment is probed and recorded in an environment that never
// exists on a managed root, which is how BBMap recorded micromamba's error.

import XCTest
@testable import LungfishWorkflow

final class MappingToolIdentityTests: XCTestCase {
    /// Executables by lock environment, over `tools` and `packTools`.
    private func lockExecutables() throws -> [String: Set<String>] {
        let lock = try ManagedToolLock.loadFromBundle()
        XCTAssertGreaterThan(lock.tools.count, 0, "the lock decoded with no tools")
        XCTAssertGreaterThan(lock.packTools.count, 0, "the lock decoded with no pack tools")
        let pairs = lock.tools.map { ($0.environment, Set($0.executables)) }
            + lock.packTools.map { ($0.environment, Set($0.executables)) }
        return Dictionary(pairs, uniquingKeysWith: { $0.union($1) })
    }

    func testEveryMappingToolEnvironmentIsALockEnvironmentThatDeclaresItsExecutable() throws {
        let executables = try lockExecutables()
        var missing: [String] = []
        for tool in MappingTool.allCases {
            guard let declared = executables[tool.environmentName] else {
                missing.append("\(tool.rawValue): environment \(tool.environmentName) is not in the lock")
                continue
            }
            if !declared.contains(tool.executableName) {
                missing.append("\(tool.rawValue): \(tool.environmentName) does not declare \(tool.executableName)")
            }
        }
        XCTAssertEqual(missing, [])
    }

    func testEveryAssemblyToolEnvironmentIsALockEnvironmentThatDeclaresItsExecutable() throws {
        let executables = try lockExecutables()
        var missing: [String] = []
        for tool in AssemblyTool.allCases {
            guard let declared = executables[tool.environmentName] else {
                missing.append("\(tool.rawValue): environment \(tool.environmentName) is not in the lock")
                continue
            }
            if !declared.contains(tool.executableName) {
                missing.append("\(tool.rawValue): \(tool.environmentName) does not declare \(tool.executableName)")
            }
        }
        XCTAssertEqual(missing, [])
    }

    /// The environments of the three conda mappers are their raw values, the
    /// bytes every earlier record names.
    func testCondaMapperEnvironmentsKeepTheirRecordedNames() {
        XCTAssertEqual(MappingTool.minimap2.environmentName, "minimap2")
        XCTAssertEqual(MappingTool.bwaMem2.environmentName, "bwa-mem2")
        XCTAssertEqual(MappingTool.bowtie2.environmentName, "bowtie2")
    }
}
