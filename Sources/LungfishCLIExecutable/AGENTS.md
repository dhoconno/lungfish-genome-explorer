# LungfishCLIExecutable

Line numbers were checked at commit a0eec8b32.

## Purpose

The `lungfish-cli` product's executable target. It is a short `@main` shim that calls `LungfishCLIMain.main()`. All commands live in LungfishCLI, which is also a library product so tests and the app's test targets can link it.

## Allowed imports

LungfishCLI only. Do not add code here.

## Entry points

| Type | Path |
|---|---|
| `EntryPoint` | Sources/LungfishCLIExecutable/EntryPoint.swift |
| `LungfishCLIMain` | Sources/LungfishCLI/LungfishCLI.swift line 129 |

## Contracts this module owns

- The product name `lungfish-cli` in Package.swift. The app locates this binary through `CLIBinaryLocator` (Sources/LungfishKit/CLIBinaryLocator.swift line 17), so renaming the product breaks every GUI operation that spawns the CLI.
- Ad hoc signing with lungfish-cli.entitlements through sign-cli.sh at the repository root.

## Tests

No test target of its own. CLI process tests find the built binary through `CLITestBinaryResolver` (Tests/Support/LungfishTestSupport/CLITestBinaryResolver.swift). Build it with `swift build --product lungfish-cli`.

## Known traps

| Trap | Evidence |
|---|---|
| When the app spawns this binary it inherits Finder's bare PATH, so tools must be resolved through the managed environment | memory file project_cli_subprocess_bare_path.md |
| A GUI failure is debugged from the failed Operations row's report, never by retyping the command | memory file feedback_gui_failure_debugging.md |
