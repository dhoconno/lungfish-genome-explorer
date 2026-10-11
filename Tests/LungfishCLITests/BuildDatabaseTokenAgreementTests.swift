// BuildDatabaseTokenAgreementTests.swift - The registry's build-db words are the words the CLI takes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision S14 holds the word `lungfish-cli build-db` takes on the analysis descriptor. The app
// passes that word to the CLI, so the set of words must equal the subcommands `build-db` registers.
// BuildDatabaseTokenPinTests in the App tests pins the argv the app launches for each of them.

import ArgumentParser
import LungfishIO
import XCTest
@testable import LungfishCLI

final class BuildDatabaseTokenAgreementTests: XCTestCase {
    func testRegistryTokensEqualTheBuildDbSubcommandNames() {
        let tokens = Set(AnalysisToolRegistry.all.compactMap(\.buildDatabaseToken))
        let subcommands = Set(BuildDbCommand.configuration.subcommands.compactMap { $0.configuration.commandName })
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertEqual(tokens, subcommands)
    }
}
