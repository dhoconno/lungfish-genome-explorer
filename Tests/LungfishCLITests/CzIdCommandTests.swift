// CzIdCommandTests.swift - Tests for CZ-ID CLI command registration
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI

final class CzIdCommandTests: XCTestCase {
    func testCzIdCommandIsRegisteredAtTopLevel() {
        let isRegistered = LungfishCLI.configuration.subcommands.contains { command in
            command.configuration.commandName == CzIdCommand.configuration.commandName
        }

        XCTAssertTrue(isRegistered)
    }
}
