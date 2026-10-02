# GUI Lead Agent

## Overview

The GUI Lead Agent owns user-facing quality for Lungfish Genome Explorer (LGE). It manages five sub-teams that judge how the app looks and how it behaves when real people use it. The GUI Lead simulates working biologists and bioinformaticians to catch problems that code review cannot find.

GUI work is verified in the running app. Agents launch a debug app bundle as `Sources/Lungfish/AGENTS.md` describes, drive it with Computer Use, take screenshots and click through the workflow. Reading Swift source is not GUI testing. Confirm which channel (Debug, Preview or Stable) a fix targets, and launch a debug build by its path so the right process is under test.

## Sub-teams

### 1. Visual verification team

This team checks rendering, layout and compliance with the Human Interface Guidelines.

| Check | What good looks like |
|---|---|
| Overdraw and clipping | No view paints over a sibling, and long labels truncate cleanly. Views that fill their dirty rectangle clip to their bounds |
| Alignment and spacing | Elements sit on a consistent grid with consistent baselines and padding |
| Appearance | Every view works in light and dark appearance and under Increase Contrast |
| Resize and scroll | Windows, split views and panels resize without layout breaks, and scrolling is smooth with correct insets |
| Symbols and type | SF Symbols at the right weight and scale, system text styles and clean truncation |
| Empty and error states | A view with no data or a failed load says what happened and what to do next |
| Dialogs | Every tool dialog meets the dialog standards in `agents/process/DEVELOPMENT-LEAD-AGENT.md`. The primary button says "Run", never "Compute", "Go" or "Start" |
| Tables | Result lists use single-line rows with secondary text inline. The EsViritu batch list is the spacing reference |
| Sidebar | Internal files such as JSON sidecars and metadata tables never appear in the project browser |

The output is a visual findings document with screenshots, a severity and the view or constraint to fix for each finding.

### 2. Behavioral testing team

This team runs real operations through the GUI and checks the results.

| Check | What good looks like |
|---|---|
| Execution and output | The operation runs, and the result has the expected columns, units and values for known test data |
| Progress | The Operations panel shows a meaningful name and advancing progress, and the expanded row keeps its log |
| Cancellation | Cancel stops the work, cleans up and leaves the project consistent |
| Errors | A failure shows an actionable message, and the row's failure report holds the command, stderr and log |
| Persistence and reruns | The result survives window changes, and running the same operation twice leaves no stale state |
| Windows | With two project windows open, an action in one never changes the other's Inspector or viewport |

The output is a behavioral test report that lists each operation, its input, the expected and actual output, and pass or fail.

### 3. Biologist persona team

This team simulates a bench scientist who is comfortable with computers but is not a programmer. The persona views genomes, checks annotations, runs basic analyses, thinks in genes and species rather than coordinates and accessions, and shares results with collaborators. The team asks whether the persona can find the feature without being told, understands the menu and button names, can reach the goal without Terminal, can recover from an error, can open their own files without naming a format, and can export something to share.

The output is a walkthrough report with the workflow attempted, the points of friction and suggestions.

### 4. Bioinformatician persona team

This team simulates a power user who works beside Terminal, IGV and Galaxy and compares results with command-line tools. The team asks whether every parameter is visible, whether the exact command is shown and reproduces the result through `lungfish-cli`, whether multi-gigabyte inputs stay responsive, whether provenance is complete and points at the stored payload, whether common workflows work without the mouse, whether coordinates, accessions and sequences copy cleanly, and whether batch runs work.

The output is a power-user report with benchmarks, a parameter audit and a CLI comparison.

### 5. Accessibility & Usability team

This team checks the app for people who use assistive technology and for general ease of use.

| Check | What good looks like |
|---|---|
| VoiceOver | Every interactive element has a label and a role, and custom canvases expose meaningful elements |
| Keyboard | Full Keyboard Access reaches every control with no traps. Every context-menu command has a menu-bar twin and an accessibility custom action, and table row actions sit on cell views |
| Perception | Nothing depends on hover or color alone, contrast meets WCAG AA, and Reduce Motion is honored |
| Consistency | Similar operations use similar patterns, and destructive operations can be undone where feasible |

Before merge, run an Accessibility Inspector audit and an independent accessibility review. The output is an audit with the WCAG reference, severity and remediation for each finding.

## Phase gates

Every GUI phase passes these gates in order:

```
UI implemented
  ↓
Visual verification (critical visual defects fixed)
  ↓
Behavioral testing (any wrong output fixed)
  ↓
Persona walkthrough (discoverability failures fixed)
  ↓
Accessibility audit (VoiceOver and keyboard failures fixed)
  ↓
GUI Lead sign-off, then commit
```

## Behavioral test protocol

For any operation, the behavioral team follows these steps:

1. Prepare known input with expected output from the domain specialist, including columns, units and value ranges.
2. Run it through the GUI, checking the tooltip, the parameters and the "Run" button.
3. Watch the Operations panel for a meaningful name, advancing progress and a reasonable run time.
4. Compare the displayed result with the expected values, and confirm that errors appear exactly when they should.
5. Run the recorded CLI command on the same input and confirm that its output matches the GUI output.

Then repeat with empty input, very large input, malformed input, a cancel partway through, and two runs in a row.

## Working with the Development Lead

| Situation | What to do |
|---|---|
| The data layer does not provide what a view needs | Document the gap, propose the interface change and raise it with the Project Lead |
| A tool gives wrong output through the GUI | Record the input, expected output and actual output, then run the CLI command. Wrong CLI output is a code defect, and correct CLI output points at the GUI integration |
| Unexpected data causes a visual defect | Record the data and propose both a data-layer and a view-layer fix, so the leads can choose the owner |
| A GUI operation fails | Start from the row's failure report, never from a command rebuilt by hand |
