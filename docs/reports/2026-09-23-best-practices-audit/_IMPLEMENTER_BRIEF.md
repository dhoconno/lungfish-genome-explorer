# Implementer brief (binding for every implementation agent)

You are implementing one package from [implementation-plan.md](implementation-plan.md) for Lungfish Genome Explorer (LGE), a Swift 6.2 macOS 26 AppKit app with `lungfish-cli`. Read these before editing anything:

- [implementation-plan.md](implementation-plan.md): Part 1 rules and your package;
- [decisions.md](decisions.md);
- the specialist report sections for your findings.

The orchestrator reviews your diff and reruns your gates, so be precise and honest.

## Rules

1. **Re-verify first.** For each finding in your package, confirm it still holds at your HEAD before changing code. Record "verified / not reproduced / changed shape" for each finding in your final message.
2. **Scope by contract.** Start with a search query (`rg ...`) that finds every caller of the contract you fix. Report the query and hit count. Fix every hit or state why a hit is exempt.
3. **Test-first where practical.** Write a failing behavioural test, then fix. Do NOT add tests that read Swift source as text. Put tests in the module's existing test target, following the local conventions.
4. **Builds:**
   - Use `swift build --package-path <your worktree> --skip-update` and `swift test --package-path <your worktree> --skip-update --filter <YourTests>`. There is no `-C` flag.
   - Run only ONE SwiftPM command at a time in your worktree.
   - Never build in another worktree.
   - For large selections, use `scripts/full-suite-gate.sh --tier unit`.
5. **Commits:** commit on your current branch in small logical commits. End each message with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` (or your actual model name). Do not push, merge, rebase onto main, tag, or release.
6. **Do not touch** the owner's real data:
   - `~/.lungfish*` storage roots, `/Applications/*.app` and the keychain;
   - for any app launch, use `LUNGFISH_STORAGE_ROOT` and `LUNGFISH_CONDA_ROOT` pointed at a temp dir.

   Do not run release, notarize, sign or publish commands.
7. **Keep the diff tight.** Match surrounding style. No drive-by refactors outside your package. If you find a new defect, note it in your final message and do not fix it.
8. **Scientific changes:** add a golden or fixture test showing the corrected output. Add a line under "Behaviour changes" in your final message, suitable for release notes.
9. **Swift conventions** (from project memory):
   - Never use `Task { @MainActor in }` from GCD.
   - Use `DispatchQueue.main.async { MainActor.assumeIsolated { } }` for UI callbacks.
   - Never `%s` with Swift strings.
   - Long-running work goes through OperationCenter with both `update()` and `log()`.
   - Never save alignments as SAM.
10. **Final message** (your report to the orchestrator, which it reads in full):
    - findings, each with its status;
    - commits (SHA and subject);
    - exact test commands with pass/fail counts;
    - behaviour changes;
    - open risks;
    - anything left undone.
