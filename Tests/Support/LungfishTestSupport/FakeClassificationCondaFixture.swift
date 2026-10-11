// FakeClassificationCondaFixture.swift - A conda root whose stand-in micromamba runs a fake kraken2 and Bracken
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved from ClassificationPipelineProvenanceSourceTests.swift by Phase 2.7
// lane F1, so the classifier freeze in LungfishAppTests drives the same fake
// tools. The fixture builds its conda root with the test initializer of
// `CondaManager` and checksums installed files with
// `ManagedToolSourceInstallationRecord.sha256(of:)`. Both are internal to
// LungfishWorkflow, so this file imports it `@testable`, the one such import
// in LungfishTestSupport. The package builds in the debug configuration,
// the app included (scripts/build-app.sh), which compiles LungfishWorkflow
// for testing.

import Foundation
import LungfishIO
@testable import LungfishWorkflow
