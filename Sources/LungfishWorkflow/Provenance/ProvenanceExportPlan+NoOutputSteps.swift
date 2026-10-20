// ProvenanceExportPlan+NoOutputSteps.swift - Tool steps whose standard output LGE read in the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A mapping run records the `samtools coverage` and `samtools view` passes that made its
// summary rows (Phase 2.13 lane 13.16, Q-B3). LGE read their standard output in the app and
// kept no file of it, so each step records no output file and holds `stdoutReadInProcess`. A
// script line that ran `samtools view` would print every alignment to the terminal and rebuild
// nothing the record names.
//
// The plan keeps such a step in `steps` and leaves it out of `replayableSteps`, as it does a
// sub-step. The scripts name it in a comment with its tool, version and recorded argv, and the
// methods text still lists its tool, because the tool did run. The rule reads two recorded
// facts, `stdoutReadInProcess` and an empty `outputs`, never a tool or verb name (decision
// V1-4 (a), narrowed by the ARCH ruling for M2). No record written before 2.13 holds the mark,
// so the script of every older record is the script it was. A tool step that recorded no
// output and holds no mark is still run. The argv stays the argv that ran, with no marker
// word (ARCH 2).

import Foundation
import LungfishCore

extension ProvenanceExportPlan {
    /// The tool steps the executable exports leave out because LGE read their standard output in
    /// the app and they recorded no output file, in recorded order.
    var noOutputSteps: [Step] { steps.filter { $0.isReadInProcessWithNoOutput && !$0.isSubStep } }
}

extension ProvenanceExportPlan.Step {
    /// Whether this is a tool step whose every recorded step lists no output file and holds
    /// `stdoutReadInProcess`.
    var isReadInProcessWithNoOutput: Bool {
        kind == .tool && sourceSteps.allSatisfy { $0.outputs.isEmpty && $0.stdoutReadInProcess == true }
    }
}
